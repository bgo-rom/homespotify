import { randomUUID } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { rename, unlink } from 'node:fs/promises';
import { basename, extname, join } from 'node:path';
import { Readable, Transform, type TransformCallback } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import type { NodeFetchConfig } from '../config.js';
import type { UserImportService } from './user-import-service.js';

const MAX_REDIRECTS = 3;
const MAX_METADATA_BYTES = 1024 * 1024;
const MAX_REMOTE_RESULTS = 50;
const JOB_RETENTION_MS = 60 * 60_000;
const MAX_ACTIVE_JOBS_PER_USER = 2;
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

export const NODE_FETCH_STATUSES = [
  'QUEUED',
  'FETCHING',
  'READY_FOR_IMPORT',
  'FAILED',
] as const;

export type NodeFetchStatus = (typeof NODE_FETCH_STATUSES)[number];

export type NodeFetchErrorCode =
  | 'node_fetch_disabled'
  | 'invalid_source_url'
  | 'source_origin_not_allowed'
  | 'node_fetch_queue_full'
  | 'node_fetch_user_busy'
  | 'source_unavailable'
  | 'source_http_error'
  | 'source_redirect_invalid'
  | 'source_timeout'
  | 'source_too_large'
  | 'source_audio_type_invalid'
  | 'remote_response_invalid'
  | 'remote_media_origin_not_allowed'
  | 'remote_track_id_invalid'
  | 'node_fetch_stopped'
  | 'node_fetch_failed';

export class NodeFetchError extends Error {
  constructor(
    readonly code: NodeFetchErrorCode,
    message: string,
  ) {
    super(message);
    this.name = 'NodeFetchError';
  }
}

export interface NodeFetchJobView {
  id: string;
  status: NodeFetchStatus;
  createdAt: string;
  updatedAt: string;
  bytesReceived: number;
  filename: string | null;
  errorCode: NodeFetchErrorCode | null;
  errorMessage: string | null;
}

export interface RemoteTrackSearchResult {
  trackId: string;
  title: string;
  artist: string;
  coverUrl: string | null;
}

type NodeFetchSource =
  | { kind: 'DIRECT_URL'; url: URL }
  | { kind: 'REMOTE_TRACK'; trackId: string };

interface NodeFetchJob extends NodeFetchJobView {
  userId: number;
  username: string;
  source: NodeFetchSource | null;
}

interface NodeFetchLogger {
  info(context: Record<string, unknown>, message: string): void;
  warn(context: Record<string, unknown>, message: string): void;
}

export interface NodeFetchServiceOptions {
  config: NodeFetchConfig;
  importService: Pick<UserImportService, 'ensureUserDirectory'>;
  logger: NodeFetchLogger;
  fetchImpl?: typeof globalThis.fetch;
}

class ByteLimitTransform extends Transform {
  bytesReceived = 0;

  constructor(private readonly maxBytes: number) {
    super();
  }

  override _transform(
    chunk: Buffer | string,
    encoding: BufferEncoding,
    callback: TransformCallback,
  ): void {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, encoding);
    this.bytesReceived += buffer.byteLength;
    if (this.bytesReceived > this.maxBytes) {
      callback(new NodeFetchError(
        'source_too_large',
        'Le fichier distant dépasse la limite configurée.',
      ));
      return;
    }
    callback(null, buffer);
  }
}

class AudioSignatureTransform extends Transform {
  private prefix = Buffer.alloc(0);
  private validated = false;

  constructor(private readonly extension: '.flac' | '.wav') {
    super();
  }

  override _transform(
    chunk: Buffer | string,
    encoding: BufferEncoding,
    callback: TransformCallback,
  ): void {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk, encoding);
    if (this.validated) {
      callback(null, buffer);
      return;
    }
    this.prefix = Buffer.concat([this.prefix, buffer]);
    const requiredBytes = this.extension === '.flac' ? 4 : 12;
    if (this.prefix.byteLength < requiredBytes) {
      callback();
      return;
    }
    if (!hasExpectedSignature(this.prefix, this.extension)) {
      callback(new NodeFetchError(
        'source_audio_type_invalid',
        'Le flux reçu n’est pas un fichier FLAC ou WAV valide.',
      ));
      return;
    }
    this.validated = true;
    const prefix = this.prefix;
    this.prefix = Buffer.alloc(0);
    callback(null, prefix);
  }

  override _flush(callback: TransformCallback): void {
    if (!this.validated) {
      callback(new NodeFetchError(
        'source_audio_type_invalid',
        'Le flux audio est incomplet ou son conteneur est invalide.',
      ));
      return;
    }
    callback();
  }
}

