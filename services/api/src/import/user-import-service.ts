import { watch, type FSWatcher } from 'node:fs';
import { mkdir, readdir, rename, stat } from 'node:fs/promises';
import { basename, extname, isAbsolute, join, relative, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { and, desc, eq, inArray, sql } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  ACTIVE_MUSIC_REQUEST_STATUSES,
  importJobs,
  musicRequestItems,
  musicRequests,
  tracks,
  userImportDirectories,
  users,
  type ImportJobStatus,
} from '../db/schema.js';
import { recordAudit } from '../auth/audit.js';
import { grantTrack } from '../library/user-library-service.js';
import {
  analyzeAudioFile,
  importFromPath,
  ImportError,
} from './import-service.js';
import { hashFile } from './import-service.js';
import { reconcileMusicRequestStatus } from '../discovery/music-request-service.js';

const ACCEPTED_EXTENSIONS = new Set(['.flac', '.wav']);
const IGNORED_SUFFIXES = ['.tmp', '.part', '.download', '.crdownload'];
const REQUEST_MATCH_THRESHOLD = 75;
const REQUEST_MATCH_MARGIN = 15;

export interface UserImportPaths {
  userId: number;
  directoryName: string;
  root: string;
  inbox: string;
  rejected: string;
  processed: string;
}

export interface ImportServiceOptions {
  importRoot: string;
  musicDir: string;
  coversDir: string;
  stableIntervalMs?: number;
  stableChecks?: number;
  maxStableChecks?: number;
}

export class UserImportError extends Error {
  constructor(
    readonly code:
      | 'invalid_path'
      | 'job_not_found'
      | 'track_not_found'
      | 'request_item_not_found'
      | 'file_not_available',
    message: string,
  ) {
    super(message);
    this.name = 'UserImportError';
  }
}

interface ParsedImportMetadata {
  title: string;
  artist: string;
  album: string;
  durationMs: number | null;
  isrc: string | null;
  trackPosition: number | null;
  trackTotal: number | null;
  discNumber: number | null;
  discTotal: number | null;
  albumArtist: string | null;
  date: string | null;
  year: number | null;
  genre: string | null;
  sampleRate: number | null;
  bitDepth: number | null;
  channels: number | null;
  container: string | null;
  codec: string | null;
  cover: {
    mimeType: string;
    type: string | null;
    width: number | null;
    height: number | null;
  } | null;
}

interface RequestMatch {
  requestId: number;
  itemId: number;
  score: number;
}

function normalize(value: string | null | undefined): string {
  return (value ?? '')
    .normalize('NFD')
    .replace(/[\u0300-\u036f]/g, '')
    .trim()
    .toLowerCase()
    .replace(/\s+/g, ' ');
}

function confined(root: string, candidate: string): string {
  const absoluteRoot = resolve(root);
  const absoluteCandidate = resolve(candidate);
  const rel = relative(absoluteRoot, absoluteCandidate);
  if (rel === '' || (!rel.startsWith('..') && !isAbsolute(rel))) return absoluteCandidate;
  throw new UserImportError('invalid_path', 'Chemin d\'import hors de la racine autorisée.');
}

function safeDirectoryName(userId: number, username: string): string {
  const safeUsername = username.replace(/[^a-z0-9._-]/g, '_');
  return `${userId}_${safeUsername}`;
}

function isAcceptedFilename(filename: string): boolean {
  const lower = filename.toLowerCase();
  if (IGNORED_SUFFIXES.some((suffix) => lower.endsWith(suffix))) return false;
  return ACCEPTED_EXTENSIONS.has(extname(lower));
}

function metadataJson(metadata: ParsedImportMetadata): string {
  return JSON.stringify(metadata);
}

export class UserImportService {
  private readonly watchers = new Map<number, FSWatcher>();
  private readonly scheduled = new Map<string, NodeJS.Timeout>();
  private readonly processing = new Map<string, Promise<number>>();
  private stopped = false;

  constructor(
    private readonly handle: DbHandle,
    private readonly options: ImportServiceOptions,
  ) {}

