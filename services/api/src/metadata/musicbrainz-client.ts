export interface MusicBrainzClientOptions {
  userAgent: string;
  baseUrl?: string;
  timeoutMs?: number;
  minIntervalMs?: number;
  maxRetries?: number;
  fetchImpl?: typeof fetch;
  sleep?: (ms: number) => Promise<void>;
  now?: () => number;
}

interface MusicBrainzArtistCredit {
  name?: string;
  artist?: {
    id?: string;
    name?: string;
  };
}

interface MusicBrainzTag {
  name?: string;
  count?: number;
}

interface MusicBrainzTrack {
  id?: string;
  title?: string;
  number?: string;
  position?: number;
  length?: number;
}

interface MusicBrainzMedium {
  position?: number;
  tracks?: MusicBrainzTrack[];
}

interface MusicBrainzReleaseGroup {
  id?: string;
  'primary-type'?: string;
}

interface MusicBrainzRelease {
  id?: string;
  title?: string;
  date?: string;
  status?: string;
  'artist-credit'?: MusicBrainzArtistCredit[];
  'release-group'?: MusicBrainzReleaseGroup;
  media?: MusicBrainzMedium[];
}

interface MusicBrainzRecording {
  id?: string;
  title?: string;
  score?: string | number;
  length?: number;
  'artist-credit'?: MusicBrainzArtistCredit[];
  releases?: MusicBrainzRelease[];
  tags?: MusicBrainzTag[];
}

interface MusicBrainzRecordingSearchResponse {
  recordings?: MusicBrainzRecording[];
}

export interface MusicBrainzReleaseCandidate {
  id: string;
  title: string;
  date: string | null;
  status: string | null;
  releaseGroupId: string | null;
  releaseGroupPrimaryType: string | null;
  artistCreditPhrase: string | null;
  discNumber: number | null;
  trackNumber: number | null;
}

export interface MusicBrainzRecordingCandidate {
  id: string;
  title: string;
  score: number;
  lengthMs: number | null;
  artistCreditPhrase: string | null;
  artistId: string | null;
  releases: MusicBrainzReleaseCandidate[];
  tags: string[];
}

export class MusicBrainzHttpError extends Error {
  constructor(
    public statusCode: number,
    message: string,
  ) {
    super(message);
  }
}

function defaultSleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function cleanUserAgent(userAgent: string): string {
  const clean = userAgent.trim();
  if (clean.length < 8) {
    throw new Error('MUSICBRAINZ_USER_AGENT invalide : identifiant applicatif requis');
  }
  return clean;
}

function normalizeBaseUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/u, '');
}

function artistCreditPhrase(credits: MusicBrainzArtistCredit[] | undefined): string | null {
  const names = credits
    ?.map((credit) => credit.name ?? credit.artist?.name ?? '')
    .map((name) => name.trim())
    .filter((name) => name.length > 0);
  return names && names.length > 0 ? names.join(' & ') : null;
}

function firstArtistId(credits: MusicBrainzArtistCredit[] | undefined): string | null {
  return credits?.find((credit) => credit.artist?.id)?.artist?.id ?? null;
}

function parseTrackNumber(value: string | undefined, fallback: number | undefined): number | null {
  if (value) {
    const match = /\d+/u.exec(value);
    if (match) return Number(match[0]);
  }
  return Number.isInteger(fallback) ? fallback ?? null : null;
}

function normalizeRelease(release: MusicBrainzRelease): MusicBrainzReleaseCandidate | null {
  if (!release.id || !release.title) return null;
  const firstMedium = release.media?.[0];
  const firstTrack = firstMedium?.tracks?.[0];
  return {
    id: release.id,
    title: release.title,
    date: release.date ?? null,
    status: release.status ?? null,
    releaseGroupId: release['release-group']?.id ?? null,
    releaseGroupPrimaryType: release['release-group']?.['primary-type'] ?? null,
    artistCreditPhrase: artistCreditPhrase(release['artist-credit']),
    discNumber: Number.isInteger(firstMedium?.position) ? firstMedium?.position ?? null : null,
    trackNumber: parseTrackNumber(firstTrack?.number, firstTrack?.position),
  };
}