function hasExpectedSignature(buffer: Buffer, extension: '.flac' | '.wav'): boolean {
  if (extension === '.flac') return buffer.subarray(0, 4).equals(Buffer.from('fLaC'));
  return buffer.subarray(0, 4).equals(Buffer.from('RIFF')) &&
    buffer.subarray(8, 12).equals(Buffer.from('WAVE'));
}

function jobView(job: NodeFetchJob): NodeFetchJobView {
  return {
    id: job.id,
    status: job.status,
    createdAt: job.createdAt,
    updatedAt: job.updatedAt,
    bytesReceived: job.bytesReceived,
    filename: job.filename,
    errorCode: job.errorCode,
    errorMessage: job.errorMessage,
  };
}

function audioExtension(
  response: Response,
  finalUrl: URL,
  requiredExtension?: '.flac',
): '.flac' | '.wav' {
  const mime = (response.headers.get('content-type') ?? '')
    .split(';', 1)[0]
    ?.trim()
    .toLowerCase() ?? '';
  const mimeExtension = new Map<string, '.flac' | '.wav'>([
    ['audio/flac', '.flac'],
    ['audio/x-flac', '.flac'],
    ['application/flac', '.flac'],
    ['audio/wav', '.wav'],
    ['audio/x-wav', '.wav'],
    ['audio/wave', '.wav'],
    ['audio/vnd.wave', '.wav'],
  ]).get(mime);
  if (mime.length > 0 && mime !== 'application/octet-stream' && mimeExtension === undefined) {
    throw new NodeFetchError(
      'source_audio_type_invalid',
      'La source ne fournit pas un fichier WAV ou FLAC accepté.',
    );
  }

  if (requiredExtension !== undefined) {
    if (mimeExtension !== undefined && mimeExtension !== requiredExtension) {
      throw new NodeFetchError(
        'source_audio_type_invalid',
        'Le nœud n’a pas fourni le flux FLAC attendu.',
      );
    }
    return requiredExtension;
  }

  const pathExtension = extname(finalUrl.pathname).toLowerCase();
  const urlExtension = pathExtension === '.flac' || pathExtension === '.wav'
    ? pathExtension
    : undefined;
  if (mimeExtension !== undefined && urlExtension !== undefined && mimeExtension !== urlExtension) {
    throw new NodeFetchError(
      'source_audio_type_invalid',
      'Le type audio annoncé ne correspond pas à l’extension du fichier.',
    );
  }
  const extension = mimeExtension ?? urlExtension;
  if (extension === undefined) {
    throw new NodeFetchError(
      'source_audio_type_invalid',
      'Impossible de déterminer un format WAV ou FLAC autorisé.',
    );
  }
  return extension;
}

function safeFilename(finalUrl: URL, extension: '.flac' | '.wav', jobId: string): string {
  let remoteName = 'node-audio';
  try {
    remoteName = basename(decodeURIComponent(finalUrl.pathname)) || remoteName;
  } catch {
    remoteName = basename(finalUrl.pathname) || remoteName;
  }
  const remoteExtension = extname(remoteName);
  const rawStem = remoteExtension.length > 0
    ? remoteName.slice(0, -remoteExtension.length)
    : remoteName;
  const stem = rawStem
    .normalize('NFC')
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, '_')
    .replace(/[. ]+$/g, '')
    .trim()
    .slice(0, 100) || 'node-audio';
  return `${stem}-${jobId.slice(0, 8)}${extension}`;
}

function contentLength(response: Response): number | null {
  const raw = response.headers.get('content-length');
  if (raw === null || !/^\d+$/.test(raw)) return null;
  const value = Number(raw);
  return Number.isSafeInteger(value) ? value : null;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : null;
}