  async ensureUserDirectory(userId: number, username: string): Promise<UserImportPaths> {
    let row = this.handle.db
      .select()
      .from(userImportDirectories)
      .where(eq(userImportDirectories.userId, userId))
      .get();
    if (!row) {
      row = this.handle.db
        .insert(userImportDirectories)
        .values({
          userId,
          directoryName: safeDirectoryName(userId, username),
          createdAt: new Date().toISOString(),
        })
        .returning()
        .get();
    }
    const root = confined(this.options.importRoot, join(this.options.importRoot, row.directoryName));
    const paths = {
      userId,
      directoryName: row.directoryName,
      root,
      inbox: confined(root, join(root, 'inbox')),
      rejected: confined(root, join(root, 'rejected')),
      processed: confined(root, join(root, 'processed')),
    };
    await Promise.all([
      mkdir(paths.inbox, { recursive: true }),
      mkdir(paths.rejected, { recursive: true }),
      mkdir(paths.processed, { recursive: true }),
    ]);
    return paths;
  }

  async ensureAllUserDirectories(): Promise<UserImportPaths[]> {
    await mkdir(this.options.importRoot, { recursive: true });
    const accounts = this.handle.db
      .select({ id: users.id, username: users.username })
      .from(users)
      .all();
    return Promise.all(accounts.map((user) => this.ensureUserDirectory(user.id, user.username)));
  }

  async start(): Promise<void> {
    this.stopped = false;
    const paths = await this.ensureAllUserDirectories();
    for (const userPaths of paths) await this.watchUserPaths(userPaths);
  }

  async ensureAndWatchUser(userId: number, username: string): Promise<UserImportPaths> {
    const paths = await this.ensureUserDirectory(userId, username);
    if (!this.stopped) await this.watchUserPaths(paths);
    return paths;
  }

  stop(): void {
    this.stopped = true;
    for (const timer of this.scheduled.values()) clearTimeout(timer);
    this.scheduled.clear();
    for (const watcher of this.watchers.values()) watcher.close();
    this.watchers.clear();
  }

  private async watchUserPaths(paths: UserImportPaths): Promise<void> {
    if (this.watchers.has(paths.userId)) return;
    const entries = await readdir(paths.inbox, { withFileTypes: true });
    for (const entry of entries) {
      if (entry.isFile()) this.schedule(paths, join(paths.inbox, entry.name));
    }
    const watcher = watch(paths.inbox, { persistent: false }, (_event, filename) => {
      if (filename === null) return;
      this.schedule(paths, join(paths.inbox, filename.toString()));
    });
    watcher.on('error', () => watcher.close());
    this.watchers.set(paths.userId, watcher);
  }

  private schedule(paths: UserImportPaths, path: string): void {
    if (this.stopped || !isAcceptedFilename(basename(path))) return;
    const safePath = confined(paths.inbox, path);
    if (this.scheduled.has(safePath)) return;
    const timer = setTimeout(() => {
      this.scheduled.delete(safePath);
      void this.processInboxFile(paths.userId, safePath).catch((error: unknown) => {
        const message = error instanceof Error ? error.message : 'Erreur d’import planifié inconnue.';
        console.error('échec import planifié', {
          userId: paths.userId,
          filename: basename(safePath),
          error: message,
        });
      });
    }, 150);
    timer.unref();
    this.scheduled.set(safePath, timer);
  }

  async processInboxFile(userId: number, path: string): Promise<number> {
    const directory = this.getUserPaths(userId);
    const safePath = confined(directory.inbox, path);
    const key = `${userId}:${safePath.toLowerCase()}`;
    const active = this.processing.get(key);
    if (active) return active;
    const processing = this.processInboxFileOnce(userId, directory, safePath)
      .finally(() => this.processing.delete(key));
    this.processing.set(key, processing);
    return processing;
  }

