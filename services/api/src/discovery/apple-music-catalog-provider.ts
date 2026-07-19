/**
 * Provider catalogue Apple Music (MusicKit) — SECONDAIRE, activé UNIQUEMENT si
 * les secrets sont présents (cf. config.ts / AppleMusicConfig). Non validé en
 * réel dans cette itération (aucun compte Apple Developer configuré) : à
 * vérifier avant mise en production. Voir memory discover-media-pipeline-v4.
 *
 * SÉCURITÉ ABSOLUE : la clé privée .p8 et le JWT généré NE SORTENT JAMAIS vers
 * le frontend Flutter ni vers Git. Seul le backend signe et appelle Apple.
 *
 * Le JWT (ES256) est généré puis mis en cache et renouvelé avant expiration.
 * Matching : ISRC exact (filter[isrc]) d'abord, sinon identité normalisée +
 * désambiguïsation de version, en réutilisant les mêmes règles que le provider
 * iTunes durci.
 */

import { createPrivateKey, sign as cryptoSign } from 'node:crypto';
import { readFileSync } from 'node:fs';
import {
  normalizeForMatch,
  type CatalogLookupInput,
  type CatalogMatch,
  type CatalogProvider,
} from './preview-provider.js';

const ALT_VERSION_RE =
  /\b(live|en\s+concert|unplugged|remix|rmx|mashup|bootleg|cover|tribute|karaoke|karaoké|made\s+famous|instrumental|acoustic|acoustique|re-?recorded|demo)\b/iu;

export interface AppleMusicCatalogProviderOptions {
  teamId: string;
  keyId: string;
  /** Contenu PEM de la clé privée .p8 (jamais loggé). */
  privateKeyPem: string;
  storefront?: string;
  /** Media identifier optionnel (contexte MusicKit ; non requis pour le catalogue). */
  mediaId?: string;
  baseUrl?: string;
  timeoutMs?: number;
  /** Durée de validité du JWT (Apple : max ~6 mois ; on prend 1 h, renouvelé). */
  tokenTtlSeconds?: number;
  fetchImpl?: typeof fetch;
  now?: () => number;
}

/** Charge les options depuis la config (lit le fichier .p8 sur disque). */
export function loadAppleKeyPem(privateKeyPath: string): string {
  return readFileSync(privateKeyPath, 'utf-8');
}

interface AppleArtwork {
  url?: string;
  width?: number;
  height?: number;
}
interface AppleSongAttributes {
  name?: string;
  artistName?: string;
  albumName?: string;
  isrc?: string;
  durationInMillis?: number;
  previews?: Array<{ url?: string }>;
  artwork?: AppleArtwork;
}
interface AppleSong {
  id?: string;
  attributes?: AppleSongAttributes;
}
interface AppleSearchResponse {
  results?: { songs?: { data?: AppleSong[] } };
}
interface AppleSongsResponse {
  data?: AppleSong[];
}

function base64url(input: Buffer): string {
  return input.toString('base64').replace(/\+/gu, '-').replace(/\//gu, '_').replace(/=+$/u, '');
}

function httpsOnly(url: string | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url).protocol === 'https:' ? url : null;
  } catch {
    return null;
  }
}

/** Rend une URL de pochette Apple (template {w}x{h}) en dimension fixe carrée. */
function renderArtwork(artwork: AppleArtwork | undefined, size = 600): { url: string; w: number; h: number } | null {
  const template = artwork?.url;
  if (!template) return null;
  const url = template.replace('{w}', String(size)).replace('{h}', String(size)).replace('{f}', 'jpg');
  const secure = httpsOnly(url);
  if (secure === null) return null;
  return { url: secure, w: size, h: size };
}

/**
 * Génère un JWT ES256 signé par la clé .p8. Signature au format brut R||S
 * (IEEE P1363) exigé par JWT — jamais le DER par défaut de Node.
 */
export function generateAppleDeveloperToken(params: {
  teamId: string;
  keyId: string;
  privateKeyPem: string;
  issuedAt: number;
  ttlSeconds: number;
}): string {
  const header = { alg: 'ES256', kid: params.keyId, typ: 'JWT' };
  const payload = {
    iss: params.teamId,
    iat: params.issuedAt,
    exp: params.issuedAt + params.ttlSeconds,
  };
  const signingInput = `${base64url(Buffer.from(JSON.stringify(header)))}.${base64url(
    Buffer.from(JSON.stringify(payload)),
  )}`;
  const key = createPrivateKey(params.privateKeyPem);
  // dsaEncoding ieee-p1363 → 64 octets R||S (format JOSE), pas du DER ASN.1.
  const signature = cryptoSign('sha256', Buffer.from(signingInput), {
    key,
    dsaEncoding: 'ieee-p1363',
  });
  return `${signingInput}.${base64url(signature)}`;
}

export class AppleMusicCatalogProvider implements CatalogProvider {
  readonly id = 'APPLE_MUSIC' as const;

  private readonly teamId: string;
  private readonly keyId: string;
  private readonly privateKeyPem: string;
  private readonly storefront: string;
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly tokenTtlSeconds: number;
  private readonly fetchImpl: typeof fetch;
  private readonly now: () => number;

