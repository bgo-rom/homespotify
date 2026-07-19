/**
 * Client Last.fm minimal (API publique, clé dans `.env` — jamais journalisée).
 * Trois méthodes seulement, celles du graphe de similarité :
 *   - track.getSimilar  : voisins DIRECTS d'un morceau (relation forte) ;
 *   - artist.getSimilar : artistes voisins d'un artiste (relation moyenne) ;
 *   - artist.getTopTracks : matérialise des morceaux pour un artiste voisin.
 *
 * Aucune donnée utilisateur HomeSpotify ne sort : seuls des noms
 * d'artistes/titres (métadonnées de la bibliothèque) partent en requête.
 */

export interface LastfmSimilarTrack {
  title: string;
  artist: string;
  /** 0..1 — force de similarité fournie par Last.fm. */
  match: number;
  durationMs: number | null;
  externalUrl: string | null;
}

export interface LastfmSimilarArtist {
  name: string;
  /** 0..1 — force de similarité fournie par Last.fm. */
  match: number;
  externalUrl: string | null;
}

export interface LastfmTopTrack {
  title: string;
  artist: string;
  externalUrl: string | null;
}

export interface LastfmClientOptions {
  apiKey: string;
  baseUrl?: string;
  timeoutMs?: number;
  maxRetries?: number;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
}

interface RawTrack {
  name?: string;
  match?: number | string;
  duration?: number | string;
  url?: string;
  artist?: { name?: string } | string;
}

interface RawArtist {
  name?: string;
  match?: number | string;
  url?: string;
}

function artistName(raw: RawTrack['artist']): string {
  if (typeof raw === 'string') return raw;
  return raw?.name ?? '';
}

function toNumber(value: number | string | undefined): number {
  const parsed = typeof value === 'string' ? Number(value) : value;
  return typeof parsed === 'number' && Number.isFinite(parsed) ? parsed : 0;
}

function httpsOnly(url: string | undefined): string | null {
  if (!url) return null;
  try {
    return new URL(url).protocol === 'https:' ? url : null;
  } catch {
    return null;
  }
}

export class LastfmError extends Error {
  constructor(
    message: string,
    readonly code: number | null = null,
  ) {
    super(message);
    this.name = 'LastfmError';
  }
}

export class LastfmClient {
  private readonly apiKey: string;
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly maxRetries: number;
  private readonly fetchImpl: typeof fetch;
  private readonly sleep: (ms: number) => Promise<void>;

  constructor(options: LastfmClientOptions) {
    this.apiKey = options.apiKey;
    this.baseUrl = (options.baseUrl ?? 'https://ws.audioscrobbler.com/2.0/').replace(/\/+$/u, '/');
    this.timeoutMs = options.timeoutMs ?? 8000;
    this.maxRetries = options.maxRetries ?? 1;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.sleep = options.sleep ?? ((ms) => new Promise((resolve) => setTimeout(resolve, ms)));
  }

  /** Voisins directs d'un MORCEAU — la relation la plus forte du graphe. */
  async getSimilarTracks(artist: string, track: string, limit = 12): Promise<LastfmSimilarTrack[]> {
    const body = await this.call('track.getsimilar', {
      artist,
      track,
      limit: String(limit),
      autocorrect: '1',
    });
    const raw = (body as { similartracks?: { track?: RawTrack[] } }).similartracks?.track ?? [];
    return raw
      .map((item) => ({
        title: item.name ?? '',
        artist: artistName(item.artist),
        match: Math.max(0, Math.min(1, toNumber(item.match))),
        durationMs: toNumber(item.duration) > 0 ? toNumber(item.duration) * 1000 : null,
        externalUrl: httpsOnly(item.url),
      }))
      .filter((item) => item.title.length > 0 && item.artist.length > 0);
  }

  /** Artistes voisins d'un ARTISTE — relation moyenne du graphe. */
  async getSimilarArtists(artist: string, limit = 8): Promise<LastfmSimilarArtist[]> {
    const body = await this.call('artist.getsimilar', {
      artist,
      limit: String(limit),
      autocorrect: '1',
    });
    const raw = (body as { similarartists?: { artist?: RawArtist[] } }).similarartists?.artist ?? [];
    return raw
      .map((item) => ({
        name: item.name ?? '',
        match: Math.max(0, Math.min(1, toNumber(item.match))),
        externalUrl: httpsOnly(item.url),
      }))
      .filter((item) => item.name.length > 0);
  }

  /** Morceaux les plus représentatifs d'un artiste (matérialise les voisins). */
  async getArtistTopTracks(artist: string, limit = 6): Promise<LastfmTopTrack[]> {
    const body = await this.call('artist.gettoptracks', {
      artist,
      limit: String(limit),
      autocorrect: '1',
    });
    const raw = (body as { toptracks?: { track?: RawTrack[] } }).toptracks?.track ?? [];
    return raw
      .map((item) => ({
        title: item.name ?? '',
        artist: artistName(item.artist) || artist,
        externalUrl: httpsOnly(item.url),
      }))
      .filter((item) => item.title.length > 0);
  }

  private async call(method: string, params: Record<string, string>): Promise<unknown> {
    const query = new URLSearchParams({
      method,
      api_key: this.apiKey,
      format: 'json',
      ...params,
    });
    const url = `${this.baseUrl}?${query.toString()}`;
    let lastError: unknown;
    for (let attempt = 0; attempt <= this.maxRetries; attempt += 1) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
      try {
        const response = await this.fetchImpl(url, {
          headers: { accept: 'application/json' },
          signal: controller.signal,
        });
        if (response.ok) {
          const body = (await response.json()) as { error?: number; message?: string };
          if (typeof body.error === 'number') {
            // Erreur applicative Last.fm (clé invalide, artiste inconnu…).
            throw new LastfmError(body.message ?? `Last.fm error ${body.error}`, body.error);
          }
          return body;
        }
        if ((response.status === 429 || response.status >= 500) && attempt < this.maxRetries) {
          await this.sleep(500 * (attempt + 1));
          continue;
        }
        throw new LastfmError(`Last.fm HTTP ${response.status}`);
      } catch (error) {
        lastError = error;
        // Les erreurs applicatives ne sont pas réessayables.
        if (error instanceof LastfmError && error.code !== null) throw error;
        if (attempt >= this.maxRetries) throw error;
        await this.sleep(500 * (attempt + 1));
      } finally {
        clearTimeout(timeout);
      }
    }
    throw lastError instanceof Error ? lastError : new LastfmError('Last.fm injoignable');
  }
}