  private async processInboxFileOnce(
    userId: number,
    directory: UserImportPaths,
    safePath: string,
  ): Promise<number> {
    const filename = basename(safePath);
    if (!isAcceptedFilename(filename)) {
      throw new UserImportError('file_not_available', 'Seuls les fichiers FLAC et WAV sont acceptés.');
    }
    const relativePath = relative(resolve(this.options.importRoot), safePath);
    const now = new Date().toISOString();
    const job = this.handle.db
      .insert(importJobs)
      .values({
        userId,
        filename,
        relativePath,
        status: 'WAITING_FOR_STABLE_FILE',
        createdAt: now,
        updatedAt: now,
      })
      .onConflictDoNothing()
      .returning()
      .get() ?? this.handle.db
      .select()
      .from(importJobs)
      .where(and(eq(importJobs.userId, userId), eq(importJobs.relativePath, relativePath)))
      .orderBy(desc(importJobs.id))
      .get();
    if (!job) throw new UserImportError('file_not_available', 'Import déjà pris en charge.');

    try {
      const stable = await this.waitForStableFile(safePath);
      this.updateJob(job.id, {
        status: 'ANALYZING',
        sizeBytes: stable.size,
        attempts: job.attempts + 1,
        errorMessage: null,
      });

      const parsed = await analyzeAudioFile(safePath, filename);
      const metadata: ParsedImportMetadata = {
        title: parsed.title,
        artist: parsed.artist,
        album: parsed.album,
        durationMs: parsed.durationSeconds === null
          ? null
          : Math.round(parsed.durationSeconds * 1000),
        isrc: parsed.isrc,
        trackPosition: parsed.trackNumber,
        trackTotal: parsed.trackTotal,
        discNumber: parsed.discNumber,
        discTotal: parsed.discTotal,
        albumArtist: parsed.albumArtist,
        date: parsed.date,
        year: parsed.year,
        genre: parsed.genre,
        sampleRate: parsed.sampleRate,
        bitDepth: parsed.bitDepth,
        channels: parsed.channels,
        container: parsed.container,
        codec: parsed.codec,
        cover: parsed.cover === null
          ? null
          : {
              mimeType: parsed.cover.mimeType,
              type: parsed.cover.type,
              width: parsed.cover.width,
              height: parsed.cover.height,
            },
      };
      const sha256 = await hashFile(safePath);
      const duplicate = this.findExistingTrack(sha256, metadata);
      let trackId: number;
      let reused = false;
      if (duplicate.kind === 'ambiguous') {
        this.updateJob(job.id, {
          status: 'WAITING_FOR_OWNER_MATCH',
          sha256,
          metadataJson: metadataJson(metadata),
          matchCandidatesJson: JSON.stringify(duplicate.trackIds),
        });
        return job.id;
      }
      if (duplicate.trackId !== null) {
        trackId = duplicate.trackId;
        reused = true;
      } else {
        const outcome = await importFromPath(
          this.handle.db,
          {
            musicDir: this.options.musicDir,
            incomingDir: this.options.importRoot,
            coversDir: this.options.coversDir,
          },
          safePath,
          'inconnue',
          parsed,
        );
        trackId = outcome.status === 'duplicate' ? outcome.existingId : outcome.track.id;
        reused = outcome.status === 'duplicate';
      }

      grantTrack(this.handle, { userId, trackId, source: 'MANUAL_IMPORT' });
      const matches = this.findRequestMatches(userId, metadata);
      const selected = this.selectUniqueRequestMatch(matches);
      if (selected !== null) {
        this.attachTrackToRequestItem(userId, selected.itemId, trackId, null);
      }
      const ambiguousRequest = selected === null && matches.length > 0;
      const destination = await this.moveTo(directory.processed, safePath);
      this.updateJob(job.id, {
        status: ambiguousRequest ? 'WAITING_FOR_OWNER_MATCH' : reused ? 'REUSED' : 'IMPORTED',
        sha256,
        metadataJson: metadataJson(metadata),
        trackId,
        musicRequestId: selected?.requestId ?? null,
        musicRequestItemId: selected?.itemId ?? null,
        matchCandidatesJson: ambiguousRequest ? JSON.stringify(matches) : null,
        relativePath: relative(resolve(this.options.importRoot), destination),
        processedAt: new Date().toISOString(),
      });
      recordAudit(this.handle, {
        action: reused ? 'import.track_reused' : 'import.track_created',
        actorUserId: null,
        targetUserId: userId,
        metadata: { jobId: job.id, trackId, requestId: selected?.requestId ?? 0 },
      });
      return job.id;
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Erreur d\'import inconnue.';
      this.updateJob(job.id, { status: 'FAILED', errorMessage: message.slice(0, 500) });
      recordAudit(this.handle, {
        action: 'import.failed',
        actorUserId: null,
        targetUserId: userId,
        metadata: { jobId: job.id, reason: message.slice(0, 120) },
      });
      if (error instanceof ImportError || error instanceof UserImportError) return job.id;
      return job.id;
    }
  }

