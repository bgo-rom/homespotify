/**
 * Sonde HEAD signee vers le Storage Agent, pour valider des pistes candidates.
 *
 * POURQUOI CETTE SONDE TOURNE SUR LE VPS ET NON SUR WINDOWS
 * ---------------------------------------------------------
 * Le Storage Agent filtre l'IP source et n'accepte que `10.8.0.1`, l'adresse
 * WireGuard du VPS (`STORAGE_AGENT_ALLOWED_REMOTE_IP`). Une sonde lancee
 * depuis Windows arriverait d'une autre adresse et recevrait un 403 : elle
 * prouverait seulement que le filtrage fonctionne, pas que la piste existe.
 * Executee depuis le VPS, elle interroge l'agent depuis la position exacte du
 * futur shadow — c'est la seule position ou un `HEAD 200` signifie quelque
 * chose.
 *
 * CE QU'ELLE N'EST PAS
 * --------------------
 * Ce n'est pas l'API. Aucun serveur n'est demarre, aucun port ouvert, aucun
 * octet ecrit sur disque. C'est une requete sortante unique par piste, sans
 * corps, dont seul l'en-tete de reponse est lu.
 *
 * SECRET
 * ------
 * Lu dans le fichier d'environnement 0600 deja depose, jamais passe en
 * argument et jamais journalise. La sortie ne contient ni chemin, ni titre, ni
 * artiste : seulement `trackId`, statut HTTP et taille annoncee.
 */
import { createHash, createHmac, randomBytes } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { request } from 'node:http';

const EMPTY_BODY_SHA256 =
  'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

function fail(code, detail) {
  console.log(JSON.stringify({ ok: false, error: code, detail: detail ?? null }));
  process.exit(1);
}

const [, , envPath, ...trackArgs] = process.argv;
if (!envPath || trackArgs.length === 0) fail('USAGE', 'env et pistes requis');

const trackIds = trackArgs.map(Number);
if (trackIds.some((id) => !Number.isSafeInteger(id) || id <= 0)) {
  fail('TRACK_ID_INVALIDE');
}

// --- Environnement : le secret ne quitte jamais cette variable --------------
const env = new Map();
for (const line of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) continue;
  const index = trimmed.indexOf('=');
  if (index <= 0) continue;
  env.set(trimmed.slice(0, index).trim(), trimmed.slice(index + 1).trim());
}
const secret = env.get('AUDIO_REMOTE_SHARED_SECRET') ?? '';
const baseUrl = env.get('AUDIO_REMOTE_BASE_URL') ?? '';
if (secret.length < 32) fail('SECRET_ABSENT_OU_TROP_COURT');
if (!baseUrl) fail('BASE_URL_ABSENTE');

let base;
try {
  base = new URL(baseUrl);
} catch {
  fail('BASE_URL_INVALIDE');
}

function signedHeaders(method, pathWithQuery) {
  const timestamp = Math.floor(Date.now() / 1000);
  const nonce = randomBytes(32).toString('base64url');
  const canonical = [
    method.toUpperCase(),
    pathWithQuery,
    String(timestamp),
    nonce,
    EMPTY_BODY_SHA256,
  ].join('\n');
  return {
    'x-hs-timestamp': String(timestamp),
    'x-hs-nonce': nonce,
    'x-hs-content-sha256': EMPTY_BODY_SHA256,
    'x-hs-signature': createHmac('sha256', secret).update(canonical, 'utf8').digest('hex'),
  };
}

function probe(method, pathWithQuery) {
  return new Promise((resolve) => {
    const started = Date.now();
    const req = request(
      {
        protocol: base.protocol,
        hostname: base.hostname,
        port: base.port,
        method,
        path: pathWithQuery,
        headers: signedHeaders(method, pathWithQuery),
        timeout: 8000,
      },
      (response) => {
        const contentLength = Number(response.headers['content-length'] ?? -1);
        // Aucun corps n'est lu ni conserve : la reponse est detruite des que
        // les en-tetes sont disponibles.
        response.destroy();
        resolve({
          statusCode: response.statusCode ?? 0,
          contentLength: Number.isFinite(contentLength) ? contentLength : -1,
          elapsedMs: Date.now() - started,
        });
      },
    );
    req.on('timeout', () => { req.destroy(); resolve({ statusCode: 0, error: 'TIMEOUT' }); });
    req.on('error', (error) => {
      resolve({ statusCode: 0, error: String(error?.code ?? error?.message).slice(0, 80) });
    });
    req.end();
  });
}

const health = await probe('GET', '/internal/storage/health');
const results = [];
for (const trackId of trackIds) {
  const result = await probe('HEAD', `/internal/storage/tracks/${trackId}`);
  results.push({ trackId, statusCode: result.statusCode, sizeBytes: result.contentLength ?? -1,
                 ...(result.error ? { error: result.error } : {}) });
}

const reachable = results.filter((item) => item.statusCode === 200);
console.log(JSON.stringify({
  ok: health.statusCode === 200 && reachable.length >= 2,
  agentHealthStatus: health.statusCode,
  probed: results.length,
  reachableCount: reachable.length,
  results,
  serverStarted: false,
  listenersOpened: 0,
}));