  private token: { value: string; expiresAtMs: number } | null = null;

  constructor(options: AppleMusicCatalogProviderOptions) {
    this.teamId = options.teamId;
    this.keyId = options.keyId;
    this.privateKeyPem = options.privateKeyPem;
    this.storefront = (options.storefront ?? 'fr').toLowerCase();
    this.baseUrl = (options.baseUrl ?? 'https://api.music.apple.com').replace(/\/+$/u, '');
    this.timeoutMs = options.timeoutMs ?? 8_000;
    this.tokenTtlSeconds = options.tokenTtlSeconds ?? 3600;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.now = options.now ?? Date.now;
    // Validation immédiate de la clé (échoue vite si le PEM est invalide).
    createPrivateKey(this.privateKeyPem);
  }

  /** JWT courant, régénéré si absent ou à moins de 5 min de l'expiration. */
  developerToken(): string {
    const nowMs = this.now();
    if (this.token !== null && this.token.expiresAtMs - nowMs > 5 * 60_000) {
      return this.token.value;
    }
    const issuedAt = Math.floor(nowMs / 1000);
    const value = generateAppleDeveloperToken({
      teamId: this.teamId,
      keyId: this.keyId,
      privateKeyPem: this.privateKeyPem,
      issuedAt,
      ttlSeconds: this.tokenTtlSeconds,
    });
    this.token = { value, expiresAtMs: (issuedAt + this.tokenTtlSeconds) * 1000 };
    return value;
  }

  async findPreview(input: CatalogLookupInput): Promise<CatalogMatch | null> {
    try {
      // 1. ISRC exact.
      if (input.isrc && input.isrc.trim().length > 0) {
        const songs = await this.songsByIsrc(input.isrc.trim());
        const chosen = this.pickCanonical(songs, input, 1.0);
        if (chosen) return chosen;
      }
      // 2. Identité + désambiguïsation.
      const songs = await this.search(`${normalizeForMatch(input.artist)} ${normalizeForMatch(input.title)}`);
      return this.pickCanonical(songs, input, 0.9);
    } catch {
      return null; // jamais bloquant
    }
  }

  private pickCanonical(
    songs: AppleSong[],
    input: CatalogLookupInput,
    baseConfidence: number,
  ): CatalogMatch | null {
    const wantedTitle = normalizeForMatch(input.title);
    const wantedArtist = normalizeForMatch(input.artist);
    const seedMarker = ALT_VERSION_RE.test(input.title);
    const identity = songs.filter((s) => {
      const a = s.attributes;
      if (!a || !s.id) return false;
      if (httpsOnly(a.previews?.[0]?.url ?? undefined) === null) return false;
      return (
        normalizeForMatch(a.name ?? '') === wantedTitle &&
        normalizeForMatch(a.artistName ?? '') === wantedArtist
      );
    });
    if (identity.length === 0) return null;
    const studio = identity.filter(
      (s) => seedMarker || !ALT_VERSION_RE.test(`${s.attributes?.name ?? ''} ${s.attributes?.albumName ?? ''}`),
    );
    const pool = studio.length > 0 ? studio : identity;
    const chosen = pool[0]!;
    const a = chosen.attributes!;
    const previewUrl = httpsOnly(a.previews?.[0]?.url ?? undefined);
    if (previewUrl === null) return null;
    const art = renderArtwork(a.artwork);
    return {
      previewUrl,
      provider: 'APPLE_MUSIC',
      confidence: studio.length > 0 ? baseConfidence : Math.min(baseConfidence, 0.8),
      catalogId: chosen.id!,
      isrc: a.isrc ?? input.isrc ?? null,
      canonicalTitle: (a.name ?? '').trim(),
      canonicalArtist: (a.artistName ?? '').trim(),
      artworkUrl: art?.url ?? null,
      artworkWidth: art?.w ?? null,
      artworkHeight: art?.h ?? null,
      artworkProvider: art ? 'APPLE_MUSIC' : null,
      matchedDurationMs: typeof a.durationInMillis === 'number' ? a.durationInMillis : null,
    };
  }

  private async songsByIsrc(isrc: string): Promise<AppleSong[]> {
    const url = `${this.baseUrl}/v1/catalog/${this.storefront}/songs?filter%5Bisrc%5D=${encodeURIComponent(isrc)}`;
    const body = (await this.get(url)) as AppleSongsResponse;
    return body.data ?? [];
  }

  private async search(term: string): Promise<AppleSong[]> {
    const params = new URLSearchParams({ term, types: 'songs', limit: '25' });
    const url = `${this.baseUrl}/v1/catalog/${this.storefront}/search?${params}`;
    const body = (await this.get(url)) as AppleSearchResponse;
    return body.results?.songs?.data ?? [];
  }

  private async get(url: string): Promise<unknown> {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImpl(url, {
        headers: { accept: 'application/json', authorization: `Bearer ${this.developerToken()}` },
        signal: controller.signal,
      });
      if (!response.ok) throw new Error(`Apple Music API ${response.status}`);
      return await response.json();
    } finally {
      clearTimeout(timeout);
    }
  }
}