  private getUserPaths(userId: number): UserImportPaths {
    const row = this.handle.db
      .select()
      .from(userImportDirectories)
      .where(eq(userImportDirectories.userId, userId))
      .get();
    if (!row) throw new UserImportError('invalid_path', 'Dossier d\'import utilisateur absent.');
    const root = confined(this.options.importRoot, join(this.options.importRoot, row.directoryName));
    return {
      userId,
      directoryName: row.directoryName,
      root,
      inbox: confined(root, join(root, 'inbox')),
      rejected: confined(root, join(root, 'rejected')),
      processed: confined(root, join(root, 'processed')),
    };
  }

  private async waitForStableFile(path: string): Promise<{ size: number; mtimeMs: number }> {
    const stableChecks = this.options.stableChecks ?? 2;
    const maxChecks = this.options.maxStableChecks ?? 30;
    const interval = this.options.stableIntervalMs ?? 1000;
    let previous: { size: number; mtimeMs: number } | null = null;
    let stableCount = 0;
    for (let attempt = 0; attempt < maxChecks; attempt += 1) {
      const currentStat = await stat(path);
      if (!currentStat.isFile()) throw new UserImportError('file_not_available', 'Entrée non fichier.');
      const current = { size: currentStat.size, mtimeMs: currentStat.mtimeMs };
      if (previous !== null && current.size === previous.size && current.mtimeMs === previous.mtimeMs) {
        stableCount += 1;
        if (stableCount >= stableChecks) return current;
      } else {
        stableCount = 0;
      }
      previous = current;
      await delay(interval);
    }
    throw new UserImportError('file_not_available', 'Le fichier reste en cours d\'écriture.');
  }

  private findExistingTrack(
    sha256: string,
    metadata: ParsedImportMetadata,
  ): { kind: 'none' | 'unique'; trackId: number | null } | { kind: 'ambiguous'; trackIds: number[] } {
    const exact = this.handle.db.select({ id: tracks.id }).from(tracks).where(eq(tracks.hash, sha256)).get();
    if (exact) return { kind: 'unique', trackId: exact.id };

    if (metadata.isrc !== null) {
      const byIsrc = this.handle.db
        .select({ id: tracks.id })
        .from(tracks)
        .where(eq(tracks.isrc, metadata.isrc))
        .limit(3)
        .all();
      if (byIsrc.length === 1) return { kind: 'unique', trackId: byIsrc[0]!.id };
      if (byIsrc.length > 1) return { kind: 'ambiguous', trackIds: byIsrc.map((row) => row.id) };
    }

    const byIdentity = this.handle.db
      .select({ id: tracks.id, durationSeconds: tracks.durationSeconds })
      .from(tracks)
      .where(
        and(
          sql`lower(${tracks.title}) = ${normalize(metadata.title)}`,
          sql`lower(${tracks.artist}) = ${normalize(metadata.artist)}`,
        ),
      )
      .limit(10)
      .all()
      .filter((row) => {
        if (metadata.durationMs === null || row.durationSeconds === null) return true;
        return Math.abs(row.durationSeconds * 1000 - metadata.durationMs) <= 5000;
      });
    if (byIdentity.length === 1) return { kind: 'unique', trackId: byIdentity[0]!.id };
    if (byIdentity.length > 1) return { kind: 'ambiguous', trackIds: byIdentity.map((row) => row.id) };
    return { kind: 'none', trackId: null };
  }

