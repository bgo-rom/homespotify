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

interface MusicBrainzArtist {
  id?: string;
  name?: string;
  score?: string | number;
  tags?: MusicBrainzTag[];
}

interface MusicBrainzArtistSearchResponse {
  artists?: MusicBrainzArtist[];
}

export interface MusicBrainzArtistCandidate {
  id: string;
  name: string;
  score: number;
  tags: string[];
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

interface MusicBrainzUrlRelation {
  type?: string;
  url?: { resource?: string };
}

interface MusicBrainzArtistFull extends MusicBrainzArtist {
  disambiguation?: string;
  relations?: MusicBrainzUrlRelation[];
}

interface MusicBrainzReleaseGroupFull {
  id?: string;
  title?: string;
  'primary-type'?: string;
  'secondary-types'?: string[];
  'first-release-date'?: string;
  'artist-credit'?: MusicBrainzArtistCredit[];
  score?: string | number;
}

interface MusicBrainzTrackFull extends MusicBrainzTrack {
  'artist-credit'?: MusicBrainzArtistCredit[];
  recording?: {
    id?: string;
    title?: string;
    length?: number;
    isrcs?: string[];
    'artist-credit'?: MusicBrainzArtistCredit[];
  };
}

interface MusicBrainzMediumFull extends MusicBrainzMedium {
  tracks?: MusicBrainzTrackFull[];
}

interface MusicBrainzReleaseFull extends MusicBrainzRelease {
  media?: MusicBrainzMediumFull[];
  'label-info'?: Array<{ label?: { name?: string } }>;
}

export interface MusicBrainzReleaseGroupCandidate {
  id: string;
  title: string;
  primaryType: string | null;
  secondaryTypes: string[];
  firstReleaseDate: string | null;
  artistCreditPhrase: string | null;
  artistId: string | null;
  score: number;
}

export interface MusicBrainzArtistDetail {
  id: string;
  name: string;
  disambiguation: string | null;
  tags: string[];
  urlRelations: Array<{ type: string; url: string }>;
}

export interface MusicBrainzReleaseTrack {
  discNumber: number | null;
  trackNumber: number | null;
  title: string;
  lengthMs: number | null;
  recordingId: string | null;
  artistCreditPhrase: string | null;
  isrc: string | null;
}

export interface MusicBrainzReleaseDetail {
  id: string;
  title: string;
  date: string | null;
  artistCreditPhrase: string | null;
  label: string | null;
  releaseGroupId: string | null;
  discCount: number | null;
  tracks: MusicBrainzReleaseTrack[];
}

function normalizeReleaseGroup(
  group: MusicBrainzReleaseGroupFull,
): MusicBrainzReleaseGroupCandidate | null {
  if (!group.id || !group.title) return null;
  return {
    id: group.id,
    title: group.title,
    primaryType: group['primary-type'] ?? null,
    secondaryTypes: group['secondary-types'] ?? [],
    firstReleaseDate: group['first-release-date'] ?? null,
    artistCreditPhrase: artistCreditPhrase(group['artist-credit']),
    artistId: firstArtistId(group['artist-credit']),
    score: Number(group.score ?? 0),
  };
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

function normalizeArtist(artist: MusicBrainzArtist): MusicBrainzArtistCandidate | null {
  if (!artist.id || !artist.name) return null;
  return {
    id: artist.id,
    name: artist.name.trim(),
    score: Number(artist.score ?? 0),
    tags: artist.tags
      ?.slice()
      .sort((a, b) => (b.count ?? 0) - (a.count ?? 0))
      .map((tag) => tag.name?.trim() ?? '')
      .filter((tag) => tag.length > 0)
      .slice(0, 5) ?? [],
  };
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

  async searchArtists(query: string, limit = 5): Promise<MusicBrainzArtistCandidate[]> {
    const clean = query.trim();
    if (!clean) return [];
    return this.enqueue(async () => {
      const params = new URLSearchParams({
        query: `artist:"${quoteSearchValue(clean)}"`,
        fmt: 'json',
        limit: String(Math.min(10, Math.max(1, limit))),
      });
      const response = await this.fetchJson<MusicBrainzArtistSearchResponse>(
        `/ws/2/artist?${params}`,
      );
      return response.artists
        ?.map(normalizeArtist)
        .filter((artist): artist is MusicBrainzArtistCandidate => artist !== null) ?? [];
    });
  }

  /**
   * Recordings associés à un ISRC (identité forte). 404 = ISRC inconnu → [].
   */
  async lookupIsrc(isrc: string): Promise<MusicBrainzRecordingCandidate[]> {
    const clean = isrc.trim().toUpperCase();
    if (!/^[A-Z0-9]{12}$/u.test(clean)) return [];
    return this.enqueue(async () => {
      const params = new URLSearchParams({
        fmt: 'json',
        inc: 'artist-credits+releases+release-groups+media',
      });
      try {
        const response = await this.fetchJson<{ recordings?: MusicBrainzRecording[] }>(
          `/ws/2/isrc/${clean}?${params}`,
        );
        return response.recordings
          ?.map(normalizeRecording)
          .filter((recording): recording is MusicBrainzRecordingCandidate => recording !== null) ?? [];
      } catch (error) {
        if (error instanceof MusicBrainzHttpError && error.statusCode === 404) return [];
        throw error;
      }
    });
  }

  /** Recherche de release-groups (albums) par titre et artiste. */
  async searchReleaseGroups(input: {
    title: string;
    artist?: string | null;
    limit?: number;
  }): Promise<MusicBrainzReleaseGroupCandidate[]> {
    const titleTerm = searchTerm('releasegroup', input.title);
    const artistTerm = searchTerm('artist', input.artist);
    const query = [titleTerm, artistTerm].filter((term): term is string => term !== null).join(' AND ');
    if (!query) return [];
    return this.enqueue(async () => {
      const params = new URLSearchParams({
        query,
        fmt: 'json',
        limit: String(Math.min(25, Math.max(1, input.limit ?? 10))),
      });
      const response = await this.fetchJson<{ 'release-groups'?: MusicBrainzReleaseGroupFull[] }>(
        `/ws/2/release-group?${params}`,
      );
      return response['release-groups']
        ?.map(normalizeReleaseGroup)
        .filter((group): group is MusicBrainzReleaseGroupCandidate => group !== null) ?? [];
    });
  }

  /** Discographie d'un artiste (release-groups triés par date, paginés). */
  async browseArtistReleaseGroups(
    artistMbid: string,
    options: { limit?: number; offset?: number } = {},
  ): Promise<{ items: MusicBrainzReleaseGroupCandidate[]; total: number }> {
    return this.enqueue(async () => {
      const params = new URLSearchParams({
        artist: artistMbid,
        fmt: 'json',
        limit: String(Math.min(100, Math.max(1, options.limit ?? 50))),
        offset: String(Math.max(0, options.offset ?? 0)),
      });
      const response = await this.fetchJson<{
        'release-groups'?: MusicBrainzReleaseGroupFull[];
        'release-group-count'?: number;
      }>(`/ws/2/release-group?${params}`);
      return {
        items:
          response['release-groups']
            ?.map(normalizeReleaseGroup)
            .filter((group): group is MusicBrainzReleaseGroupCandidate => group !== null) ?? [],
        total: response['release-group-count'] ?? 0,
      };
    });
  }

  /** Artiste + relations URL (sites officiels, Bandcamp, plateformes). */
  async lookupArtistWithUrls(mbid: string): Promise<MusicBrainzArtistDetail | null> {
    return this.enqueue(async () => {
      const params = new URLSearchParams({ fmt: 'json', inc: 'url-rels+tags' });
      try {
        const artist = await this.fetchJson<MusicBrainzArtistFull>(
          `/ws/2/artist/${encodeURIComponent(mbid)}?${params}`,
        );
        if (!artist.id || !artist.name) return null;
        return {
          id: artist.id,
          name: artist.name.trim(),
          disambiguation: artist.disambiguation?.trim() || null,
          tags:
            artist.tags
              ?.slice()
              .sort((a, b) => (b.count ?? 0) - (a.count ?? 0))
              .map((tag) => tag.name?.trim() ?? '')
              .filter((tag) => tag.length > 0)
              .slice(0, 8) ?? [],
          urlRelations:
            artist.relations
              ?.map((relation) => ({
                type: relation.type ?? '',
                url: relation.url?.resource ?? '',
              }))
              .filter((relation) => relation.url.length > 0) ?? [],
        };
      } catch (error) {
        if (error instanceof MusicBrainzHttpError && error.statusCode === 404) return null;
        throw error;
      }
    });
  }

  /** Release (média + pistes ordonnées) pour la tracklist canonique. */
  async lookupReleaseWithTracks(mbid: string): Promise<MusicBrainzReleaseDetail | null> {
    return this.enqueue(async () => {
      const params = new URLSearchParams({
        fmt: 'json',
        inc: 'recordings+artist-credits+labels+media+isrcs',
      });
      try {
        const release = await this.fetchJson<MusicBrainzReleaseFull>(
          `/ws/2/release/${encodeURIComponent(mbid)}?${params}`,
        );
        if (!release.id || !release.title) return null;
        const media = release.media ?? [];
        const trackEntries: MusicBrainzReleaseTrack[] = [];
        for (const medium of media) {
          for (const track of medium.tracks ?? []) {
            trackEntries.push({
              discNumber: medium.position ?? null,
              trackNumber: parseTrackNumber(track.number, track.position),
              title: track.title ?? track.recording?.title ?? '',
              lengthMs: track.length ?? track.recording?.length ?? null,
              recordingId: track.recording?.id ?? null,
              artistCreditPhrase: artistCreditPhrase(track.recording?.['artist-credit'] ?? track['artist-credit']),
              isrc: track.recording?.isrcs?.[0] ?? null,
            });
          }
        }
        return {
          id: release.id,
          title: release.title,
          date: release.date ?? null,
          artistCreditPhrase: artistCreditPhrase(release['artist-credit']),
          label: release['label-info']?.[0]?.label?.name ?? null,
          releaseGroupId: release['release-group']?.id ?? null,
          discCount: media.length || null,
          tracks: trackEntries,
        };
      } catch (error) {
        if (error instanceof MusicBrainzHttpError && error.statusCode === 404) return null;
        throw error;
      }
    });
  }

  /** Releases d'un release-group : sert à choisir la release canonique. */
  async browseReleaseGroupReleases(releaseGroupMbid: string): Promise<MusicBrainzReleaseCandidate[]> {
    return this.enqueue(async () => {
      const params = new URLSearchParams({
        'release-group': releaseGroupMbid,
        fmt: 'json',
        status: 'official',
        limit: '25',
      });
      const response = await this.fetchJson<{ releases?: MusicBrainzRelease[] }>(
        `/ws/2/release?${params}`,
      );
      return response.releases
        ?.map(normalizeRelease)
        .filter((release): release is MusicBrainzReleaseCandidate => release !== null) ?? [];
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
