/**
 * Résolution média (extrait 30 s + pochette + identité) via un catalogue.
 * Provider PRIMAIRE : iTunes Search API (publique, sans clé, storefront FR).
 * Le provider Apple Music (JWT) vit dans apple-music-catalog-provider.ts et
 * n'est branché que si les secrets sont présents.
 *
 * Cascade de matching STRICTE sur l'IDENTITÉ, mais DÉTERMINISTE sur la version
 * (leçon Phase 1 : l'ancien code abandonnait dès qu'iTunes renvoyait plusieurs
 * versions légitimes d'un classique → 95/97 échecs). Ordre :
 *   1. ISRC exact (confiance 1.0)
 *   2. Identifiant catalogue stable d'une résolution antérieure (0.95)
 *   3. Identité normalisée (titre + artiste, tolérante feat./accents/crochets)
 *      puis DÉSAMBIGUÏSATION vers la version canonique STUDIO :
 *        - exclut live / remix / cover / karaoké / instrumental / acoustique ;
 *        - corroboration de durée si fiable (0.9), sinon meilleure version
 *          studio (0.85) ; jamais un rejet au seul motif « plusieurs versions ».
 *      Rejet AMBIGUOUS_MATCH uniquement si deux enregistrements studio
 *      DISTINCTS (durées éloignées) sans durée seed pour trancher.
 *
 * Sécurité : previewUrl/artwork acceptés uniquement en https ; aucun header
 * d'authentification HomeSpotify ne sort vers l'API tierce.
 */

export interface CatalogLookupInput {
  title: string;
  artist: string;
  durationMs: number | null;
  /** ISRC si connu (identité forte — résolu en amont via MusicBrainz). */
  isrc?: string | null;
  /** trackId catalogue d'une résolution antérieure (re-validation rapide). */
  catalogId?: string | null;
}

export type MediaProviderId = 'ITUNES' | 'APPLE_MUSIC';
export type ArtworkProviderId = 'ITUNES' | 'APPLE_MUSIC' | 'COVER_ART_ARCHIVE';

export interface CatalogMatch {
  previewUrl: string;
  provider: MediaProviderId;
  confidence: number;
  catalogId: string;
  isrc: string | null;
  /** Identité canonique du catalogue (jamais la casse Last.fm brute). */
  canonicalTitle: string;
  canonicalArtist: string;
  artworkUrl: string | null;
  artworkWidth: number | null;
  artworkHeight: number | null;
  artworkProvider: ArtworkProviderId | null;
  /** Durée exacte du morceau vérifié (recoupement des métadonnées). */
  matchedDurationMs: number | null;
}

export interface CatalogProvider {
  readonly id: MediaProviderId;
  findPreview(input: CatalogLookupInput): Promise<CatalogMatch | null>;
}

// --- Compat rétrograde (anciens noms) --------------------------------------
export type PreviewLookupInput = CatalogLookupInput;
export type PreviewMatch = CatalogMatch;
export type PreviewProvider = CatalogProvider;

export interface ItunesCatalogProviderOptions {
  baseUrl?: string;
  /** Storefront iTunes (country=). Défaut FR (bibliothèque francophone). */
  storefront?: string;
  timeoutMs?: number;
  maxRetries?: number;
  cacheTtlMs?: number;
  negativeCacheTtlMs?: number;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}

interface ItunesTrack {
  trackId?: number;
  trackName?: string;
  artistName?: string;
  collectionName?: string;
  trackTimeMillis?: number;
  previewUrl?: string;
  artworkUrl100?: string;
  isStreamable?: boolean;
}

interface ItunesResponse {
  resultCount?: number;
  results?: ItunesTrack[];
}

/** Corroboration de durée : ±12 s = « même enregistrement » (soft, jamais un gate dur). */
const DURATION_TOLERANCE_MS = 12_000;
/** Au-delà, deux studios sont des enregistrements DISTINCTS (ambiguïté réelle). */
const DISTINCT_RECORDING_GAP_MS = 45_000;
/** Durée seed plausible pour servir d'arbitre (30 s – 15 min). */
const MIN_PLAUSIBLE_MS = 30_000;
const MAX_PLAUSIBLE_MS = 15 * 60_000;
/** Artwork minimal exigé côté MEDIA_READY (miroir du gate). */
export const MIN_ARTWORK_PX = 500;