  private findRequestMatches(userId: number, metadata: ParsedImportMetadata): RequestMatch[] {
    const rows = this.handle.db
      .select({
        requestId: musicRequests.id,
        itemId: musicRequestItems.id,
        position: musicRequestItems.position,
        title: musicRequestItems.title,
        artist: musicRequestItems.artist,
        album: musicRequestItems.album,
        durationMs: musicRequestItems.durationMs,
        isrc: musicRequestItems.isrc,
      })
      .from(musicRequestItems)
      .innerJoin(musicRequests, eq(musicRequests.id, musicRequestItems.musicRequestId))
      .where(
        and(
          eq(musicRequests.requestedByUserId, userId),
          inArray(musicRequests.status, [...ACTIVE_MUSIC_REQUEST_STATUSES]),
          inArray(musicRequestItems.status, ['PENDING', 'SEARCHING', 'FOUND', 'IMPORTING']),
        ),
      )
      .all();
    return rows
      .map((row) => {
        let score = 0;
        if (metadata.isrc !== null && row.isrc !== null && metadata.isrc === row.isrc.toUpperCase()) score += 100;
        if (normalize(metadata.title) === normalize(row.title)) score += 35;
        if (normalize(metadata.artist) === normalize(row.artist)) score += 30;
        if (normalize(metadata.album) === normalize(row.album)) score += 15;
        if (
          metadata.durationMs !== null &&
          row.durationMs !== null &&
          Math.abs(metadata.durationMs - row.durationMs) <= 5000
        ) score += 10;
        if (metadata.trackPosition !== null && metadata.trackPosition === row.position) score += 5;
        return { requestId: row.requestId, itemId: row.itemId, score };
      })
      .filter((match) => match.score >= 35)
      .sort((a, b) => b.score - a.score || a.itemId - b.itemId);
  }

  private selectUniqueRequestMatch(matches: RequestMatch[]): RequestMatch | null {
    const first = matches[0];
    if (!first || first.score < REQUEST_MATCH_THRESHOLD) return null;
    const second = matches[1];
    if (second && first.score - second.score < REQUEST_MATCH_MARGIN) return null;
    return first;
  }

  private attachTrackToRequestItem(
    userId: number,
    itemId: number,
    trackId: number,
    ownerId: number | null,
  ): void {
    const item = this.handle.db
      .select({ item: musicRequestItems, requesterId: musicRequests.requestedByUserId })
      .from(musicRequestItems)
      .innerJoin(musicRequests, eq(musicRequests.id, musicRequestItems.musicRequestId))
      .where(eq(musicRequestItems.id, itemId))
      .get();
    if (!item || item.requesterId !== userId) {
      throw new UserImportError('request_item_not_found', 'Item de demande inconnu pour cet utilisateur.');
    }
    const track = this.handle.db.select({ id: tracks.id }).from(tracks).where(eq(tracks.id, trackId)).get();
    if (!track) throw new UserImportError('track_not_found', 'Piste inconnue.');
    grantTrack(this.handle, {
      userId,
      trackId,
      source: ownerId === null ? 'MANUAL_IMPORT' : 'ADMIN',
      addedByUserId: ownerId,
    });
    const now = new Date().toISOString();
    this.handle.db
      .update(musicRequestItems)
      .set({ resultingTrackId: trackId, status: 'IMPORTING', updatedAt: now })
      .where(eq(musicRequestItems.id, itemId))
      .run();
    reconcileMusicRequestStatus(this.handle, item.item.musicRequestId);
  }

  private async moveTo(destinationDir: string, source: string): Promise<string> {
    await mkdir(destinationDir, { recursive: true });
    const extension = extname(source);
    const stem = basename(source, extension);
    let destination = confined(destinationDir, join(destinationDir, basename(source)));
    try {
      await stat(destination);
      destination = confined(destinationDir, join(destinationDir, `${stem}-${Date.now()}${extension}`));
    } catch {
      // Destination libre.
    }
    await rename(source, destination);
    return destination;
  }

  private updateJob(
    jobId: number,
    values: Partial<typeof importJobs.$inferInsert> & { status?: ImportJobStatus },
  ): void {
    this.handle.db
      .update(importJobs)
      .set({ ...values, updatedAt: new Date().toISOString() })
      .where(eq(importJobs.id, jobId))
      .run();
  }

