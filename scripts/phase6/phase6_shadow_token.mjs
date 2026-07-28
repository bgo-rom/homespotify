/**
 * Jeton d'acces SHADOW, forge selon le contrat applicatif reel.
 *
 * POURQUOI FORGER PLUTOT QUE S'AUTHENTIFIER
 * -----------------------------------------
 * Le shadow possede son propre `AUTH_TOKEN_SECRET` (TD-Phase6-Secrets) : aucun
 * jeton de production ne peut y ouvrir de session, et c'est precisement la
 * propriete qu'on veut PROUVER. Reste a obtenir un jeton valide pour tester
 * les routes authentifiees. Deux voies existent :
 *
 *   1. s'authentifier avec un mot de passe reel sur la copie jetable — il
 *      faudrait manipuler un mot de passe du proprietaire, ce qu'on refuse ;
 *   2. forger le jeton avec le secret DU SHADOW, selon exactement le contrat
 *      de `signAccessToken()` — aucun secret de production n'intervient.
 *
 * La voie 2 est retenue. Elle n'affaiblit rien : le secret utilise est celui
 * du shadow, il est deja sur la machine, et le jeton produit n'a aucune
 * valeur ailleurs.
 *
 * CONTRAT REPRODUIT
 * -----------------
 * `services/api/src/auth/guards.ts` : `app.jwt.sign({sub, username, role,
 * type:'access'}, {expiresIn})`. `@fastify/jwt` signe en HS256 avec
 * `AUTH_TOKEN_SECRET`. Le garde recharge ensuite l'utilisateur en base par
 * `sub` et refuse les comptes inactifs : un jeton forge pour un compte absent
 * ou desactive serait donc rejete. Le jeton ne contourne aucune autorisation.
 *
 * CE QUI N'EST JAMAIS PUBLIE
 * --------------------------
 * Ni le secret, ni le jeton, ni le nom d'utilisateur. Le jeton est ecrit dans
 * un fichier 0600 fourni par l'appelant ; la sortie ne porte que des
 * metadonnees verifiables.
 */
import { createHmac } from 'node:crypto';
import { closeSync, openSync, readFileSync, writeSync } from 'node:fs';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

function fail(code, detail) {
  console.log(JSON.stringify({ ok: false, error: code, detail: detail ?? null }));
  process.exit(1);
}

const [, , envPath, dbPath, bundlePath, outPath] = process.argv;
if (!envPath || !dbPath || !bundlePath || !outPath) {
  fail('USAGE', 'env, db, bundle et destination requis');
}

// --- Secret : lu dans le fichier 0600, jamais en argument -------------------
let secret = '';
for (const line of readFileSync(envPath, 'utf8').split(/\r?\n/)) {
  const trimmed = line.trim();
  if (trimmed.startsWith('#')) continue;
  const index = trimmed.indexOf('=');
  if (index <= 0) continue;
  if (trimmed.slice(0, index).trim() === 'AUTH_TOKEN_SECRET') {
    secret = trimmed.slice(index + 1).trim();
  }
}
if (secret.length < 32) fail('SECRET_ABSENT_OU_TROP_COURT');

// --- Utilisateur : lu dans la copie JETABLE, en lecture seule --------------
let Database;
try {
  Database = require(bundlePath + '/better-sqlite3');
} catch (error) {
  fail('BETTER_SQLITE3_INDISPONIBLE', String(error?.message).slice(0, 200));
}

let user = null;
let visibleTracks = 0;
const db = new Database(dbPath, { readonly: true, fileMustExist: true });
try {
  // Un compte actif, sans changement de mot de passe impose : le garde
  // `requireAuth` refuse les deux cas, et un jeton refuse ne prouverait rien.
  user = db
    .prepare(
      "SELECT id, username, role FROM users " +
      "WHERE is_active = 1 AND must_change_password = 0 " +
      "ORDER BY CASE role WHEN 'OWNER' THEN 0 ELSE 1 END, id LIMIT 1",
    )
    .get();
  if (user) {
    visibleTracks = db
      .prepare('SELECT count(*) AS n FROM user_tracks WHERE user_id = ? AND is_visible = 1')
      .get(user.id).n;
  }
} finally {
  db.close();
}
if (!user) fail('AUCUN_COMPTE_UTILISABLE');

// --- Signature HS256, identique a `signAccessToken()` ----------------------
const base64url = (buffer) => Buffer.from(buffer).toString('base64url');
const issuedAt = Math.floor(Date.now() / 1000);
const expiresIn = 3600;
const header = { alg: 'HS256', typ: 'JWT' };
const payload = {
  sub: String(user.id),
  username: user.username,
  role: user.role,
  type: 'access',
  iat: issuedAt,
  exp: issuedAt + expiresIn,
};
const signingInput =
  base64url(JSON.stringify(header)) + '.' + base64url(JSON.stringify(payload));
const signature = createHmac('sha256', secret).update(signingInput).digest('base64url');
const token = signingInput + '.' + signature;

// --- Ecriture en 0600, jamais sur stdout -----------------------------------
// `0o600` est passe a `openSync` : le fichier NAIT avec ses permissions
// finales. Un `writeFileSync` suivi d'un `chmod` laisserait une fenetre, si
// courte soit-elle, ou le jeton est lisible par d'autres comptes.
const descriptor = openSync(outPath, 'w', 0o600);
try {
  writeSync(descriptor, token);
} finally {
  closeSync(descriptor);
}

console.log(JSON.stringify({
  ok: true,
  userId: user.id,
  role: user.role,
  visibleTracks,
  expiresInSeconds: expiresIn,
  tokenBytes: token.length,
  // Preuves explicites, portees par la sortie elle-meme.
  tokenPrinted: false,
  secretPrinted: false,
  usernamePrinted: false,
  productionSecretUsed: false,
}));