/**
 * Marqueurs de VERSION alternative (pas l'enregistrement studio canonique).
 * Cherchés dans le trackName/collectionName BRUTS (les crochets sont retirés
 * par la normalisation d'identité, donc « Thriller (Live) » matche l'identité
 * « thriller » mais reste détecté ici comme live).
 */
const ALT_VERSION_RE =
  /\b(live|en\s+concert|unplugged|remix|rmx|mashup|bootleg|cover|tribute|karaoke|karaoké|made\s+famous|as\s+made\s+popular|instrumental|acoustic|acoustique|re-?recorded|re-?record|demo|rehearsal)\b/iu;

/** Normalisation d'IDENTITÉ : minuscules, sans diacritiques, sans crochets ni feat. */
export function normalizeForMatch(value: string): string {
  return value
    .normalize('NFD')
    .replace(/[̀-ͯ]/gu, '')
    .toLowerCase()
    .replace(/\s*[([{].*?[)\]}]\s*/gu, ' ')
    .replace(/\b(feat|ft|featuring)\.?\s.+$/u, ' ')
    .replace(/[^a-z0-9]+/gu, ' ')
    .trim();
}

function httpsOnly(url: string | undefined): string | null {
  if (!url) return null;
  try {
    const parsed = new URL(url);
    return parsed.protocol === 'https:' ? parsed.toString() : null;
  } catch {
    return null;
  }
}

/** true si `raw` porte un marqueur de version alternative absent de la seed. */
function isAltVersion(raw: string, seedHasMarker: boolean): boolean {
  if (seedHasMarker) return false; // la seed VEUT explicitement cette version
  return ALT_VERSION_RE.test(raw);
}

function plausibleDuration(ms: number | null): boolean {
  return ms !== null && ms >= MIN_PLAUSIBLE_MS && ms <= MAX_PLAUSIBLE_MS;
}

interface ScoredItunes {
  track: ItunesTrack;
  index: number;
  alt: boolean;
  durationGap: number | null;
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

interface CacheEntry {
  value: CatalogMatch | null;
  expiresAt: number;
}

export class ItunesCatalogProvider implements CatalogProvider {
  readonly id = 'ITUNES' as const;

  private readonly baseUrl: string;
  private readonly storefront: string;
  private readonly timeoutMs: number;
  private readonly maxRetries: number;
  private readonly cacheTtlMs: number;
  private readonly negativeCacheTtlMs: number;
  private readonly fetchImpl: typeof fetch;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly now: () => number;
  private readonly cache = new Map<string, CacheEntry>();
  /** Single-flight : une seule requête réseau simultanée par clé. */
  private readonly inFlight = new Map<string, Promise<CatalogMatch | null>>();

  constructor(options: ItunesCatalogProviderOptions = {}) {
    this.baseUrl = (options.baseUrl ?? 'https://itunes.apple.com').replace(/\/+$/u, '');
    this.storefront = options.storefront ?? 'FR';
    this.timeoutMs = options.timeoutMs ?? 8_000;
    this.maxRetries = options.maxRetries ?? 1;
    this.cacheTtlMs = options.cacheTtlMs ?? 24 * 60 * 60 * 1000;
    this.negativeCacheTtlMs = options.negativeCacheTtlMs ?? 6 * 60 * 60 * 1000;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.sleep = options.sleep ?? defaultSleep;
    this.now = options.now ?? Date.now;
  }

  async findPreview(input: CatalogLookupInput): Promise<CatalogMatch | null> {
    const cacheKey = [
      input.isrc ?? '',
      input.catalogId ?? '',
      normalizeForMatch(input.title),
      normalizeForMatch(input.artist),
      input.durationMs ?? '',
    ].join('|');
    const cached = this.cache.get(cacheKey);
    if (cached && cached.expiresAt > this.now()) return cached.value;

    // Single-flight : dédoublonne les résolutions concurrentes identiques.
    const running = this.inFlight.get(cacheKey);
    if (running) return running;

    const promise = (async () => {
      let match: CatalogMatch | null = null;
      // Un échec réseau ne DOIT jamais interrompre la préparation : on renvoie
      // null (candidat non résolu, réessayable) et on met en cache négatif court.
      try {
        match = await this.resolve(input);
      } catch {
        match = null;
      }
      this.cache.set(cacheKey, {
        value: match,
        expiresAt: this.now() + (match ? this.cacheTtlMs : this.negativeCacheTtlMs),
      });
      return match;
    })().finally(() => this.inFlight.delete(cacheKey));

    this.inFlight.set(cacheKey, promise);
    return promise;
  }