function normalizeRecording(recording: MusicBrainzRecording): MusicBrainzRecordingCandidate | null {
  if (!recording.id || !recording.title) return null;
  const releases = recording.releases
    ?.map(normalizeRelease)
    .filter((release): release is MusicBrainzReleaseCandidate => release !== null) ?? [];
  const tags = recording.tags
    ?.filter((tag) => (tag.count ?? 0) >= 0)
    .map((tag) => tag.name?.trim() ?? '')
    .filter((name) => name.length > 0)
    .slice(0, 5) ?? [];
  return {
    id: recording.id,
    title: recording.title,
    score: Number(recording.score ?? 0),
    lengthMs: typeof recording.length === 'number' ? recording.length : null,
    artistCreditPhrase: artistCreditPhrase(recording['artist-credit']),
    artistId: firstArtistId(recording['artist-credit']),
    releases,
    tags,
  };
}

function quoteSearchValue(value: string): string {
  return value.replace(/[\\"]/gu, '\\$&').trim();
}

function searchTerm(field: string, value: string | null | undefined): string | null {
  const clean = value?.trim();
  if (!clean) return null;
  return `${field}:"${quoteSearchValue(clean)}"`;
}

export interface RecordingSearchInput {
  title: string;
  artist: string;
  album?: string | null;
  limit?: number;
}

export class MusicBrainzClient {
  private readonly userAgent: string;
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly minIntervalMs: number;
  private readonly maxRetries: number;
  private readonly fetchImpl: typeof fetch;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly now: () => number;
  private queue: Promise<unknown> = Promise.resolve();
  private lastRequestStartedAt = 0;

  constructor(options: MusicBrainzClientOptions) {
    this.userAgent = cleanUserAgent(options.userAgent);
    this.baseUrl = normalizeBaseUrl(options.baseUrl ?? 'https://musicbrainz.org');
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.minIntervalMs = options.minIntervalMs ?? 1_000;
    this.maxRetries = options.maxRetries ?? 2;
    this.fetchImpl = options.fetchImpl ?? fetch;
    this.sleep = options.sleep ?? defaultSleep;
    this.now = options.now ?? Date.now;
  }

  async searchRecordings(input: RecordingSearchInput): Promise<MusicBrainzRecordingCandidate[]> {
    const titleTerm = searchTerm('recording', input.title);
    const artistTerm = searchTerm('artist', input.artist);
    const albumTerm = searchTerm('release', input.album);
    const query = [titleTerm, artistTerm, albumTerm].filter((term): term is string => term !== null).join(' AND ');
    if (!query) return [];

    return this.enqueue(async () => {
      const params = new URLSearchParams({
        query,
        fmt: 'json',
        limit: String(Math.min(10, Math.max(1, input.limit ?? 5))),
        inc: 'artist-credits+releases+release-groups+media+tags',
      });
      const response = await this.fetchJson<MusicBrainzRecordingSearchResponse>(`/ws/2/recording?${params}`);
      return response.recordings
        ?.map(normalizeRecording)
        .filter((recording): recording is MusicBrainzRecordingCandidate => recording !== null) ?? [];
    });
  }

  private async enqueue<T>(task: () => Promise<T>): Promise<T> {
    const run = this.queue.then(task, task);
    this.queue = run.then(() => undefined, () => undefined);
    return run;
  }

  private async waitForRateLimit(): Promise<void> {
    const elapsed = this.now() - this.lastRequestStartedAt;
    const waitMs = Math.max(0, this.minIntervalMs - elapsed);
    if (waitMs > 0) await this.sleep(waitMs);
    this.lastRequestStartedAt = this.now();
  }

  private async fetchJson<T>(pathAndQuery: string): Promise<T> {
    let lastError: unknown;
    for (let attempt = 0; attempt <= this.maxRetries; attempt += 1) {
      await this.waitForRateLimit();
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
      try {
        const response = await this.fetchImpl(`${this.baseUrl}${pathAndQuery}`, {
          headers: {
            accept: 'application/json',
            'user-agent': this.userAgent,
          },
          signal: controller.signal,
        });
        if (response.ok) return await response.json() as T;

        const body = await response.text().catch(() => '');
        const message = body.trim().slice(0, 300) || response.statusText || 'MusicBrainz request failed';
        if ((response.status === 503 || response.status === 429) && attempt < this.maxRetries) {
          await this.sleep(1_000 * (attempt + 1));
          continue;
        }
        throw new MusicBrainzHttpError(response.status, message);
      } catch (error) {
        lastError = error;
        if (attempt >= this.maxRetries || error instanceof MusicBrainzHttpError) throw error;
        await this.sleep(1_000 * (attempt + 1));
      } finally {
        clearTimeout(timeout);
      }
    }
    throw lastError instanceof Error ? lastError : new Error('MusicBrainz request failed');
  }
}