  listJobs(filters: { userId?: number; status?: ImportJobStatus } = {}) {
    const conditions = [];
    if (filters.userId !== undefined) conditions.push(eq(importJobs.userId, filters.userId));
    if (filters.status !== undefined) conditions.push(eq(importJobs.status, filters.status));
    return this.handle.db
      .select({
        job: importJobs,
        username: users.username,
        displayName: users.displayName,
        directoryName: userImportDirectories.directoryName,
        trackTitle: tracks.title,
        trackArtist: tracks.artist,
      })
      .from(importJobs)
      .innerJoin(users, eq(users.id, importJobs.userId))
      .innerJoin(userImportDirectories, eq(userImportDirectories.userId, importJobs.userId))
      .leftJoin(tracks, eq(tracks.id, importJobs.trackId))
      .where(conditions.length > 0 ? and(...conditions) : undefined)
      .orderBy(desc(importJobs.id))
      .all()
      .map((row) => {
        const availableRequestItems = this.handle.db
          .select({
            id: musicRequestItems.id,
            requestId: musicRequests.id,
            position: musicRequestItems.position,
            title: musicRequestItems.title,
            artist: musicRequestItems.artist,
          })
          .from(musicRequestItems)
          .innerJoin(musicRequests, eq(musicRequests.id, musicRequestItems.musicRequestId))
          .where(
            and(
              eq(musicRequests.requestedByUserId, row.job.userId),
              inArray(musicRequests.status, [...ACTIVE_MUSIC_REQUEST_STATUSES]),
              inArray(musicRequestItems.status, ['PENDING', 'SEARCHING', 'FOUND', 'IMPORTING']),
            ),
          )
          .orderBy(desc(musicRequests.id), musicRequestItems.position)
          .all();
        return {
          ...row.job,
          user: { id: row.job.userId, username: row.username, displayName: row.displayName },
          directoryPath: join(this.options.importRoot, row.directoryName),
          track: row.job.trackId === null
            ? null
            : { id: row.job.trackId, title: row.trackTitle, artist: row.trackArtist },
          availableRequestItems,
        };
      });
  }

  async retryJob(jobId: number, ownerId: number): Promise<void> {
    const job = this.handle.db.select().from(importJobs).where(eq(importJobs.id, jobId)).get();
    if (!job) throw new UserImportError('job_not_found', 'Import inconnu.');
    const path = confined(this.options.importRoot, join(this.options.importRoot, job.relativePath));
    this.updateJob(jobId, { status: 'REJECTED' });
    recordAudit(this.handle, {
      action: 'import.retried',
      actorUserId: ownerId,
      targetUserId: job.userId,
      metadata: { jobId },
    });
    await this.processInboxFile(job.userId, path);
  }

  async rejectJob(jobId: number, ownerId: number): Promise<void> {
    const job = this.handle.db.select().from(importJobs).where(eq(importJobs.id, jobId)).get();
    if (!job) throw new UserImportError('job_not_found', 'Import inconnu.');
    const paths = this.getUserPaths(job.userId);
    const source = confined(this.options.importRoot, join(this.options.importRoot, job.relativePath));
    const destination = await this.moveTo(paths.rejected, source);
    this.updateJob(jobId, {
      status: 'REJECTED',
      relativePath: relative(resolve(this.options.importRoot), destination),
      processedAt: new Date().toISOString(),
    });
    recordAudit(this.handle, {
      action: 'import.rejected',
      actorUserId: ownerId,
      targetUserId: job.userId,
      metadata: { jobId },
    });
  }

  assignJob(jobId: number, itemId: number, trackId: number, ownerId: number): void {
    const job = this.handle.db.select().from(importJobs).where(eq(importJobs.id, jobId)).get();
    if (!job) throw new UserImportError('job_not_found', 'Import inconnu.');
    this.attachTrackToRequestItem(job.userId, itemId, trackId, ownerId);
    const item = this.handle.db
      .select({ requestId: musicRequestItems.musicRequestId })
      .from(musicRequestItems)
      .where(eq(musicRequestItems.id, itemId))
      .get();
    this.updateJob(jobId, {
      status: 'REUSED',
      trackId,
      musicRequestId: item?.requestId ?? null,
      musicRequestItemId: itemId,
      matchCandidatesJson: null,
      processedAt: new Date().toISOString(),
    });
    recordAudit(this.handle, {
      action: 'import.manually_matched',
      actorUserId: ownerId,
      targetUserId: job.userId,
      metadata: { jobId, itemId, trackId },
    });
  }
}