async function readLimitedJson(response: Response): Promise<unknown> {
  const mime = (response.headers.get('content-type') ?? '')
    .split(';', 1)[0]
    ?.trim()
    .toLowerCase() ?? '';
  if (mime !== 'application/json' && !mime.endsWith('+json')) {
    await discardResponse(response);
    throw new NodeFetchError(
      'remote_response_invalid',
      'Le nœud distant n’a pas renvoyé une réponse JSON.',
    );
  }
  const announcedLength = contentLength(response);
  if (announcedLength !== null && announcedLength > MAX_METADATA_BYTES) {
    await discardResponse(response);
    throw new NodeFetchError(
      'remote_response_invalid',
      'La réponse JSON du nœud dépasse la limite autorisée.',
    );
  }
  if (response.body === null) {
    throw new NodeFetchError('remote_response_invalid', 'Réponse JSON distante vide.');
  }
  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > MAX_METADATA_BYTES) {
        await reader.cancel();
        throw new NodeFetchError(
          'remote_response_invalid',
          'La réponse JSON du nœud dépasse la limite autorisée.',
        );
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }
  try {
    return JSON.parse(Buffer.concat(chunks, total).toString('utf8')) as unknown;
  } catch {
    throw new NodeFetchError('remote_response_invalid', 'Réponse JSON distante invalide.');
  }
}

function remoteString(
  record: Record<string, unknown>,
  keys: readonly string[],
  maxLength: number,
): string | null {
  for (const key of keys) {
    const value = record[key];
    if (typeof value !== 'string') continue;
    const normalized = value.trim().normalize('NFC');
    if (normalized.length > 0 && normalized.length <= maxLength) return normalized;
  }
  return null;
}

function allowedRemoteAssetUrl(value: unknown, origins: Set<string>): string | null {
  if (typeof value !== 'string' || value.length > 2_048) return null;
  try {
    const parsed = new URL(value);
    if (
      parsed.protocol !== 'https:' ||
      parsed.username.length > 0 ||
      parsed.password.length > 0 ||
      !origins.has(parsed.origin)
    ) return null;
    parsed.hash = '';
    return parsed.toString();
  } catch {
    return null;
  }
}

function parseRemoteSearchPayload(
  payload: unknown,
  assetOrigins: Set<string>,
): RemoteTrackSearchResult[] {
  type NodeTrack = {
    id?: unknown;
    title?: unknown;
    artists?: Array<{ name?: unknown }> | null;
    artist?: { name?: unknown } | null;
    album?: { coverArt?: unknown } | null;
    albums?: Array<{ coverArt?: unknown }> | null;
    cover?: unknown;
  };

  const normalizeText = (value: unknown, maxLength: number): string | null => {
    if (typeof value !== 'string') return null;
    const normalized = value.trim().normalize('NFC');
    return normalized.length > 0 && normalized.length <= maxLength
      ? normalized
      : null;
  };

  const payloadRecord = asRecord(payload);
  const nestedTrackItems = asRecord(payloadRecord?.tracks)?.items;
  const rawResults = Array.isArray(payloadRecord?.items)
    ? payloadRecord.items
    : Array.isArray(payloadRecord?.tracks)
      ? payloadRecord.tracks
      : Array.isArray(nestedTrackItems)
        ? nestedTrackItems
        : [];
  const results: RemoteTrackSearchResult[] = [];
  const seenTrackIds = new Set<string>();
  for (const rawResult of rawResults.slice(0, MAX_REMOTE_RESULTS)) {
    const record = asRecord(rawResult);
    if (record === null) continue;
    const item = record as NodeTrack;
    const rawId = item.id;
    const trackId = typeof rawId === 'string'
      ? normalizeText(rawId, 200)
      : typeof rawId === 'number' && Number.isFinite(rawId)
        ? String(rawId)
        : null;
    const title = normalizeText(item.title, 300);
    if (trackId === null || title === null || seenTrackIds.has(trackId)) {
      continue;
    }
    const artist = normalizeText(
      item.artists?.[0]?.name ?? item.artist?.name,
      300,
    ) ?? 'Artiste inconnu';
    const rawCover = item.album?.coverArt ??
      item.albums?.[0]?.coverArt ??
      item.cover;
    const coverText = normalizeText(rawCover, 2_048);
    const coverUrl = coverText === null
      ? null
      : /^[A-Za-z0-9_-]{1,200}$/.test(coverText)
        ? coverText
        : allowedRemoteAssetUrl(coverText, assetOrigins);
    seenTrackIds.add(trackId);
    results.push({
      trackId,
      title,
      artist,
      coverUrl,
    });
  }
  return results;
}