  private async resolve(input: CatalogLookupInput): Promise<CatalogMatch | null> {
    // 1. ISRC exact — identité la plus forte.
    if (input.isrc && input.isrc.trim().length > 0) {
      const tracks = await this.lookup(`isrc=${encodeURIComponent(input.isrc.trim())}&entity=song`);
      const seedMarker = ALT_VERSION_RE.test(input.title);
      const clean = tracks.filter(
        (t) => httpsOnly(t.previewUrl) !== null && t.trackId && !isAltVersion(t.trackName ?? '', seedMarker),
      );
      const chosen = this.pickBestByDuration(clean, input.durationMs) ?? clean[0];
      if (chosen) return this.toMatch(chosen, 1.0, input.isrc.trim());
    }

    // 2. Identifiant catalogue stable (re-validation d'une résolution passée).
    if (input.catalogId && /^\d+$/u.test(input.catalogId.trim())) {
      const tracks = await this.lookup(`id=${input.catalogId.trim()}&entity=song`);
      const track = tracks.find(
        (t) => String(t.trackId ?? '') === input.catalogId?.trim() && httpsOnly(t.previewUrl) !== null,
      );
      if (track?.trackId) return this.toMatch(track, 0.95, input.isrc ?? null);
    }

    // 3. Recherche par identité normalisée + désambiguïsation de version.
    return this.resolveByIdentity(input);
  }

  private async resolveByIdentity(input: CatalogLookupInput): Promise<CatalogMatch | null> {
    const wantedTitle = normalizeForMatch(input.title);
    const wantedArtist = normalizeForMatch(input.artist);
    if (wantedTitle.length === 0 || wantedArtist.length === 0) return null;

    // Terme de recherche NETTOYÉ (sans feat./crochets) pour de meilleurs
    // rappels côté iTunes, puis on filtre localement sur l'identité stricte.
    const term = `${normalizeForMatch(input.artist)} ${normalizeForMatch(input.title)}`.trim();
    if (term.length === 0) return null;
    const params = new URLSearchParams({
      term,
      media: 'music',
      entity: 'song',
      limit: '25',
      country: this.storefront,
    });
    const results = await this.fetchJson(`/search?${params}`);

    const seedMarker = ALT_VERSION_RE.test(input.title);
    // Identité stricte + extrait https, en conservant l'ordre iTunes (proxy de popularité).
    const identity: ScoredItunes[] = results
      .map((track, index) => ({ track, index }))
      .filter(
        ({ track }) =>
          httpsOnly(track.previewUrl) !== null &&
          track.trackId &&
          normalizeForMatch(track.trackName ?? '') === wantedTitle &&
          normalizeForMatch(track.artistName ?? '') === wantedArtist,
      )
      .map(({ track, index }) => ({
        track,
        index,
        alt: isAltVersion(
          `${track.trackName ?? ''} ${track.collectionName ?? ''}`,
          seedMarker,
        ),
        durationGap:
          plausibleDuration(input.durationMs) && typeof track.trackTimeMillis === 'number'
            ? Math.abs(track.trackTimeMillis - input.durationMs!)
            : null,
      }));

    if (identity.length === 0) return null; // NO_CATALOG_RESULT / IDENTITY_MISMATCH / NO_PREVIEW

    // Préfère les versions STUDIO ; ne retombe sur les versions alt que si
    // AUCUN studio n'existe (« ONLY_ALT_VERSIONS » → on résout quand même, mais
    // à confiance plus basse : mieux vaut un extrait live que rien pour un
    // classique introuvable en studio sur ce storefront).
    const studio = identity.filter((s) => !s.alt);
    const pool = studio.length > 0 ? studio : identity;

    // Corroboration de durée fiable → 0.9 et match certain.
    if (plausibleDuration(input.durationMs)) {
      const near = pool.filter((s) => s.durationGap !== null && s.durationGap <= DURATION_TOLERANCE_MS);
      if (near.length > 0) {
        const best = near.sort((a, b) => (a.durationGap! - b.durationGap!) || (a.index - b.index))[0]!;
        return this.toMatch(best.track, 0.9, input.isrc ?? null);
      }
      // Aucune version proche de la durée seed : la durée seed est peu fiable
      // (leçon GNR : 569 s pour Sweet Child). On ne rejette PAS pour autant —
      // on désambiguïse par version, sans corroboration (0.85 / 0.8).
    }

    // Un seul candidat studio : canonique évident.
    if (pool.length === 1) {
      return this.toMatch(pool[0]!.track, studio.length > 0 ? 0.85 : 0.8, input.isrc ?? null);
    }

    // Plusieurs candidats. S'ils partagent la même durée (± tolérance) ce sont
    // des ré-éditions du MÊME enregistrement (album/single/compilation) : on
    // prend le premier (proxy popularité). Sinon enregistrements distincts.
    const withDuration = pool.filter((s) => typeof s.track.trackTimeMillis === 'number');
    if (withDuration.length >= 2) {
      const durations = withDuration.map((s) => s.track.trackTimeMillis!);
      const spread = Math.max(...durations) - Math.min(...durations);
      if (spread > DISTINCT_RECORDING_GAP_MS && !plausibleDuration(input.durationMs)) {
        return null; // AMBIGUOUS_MATCH : studios distincts, aucun arbitre de durée.
      }
    }
    // Ré-éditions du même enregistrement OU écart faible : on prend le premier.
    const chosen = pool.sort((a, b) => a.index - b.index)[0]!;
    return this.toMatch(chosen.track, studio.length > 0 ? 0.85 : 0.8, input.isrc ?? null);
  }