function describeJsonStructure(value: unknown, depth = 0): Record<string, unknown> {
  if (value === null) return { type: 'null' };
  if (Array.isArray(value)) {
    return {
      type: 'array',
      length: value.length,
      ...(value.length > 0 && depth < 3
        ? { firstItem: describeJsonStructure(value[0], depth + 1) }
        : {}),
    };
  }
  if (typeof value === 'object') {
    const record = value as Record<string, unknown>;
    const keys = Object.keys(record).slice(0, 50);
    return {
      type: 'object',
      keys,
      ...(depth < 3
        ? {
            fields: Object.fromEntries(
              keys.map((key) => [key, describeJsonStructure(record[key], depth + 1)]),
            ),
          }
        : {}),
    };
  }
  return { type: typeof value };
}

async function discardResponse(response: Response): Promise<void> {
  try {
    await response.body?.cancel();
  } catch {
    // La connexion est déjà fermée : rien d'autre à libérer.
  }
}

async function removeTemporaryFile(path: string | null): Promise<void> {
  if (path === null) return;
  try {
    await unlink(path);
  } catch (error) {
    const code = error instanceof Error && 'code' in error ? error.code : undefined;
    if (code !== 'ENOENT') throw error;
  }
}

export class NodeFetchService {
  private readonly jobs = new Map<string, NodeFetchJob>();
  private readonly queue: NodeFetchJob[] = [];
  private readonly activeTasks = new Set<Promise<void>>();
  private readonly activeControllers = new Map<string, AbortController>();
  private readonly allowedOrigins: Set<string>;
  private readonly mediaAllowedOrigins: Set<string>;
  private readonly remoteAssetOrigins: Set<string>;
  private readonly fetchImpl: typeof globalThis.fetch;
  private runningJobs = 0;
  private stopped = false;

  constructor(private readonly options: NodeFetchServiceOptions) {
    this.allowedOrigins = new Set(options.config.allowedOrigins);
    this.mediaAllowedOrigins = new Set([
      ...options.config.allowedOrigins,
      ...options.config.mediaAllowedOrigins,
    ]);
    this.remoteAssetOrigins = new Set(this.mediaAllowedOrigins);
    this.fetchImpl = options.fetchImpl ?? globalThis.fetch;
  }

  enqueue(input: { userId: number; username: string; url: string }): NodeFetchJobView {
    this.ensureAvailable();
    const sourceUrl = this.parseAllowedUrl(input.url, this.allowedOrigins);
    return this.enqueueSource(input.userId, input.username, {
      kind: 'DIRECT_URL',
      url: sourceUrl,
    });
  }

  enqueueRemoteTrack(input: {
    userId: number;
    username: string;
    trackId: string;
  }): NodeFetchJobView {
    this.ensureAvailable();
    const trackId = input.trackId.trim();
    if (
      trackId.length === 0 ||
      trackId.length > 200 ||
      !/^[A-Za-z0-9._:-]+$/.test(trackId)
    ) {
      throw new NodeFetchError(
        'remote_track_id_invalid',
        'Identifiant de piste distante invalide.',
      );
    }
    return this.enqueueSource(input.userId, input.username, {
      kind: 'REMOTE_TRACK',
      trackId,
    });
  }

  async searchRemote(rawQuery: string): Promise<RemoteTrackSearchResult[]> {
    this.ensureAvailable();
    const query = rawQuery.trim().normalize('NFC');
    if (query.length < 2 || query.length > 200) {
      throw new NodeFetchError(
        'remote_response_invalid',
        'La recherche doit contenir entre 2 et 200 caractères.',
      );
    }
    const nodeOrigin = this.options.config.allowedOrigins[0];
    if (nodeOrigin === undefined) {
      throw new NodeFetchError(
        'node_fetch_disabled',
        'La recherche distante n’est pas configurée sur le serveur.',
      );
    }
    const relativePath = this.options.config.remoteSearchPathTemplate.replace(
      '{query}',
      encodeURIComponent(query),
    );
    const url = new URL(relativePath, nodeOrigin);
    this.options.logger.info(
      { remoteUrl: url.toString() },
      'recherche distante : appel du nœud',
    );
    const controller = new AbortController();
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, this.options.config.metadataTimeoutMs);
    timeout.unref();
    try {
      const payload = await this.fetchNodeJson(url, controller.signal);
      this.options.logger.info(
        {
          remoteUrl: url.toString(),
          payloadStructure: describeJsonStructure(payload),
        },
        'recherche distante : structure JSON reçue',
      );
      return parseRemoteSearchPayload(payload, this.remoteAssetOrigins);
    } catch (error) {
      if (timedOut) {
        throw new NodeFetchError(
          'source_timeout',
          'La recherche distante a dépassé le délai autorisé.',
        );
      }
      throw error;
    } finally {
      clearTimeout(timeout);
    }
  }

  private ensureAvailable(): void {
    if (this.stopped) {
      throw new NodeFetchError('node_fetch_stopped', 'Le service d’import distant est arrêté.');
    }
    if (this.allowedOrigins.size === 0) {
      throw new NodeFetchError(
        'node_fetch_disabled',
        'L’import depuis un nœud autorisé n’est pas configuré sur le serveur.',
      );
    }
  }

  private enqueueSource(
    userId: number,
    username: string,
    source: NodeFetchSource,
  ): NodeFetchJobView {
    this.cleanupExpiredJobs();
    const activeForUser = [...this.jobs.values()].filter((job) =>
      job.userId === userId && (job.status === 'QUEUED' || job.status === 'FETCHING')).length;
    if (activeForUser >= MAX_ACTIVE_JOBS_PER_USER) {
      throw new NodeFetchError(
        'node_fetch_user_busy',
        'Deux imports distants sont déjà en cours pour ce compte.',
      );
    }
    if (this.queue.length >= this.options.config.maxQueuedJobs) {
      throw new NodeFetchError(
        'node_fetch_queue_full',
        'La file d’import distant est pleine. Réessaie plus tard.',
      );
    }

    const now = new Date().toISOString();
    const job: NodeFetchJob = {
      id: randomUUID(),
      userId,
      username,
      source,
      status: 'QUEUED',
      createdAt: now,
      updatedAt: now,
      bytesReceived: 0,
      filename: null,
      errorCode: null,
      errorMessage: null,
    };
    this.jobs.set(job.id, job);
    this.queue.push(job);
    queueMicrotask(() => this.drain());
    return jobView(job);
  }

  getJob(userId: number, jobId: string): NodeFetchJobView | null {
    this.cleanupExpiredJobs();
    const job = this.jobs.get(jobId);
    if (job === undefined || job.userId !== userId) return null;
    return jobView(job);
  }

  async stop(): Promise<void> {
    this.stopped = true;
    for (const job of this.queue.splice(0)) {
      this.failJob(job, new NodeFetchError(
        'node_fetch_stopped',
        'Import annulé pendant l’arrêt du serveur.',
      ));
    }
    for (const controller of this.activeControllers.values()) controller.abort();
    await Promise.allSettled([...this.activeTasks]);
  }

  private parseAllowedUrl(
    raw: string,
    allowedOrigins: Set<string>,
    originErrorCode: NodeFetchErrorCode = 'source_origin_not_allowed',
  ): URL {
    const value = raw.trim();
    if (value.length === 0 || value.length > 2_048) {
      throw new NodeFetchError('invalid_source_url', 'URL source invalide.');
    }
    let parsed: URL;
    try {
      parsed = new URL(value);
    } catch {
      throw new NodeFetchError('invalid_source_url', 'URL source invalide.');
    }
    if (
      parsed.protocol !== 'https:' ||
      parsed.username.length > 0 ||
      parsed.password.length > 0
    ) {
      throw new NodeFetchError(
        'invalid_source_url',
        'Seules les URL HTTPS sans credentials intégrés sont acceptées.',
      );
    }
    if (!allowedOrigins.has(parsed.origin)) {
      throw new NodeFetchError(
        originErrorCode,
        'Cette origine n’est pas autorisée par le serveur.',
      );
    }
    parsed.hash = '';
    return parsed;
  }

  private drain(): void {
    if (this.stopped) return;
    while (
      this.runningJobs < this.options.config.maxConcurrentJobs &&
      this.queue.length > 0
    ) {
      const job = this.queue.shift();
      if (job === undefined) return;
      this.runningJobs += 1;
      const task = this.processJob(job)
        .finally(() => {
          this.runningJobs -= 1;
          this.activeTasks.delete(task);
          this.drain();
        });
      this.activeTasks.add(task);
    }
  }

  private async processJob(job: NodeFetchJob): Promise<void> {
    this.updateJob(job, { status: 'FETCHING' });
    const controller = new AbortController();
    this.activeControllers.set(job.id, controller);
    let timedOut = false;
    const timeout = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, this.options.config.timeoutMs);
    timeout.unref();
    let temporaryPath: string | null = null;

    try {
      const jobSource = job.source;
      if (jobSource === null) {
        throw new NodeFetchError('node_fetch_failed', 'La source du job n’est plus disponible.');
      }
      const remoteTrack = jobSource.kind === 'REMOTE_TRACK';
      const sourceUrl = remoteTrack
        ? await this.resolveRemoteTrack(jobSource.trackId, controller.signal)
        : jobSource.url;
      const downloadOrigins = remoteTrack
        ? this.mediaAllowedOrigins
        : this.allowedOrigins;
      const paths = await this.options.importService.ensureUserDirectory(job.userId, job.username);
      const { response, finalUrl } = await this.fetchFollowingAllowedRedirects(
        sourceUrl,
        controller.signal,
        downloadOrigins,
        remoteTrack ? 'remote_media_origin_not_allowed' : 'source_origin_not_allowed',
      );
      const announcedLength = contentLength(response);
      if (announcedLength !== null && announcedLength > this.options.config.maxBytes) {
        await discardResponse(response);
        throw new NodeFetchError(
          'source_too_large',
          'Le fichier distant dépasse la limite configurée.',
        );
      }
      if (response.body === null) {
        throw new NodeFetchError('source_unavailable', 'La source ne contient aucun flux audio.');
      }

      const extension = audioExtension(response, finalUrl, remoteTrack ? '.flac' : undefined);
      const filename = safeFilename(finalUrl, extension, job.id);
      const finalPath = join(paths.inbox, filename);
      temporaryPath = join(paths.inbox, `.node-fetch-${job.id}.part`);
      const limiter = new ByteLimitTransform(this.options.config.maxBytes);
      const source = Readable.fromWeb(
        response.body as import('node:stream/web').ReadableStream<Uint8Array>,
      );
      await pipeline(
        source,
        limiter,
        new AudioSignatureTransform(extension),
        createWriteStream(temporaryPath, { flags: 'wx', mode: 0o600 }),
      );
      await rename(temporaryPath, finalPath);
      temporaryPath = null;
      this.updateJob(job, {
        status: 'READY_FOR_IMPORT',
        bytesReceived: limiter.bytesReceived,
        filename,
      });
      this.options.logger.info(
        { jobId: job.id, userId: job.userId, bytesReceived: limiter.bytesReceived, filename },
        'import distant déposé dans l’inbox',
      );
    } catch (error) {
      try {
        await removeTemporaryFile(temporaryPath);
      } catch (cleanupError) {
        this.options.logger.warn(
          { jobId: job.id, userId: job.userId, err: cleanupError },
          'nettoyage du fichier temporaire échoué',
        );
      }
      const failure = error instanceof NodeFetchError
        ? error
        : timedOut
          ? new NodeFetchError('source_timeout', 'La source a dépassé le délai autorisé.')
          : controller.signal.aborted && this.stopped
            ? new NodeFetchError('node_fetch_stopped', 'Import interrompu par l’arrêt du serveur.')
            : new NodeFetchError('node_fetch_failed', 'L’import distant a échoué.');
      this.failJob(job, failure);
      this.options.logger.warn(
        { jobId: job.id, userId: job.userId, errorCode: failure.code },
        'import distant échoué',
      );
    } finally {
      clearTimeout(timeout);
      this.activeControllers.delete(job.id);
      job.source = null;
    }
  }

  private async resolveRemoteTrack(trackId: string, signal: AbortSignal): Promise<URL> {
    const nodeOrigin = this.options.config.allowedOrigins[0];
    if (nodeOrigin === undefined) {
      throw new NodeFetchError(
        'node_fetch_disabled',
        'La résolution distante n’est pas configurée sur le serveur.',
      );
    }
    const relativePath = this.options.config.remoteResolvePathTemplate.replace(
      '{trackId}',
      encodeURIComponent(trackId),
    );
    const endpoint = new URL(relativePath, nodeOrigin);
    const payload = await this.fetchNodeJson(endpoint, signal);
    const record = asRecord(payload);
    const rawUrl = record === null
      ? null
      : remoteString(record, ['downloadUrl', 'url'], 2_048);
    if (rawUrl === null) {
      throw new NodeFetchError(
        'remote_response_invalid',
        'Le nœud distant n’a fourni aucune URL de téléchargement.',
      );
    }
    return this.parseAllowedUrl(
      rawUrl,
      this.mediaAllowedOrigins,
      'remote_media_origin_not_allowed',
    );
  }

  private async fetchNodeJson(url: URL, signal: AbortSignal): Promise<unknown> {
    let response: Response;
    try {
      response = await this.fetchImpl(url, {
        method: 'GET',
        redirect: 'manual',
        signal,
        headers: {
          accept: 'application/json',
          'user-agent': 'HomeSpotify/0.1.0',
        },
      });
    } catch (error) {
      if (signal.aborted) throw error;
      throw new NodeFetchError('source_unavailable', 'Le nœud autorisé est inaccessible.');
    }
    if (response.status !== 200) {
      await discardResponse(response);
      if (REDIRECT_STATUSES.has(response.status)) {
        throw new NodeFetchError(
          'source_redirect_invalid',
          'Les endpoints JSON du nœud ne peuvent pas rediriger.',
        );
      }
      throw new NodeFetchError(
        'source_http_error',
        `Le nœud autorisé a répondu avec le code HTTP ${response.status}.`,
      );
    }
    return readLimitedJson(response);
  }

  private async fetchFollowingAllowedRedirects(
    initialUrl: URL,
    signal: AbortSignal,
    allowedOrigins: Set<string>,
    originErrorCode: NodeFetchErrorCode,
  ): Promise<{ response: Response; finalUrl: URL }> {
    let current = new URL(initialUrl);
    for (let redirectCount = 0; redirectCount <= MAX_REDIRECTS; redirectCount += 1) {
      let response: Response;
      try {
        response = await this.fetchImpl(current, {
          method: 'GET',
          redirect: 'manual',
          signal,
          headers: {
            accept: 'audio/flac, audio/wav, application/octet-stream;q=0.5',
            'user-agent': 'HomeSpotify/0.1.0',
          },
        });
      } catch (error) {
        if (signal.aborted) throw error;
        throw new NodeFetchError('source_unavailable', 'Le nœud autorisé est inaccessible.');
      }
      if (response.status === 200) return { response, finalUrl: current };
      if (!REDIRECT_STATUSES.has(response.status)) {
        await discardResponse(response);
        throw new NodeFetchError(
          'source_http_error',
          `Le nœud autorisé a répondu avec le code HTTP ${response.status}.`,
        );
      }
      const location = response.headers.get('location');
      await discardResponse(response);
      if (location === null || redirectCount === MAX_REDIRECTS) {
        throw new NodeFetchError(
          'source_redirect_invalid',
          'La chaîne de redirections du nœud est invalide.',
        );
      }
      let redirected: URL;
      try {
        redirected = new URL(location, current);
      } catch {
        throw new NodeFetchError(
          'source_redirect_invalid',
          'La redirection du nœud contient une URL invalide.',
        );
      }
      current = this.parseAllowedUrl(
        redirected.toString(),
        allowedOrigins,
        originErrorCode,
      );
    }
    throw new NodeFetchError('source_redirect_invalid', 'Trop de redirections.');
  }

  private updateJob(
    job: NodeFetchJob,
    values: Partial<Pick<NodeFetchJob, 'status' | 'bytesReceived' | 'filename'>>,
  ): void {
    Object.assign(job, values, { updatedAt: new Date().toISOString() });
  }

  private failJob(job: NodeFetchJob, error: NodeFetchError): void {
    Object.assign(job, {
      status: 'FAILED' as const,
      errorCode: error.code,
      errorMessage: error.message,
      updatedAt: new Date().toISOString(),
    });
  }

  private cleanupExpiredJobs(): void {
    const cutoff = Date.now() - JOB_RETENTION_MS;
    for (const [id, job] of this.jobs) {
      if (
        job.status !== 'QUEUED' &&
        job.status !== 'FETCHING' &&
        Date.parse(job.updatedAt) < cutoff
      ) {
        this.jobs.delete(id);
      }
    }
  }
}