  private pickBestByDuration(tracks: ItunesTrack[], durationMs: number | null): ItunesTrack | undefined {
    if (tracks.length === 0) return undefined;
    if (!plausibleDuration(durationMs)) return tracks[0];
    return [...tracks].sort((a, b) => {
      const ga = typeof a.trackTimeMillis === 'number' ? Math.abs(a.trackTimeMillis - durationMs!) : Number.MAX_SAFE_INTEGER;
      const gb = typeof b.trackTimeMillis === 'number' ? Math.abs(b.trackTimeMillis - durationMs!) : Number.MAX_SAFE_INTEGER;
      return ga - gb;
    })[0];
  }

  private toMatch(track: ItunesTrack, confidence: number, isrc: string | null): CatalogMatch | null {
    const previewUrl = httpsOnly(track.previewUrl);
    if (previewUrl === null || !track.trackId) return null;
    // Pochette du MÊME match vérifié, upscalée 600×600 (l'API sert du 100×100).
    const artwork100 = httpsOnly(track.artworkUrl100);
    const artworkUrl = artwork100 === null ? null : artwork100.replace('100x100bb', '600x600bb');
    return {
      previewUrl,
      provider: 'ITUNES',
      confidence,
      catalogId: String(track.trackId),
      isrc,
      canonicalTitle: (track.trackName ?? '').trim(),
      canonicalArtist: (track.artistName ?? '').trim(),
      artworkUrl,
      artworkWidth: artworkUrl === null ? null : 600,
      artworkHeight: artworkUrl === null ? null : 600,
      artworkProvider: artworkUrl === null ? null : 'ITUNES',
      matchedDurationMs:
        typeof track.trackTimeMillis === 'number' && track.trackTimeMillis > 0
          ? track.trackTimeMillis
          : null,
    };
  }

  private async lookup(query: string): Promise<ItunesTrack[]> {
    return this.fetchJson(`/lookup?${query}&country=${this.storefront}`);
  }

  private async fetchJson(pathAndQuery: string): Promise<ItunesTrack[]> {
    let lastError: unknown;
    for (let attempt = 0; attempt <= this.maxRetries; attempt += 1) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
      try {
        const response = await this.fetchImpl(`${this.baseUrl}${pathAndQuery}`, {
          headers: { accept: 'application/json' },
          signal: controller.signal,
        });
        if (response.ok) {
          const body = (await response.json()) as ItunesResponse;
          return body.results ?? [];
        }
        if ((response.status === 429 || response.status >= 500) && attempt < this.maxRetries) {
          await this.sleep(500 * (attempt + 1));
          continue;
        }
        throw new Error(`iTunes Search API ${response.status}`);
      } catch (error) {
        lastError = error;
        if (attempt >= this.maxRetries) throw error;
        await this.sleep(500 * (attempt + 1));
      } finally {
        clearTimeout(timeout);
      }
    }
    throw lastError instanceof Error ? lastError : new Error('iTunes Search API failed');
  }
}

/** @deprecated Alias de compat — utiliser ItunesCatalogProvider. */
export const ItunesPreviewProvider = ItunesCatalogProvider;
