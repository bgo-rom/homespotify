import { createHash, randomUUID } from 'node:crypto';
import { once } from 'node:events';
import {
  createReadStream,
  mkdirSync,
  readdirSync,
  rmSync,
  statfsSync,
  statSync,
} from 'node:fs';
import { open, rename, unlink, type FileHandle } from 'node:fs/promises';
import { join } from 'node:path';
import { performance } from 'node:perf_hooks';
import { Readable, Transform, type TransformCallback } from 'node:stream';
import {
  AudioStorageError,
  type AudioFileInfo,
  type AudioStorageProvider,
  type ByteRange,
  type StorageHealth,
  type StorageRequestContext,
  type TrackStorageReference,
} from '../audio-storage.js';
import {
  SILENT_REMOTE_LOGGER,
  type RemoteLogger,
} from '../remote/storage-agent-client.js';
import type { AudioCacheConfig } from './cache-config.js';
import { CacheIndex, type CacheEntry } from './cache-index.js';

const SHA256 = /^[a-f0-9]{64}$/;

interface CacheCounters {
  hitCount: number;
  missCount: number;
  fillCount: number;
  evictionCount: number;
  corruptionCount: number;
}

class CacheFillStream extends Transform {
  private bytesWritten = 0;
  private readonly hash = createHash('sha256');
  private caching = true;
  private promoted = false;
  private released = false;

  constructor(
    private readonly upstream: Readable,
    private readonly handle: FileHandle,
    private readonly partPath: string,
    private readonly finalPath: string,
    private readonly expectedSize: number,
    private readonly expectedHash: string,
    private readonly completed: () => void,
    private readonly failed: (reason: string) => void,
    private readonly release: () => void,
  ) {
    super({ highWaterMark: 256 * 1024 });
    upstream.once('error', (error) => this.destroy(error));
    upstream.pipe(this);
  }

  private releaseOnce(): void {
    if (this.released) return;
    this.released = true;
    this.release();
  }

  private async abandonCache(reason: string): Promise<void> {
    if (!this.caching) return;
    this.caching = false;
    await this.handle.close().catch(() => undefined);
    await unlink(this.partPath).catch(() => undefined);
    this.failed(reason);
  }

  override _transform(
    chunk: Buffer,
    _encoding: BufferEncoding,
    callback: TransformCallback,
  ): void {
    if (!this.caching) {
      callback(null, chunk);
      return;
    }
    this.handle
      .writeFile(chunk)
      .then(() => {
        this.hash.update(chunk);
        this.bytesWritten += chunk.length;
        callback(null, chunk);
      })
      .catch(async () => {
        await this.abandonCache('CACHE_WRITE_FAILED');
        callback(null, chunk);
      });
  }

  override _flush(callback: TransformCallback): void {
    if (!this.caching) {
      this.releaseOnce();
      callback();
      return;
    }
    const digest = this.hash.digest('hex');
    if (this.bytesWritten !== this.expectedSize || digest !== this.expectedHash) {
      void this.abandonCache(
        this.bytesWritten === this.expectedSize
          ? 'CACHE_CORRUPT'
          : 'CACHE_FILL_TRUNCATED',
      ).then(() => {
        this.releaseOnce();
        callback();
      });
      return;
    }
    void this.handle
      .sync()
      .then(() => this.handle.close())
      .then(() => rename(this.partPath, this.finalPath))
      .then(() => {
        this.promoted = true;
        this.completed();
        this.releaseOnce();
        callback();
      })
      .catch(async () => {
        await this.abandonCache('CACHE_WRITE_FAILED');
        this.releaseOnce();
        callback();
      });
  }

  override _destroy(
    error: Error | null,
    callback: (error?: Error | null) => void,
  ): void {
    if (!this.upstream.destroyed) this.upstream.destroy(error ?? undefined);
    const cleanup = this.promoted
      ? Promise.resolve()
      : this.abandonCache(error === null ? 'CACHE_FILL_ABORTED' : 'CACHE_FILL_FAILED');
    void cleanup.finally(() => {
      this.releaseOnce();
      callback(error);
    });
  }
}

export class CachedAudioStorageProvider implements AudioStorageProvider {
  private readonly objectsRoot: string;
  private readonly tempRoot: string;
  private readonly metadataRoot: string;
  private readonly index: CacheIndex;
  private readonly fills = new Map<string, CacheFillStream>();
  private readonly activeReads = new Map<string, number>();
  private readonly counters: CacheCounters = {
    hitCount: 0,
    missCount: 0,
    fillCount: 0,
    evictionCount: 0,
    corruptionCount: 0,
  };
  private shuttingDown = false;

  constructor(
    private readonly upstream: AudioStorageProvider,
    private readonly config: AudioCacheConfig,
    private readonly logger: RemoteLogger = SILENT_REMOTE_LOGGER,
  ) {
    this.objectsRoot = join(config.root, 'objects');
    this.tempRoot = join(config.root, 'tmp');
    this.metadataRoot = join(config.root, 'metadata');
    mkdirSync(this.objectsRoot, { recursive: true });
    mkdirSync(this.tempRoot, { recursive: true });
    mkdirSync(this.metadataRoot, { recursive: true });
    this.index = new CacheIndex(join(this.metadataRoot, 'cache-index.sqlite'));
    this.recover();
  }

  private objectPath(hash: string): string {
    return join(this.objectsRoot, hash.slice(0, 2), `${hash}.audio`);
  }

  private log(
    level: 'info' | 'warn' | 'error',
    event: string,
    reference: TrackStorageReference,
    context?: StorageRequestContext,
    fields: Record<string, unknown> = {},
  ): void {
    this.logger[level](
      {
        event,
        requestId: context?.requestId,
        trackId: reference.trackId,
        contentHashPrefix: reference.contentHash.slice(0, 12),
        ...fields,
      },
      event,
    );
  }

  private recover(): void {
    const cutoff = Date.now() - this.config.tempMaxAgeMs;
    for (const item of readdirSync(this.tempRoot, { withFileTypes: true })) {
      if (!item.isFile() || !item.name.endsWith('.part')) continue;
      const path = join(this.tempRoot, item.name);
      if (statSync(path).mtimeMs < cutoff) rmSync(path, { force: true });
    }
    const indexed = new Set(this.index.all().map((value) => value.contentHash));
    for (const value of this.index.all()) {
      const path = this.objectPath(value.contentHash);
      try {
        if (statSync(path).size !== value.sizeBytes) {
          rmSync(path, { force: true });
          this.index.delete(value.contentHash);
          this.counters.corruptionCount++;
        }
      } catch {
        this.index.delete(value.contentHash);
        this.counters.corruptionCount++;
      }
    }
    for (const prefix of readdirSync(this.objectsRoot, { withFileTypes: true })) {
      if (!prefix.isDirectory()) continue;
      const directory = join(this.objectsRoot, prefix.name);
      for (const object of readdirSync(directory, { withFileTypes: true })) {
        const match = object.isFile() ? /^([a-f0-9]{64})\.audio$/.exec(object.name) : null;
        if (match !== null && !indexed.has(match[1] as string)) {
          rmSync(join(directory, object.name), { force: true });
        }
      }
    }
  }

  private cached(reference: TrackStorageReference): CacheEntry | undefined {
    if (!SHA256.test(reference.contentHash)) return undefined;
    const value = this.index.get(reference.contentHash);
    if (value === undefined) return undefined;
    try {
      if (statSync(this.objectPath(reference.contentHash)).size !== value.sizeBytes) {
        throw new Error('size mismatch');
      }
    } catch {
      rmSync(this.objectPath(reference.contentHash), { force: true });
      this.index.delete(reference.contentHash);
      this.counters.corruptionCount++;
      this.log('warn', 'CACHE_CORRUPT_ENTRY', reference);
      return undefined;
    }
    this.index.touch(reference.contentHash);
    return value;
  }

  async stat(
    reference: TrackStorageReference,
    context?: StorageRequestContext,
  ): Promise<AudioFileInfo> {
    const startedAt = performance.now();
    const value = this.cached(reference);
    if (value !== undefined) {
      this.counters.hitCount++;
      this.log('info', 'CACHE_HIT', reference, context, {
        operation: 'stat',
        durationMs: performance.now() - startedAt,
        sizeBytes: value.sizeBytes,
      });
      return {
        sizeBytes: value.sizeBytes,
        modifiedAt: new Date(value.modifiedAtMs),
        source: 'cache',
        ...(value.contentType === null ? {} : { contentType: value.contentType }),
      };
    }
    this.counters.missCount++;
    this.log('info', 'CACHE_MISS', reference, context, { operation: 'stat' });
    return this.upstream.stat(reference, context);
  }

  private protect(hash: string, stream: Readable): Readable {
    this.activeReads.set(hash, (this.activeReads.get(hash) ?? 0) + 1);
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      const remaining = (this.activeReads.get(hash) ?? 1) - 1;
      if (remaining <= 0) this.activeReads.delete(hash);
      else this.activeReads.set(hash, remaining);
    };
    stream.once('close', release);
    stream.once('end', release);
    stream.once('error', release);
    return stream;
  }

  private diskFreeBytes(): number {
    const info = statfsSync(this.config.root);
    return info.bavail * info.bsize;
  }

  private ensureCapacity(requiredBytes: number, reference: TrackStorageReference): boolean {
    const totals = this.index.totals();
    const target = Math.floor(this.config.maxBytes * this.config.evictionTargetRatio);
    const needsEviction =
      totals.totalBytes + requiredBytes > this.config.maxBytes ||
      this.diskFreeBytes() - requiredBytes < this.config.minFreeBytes;
    if (!needsEviction) return true;
    this.log('info', 'CACHE_EVICTION_STARTED', reference, undefined, {
      totalBytes: totals.totalBytes,
    });
    let current = totals.totalBytes;
    for (const candidate of this.index.lru()) {
      if (
        this.activeReads.has(candidate.contentHash) ||
        this.fills.has(candidate.contentHash)
      ) {
        continue;
      }
      rmSync(this.objectPath(candidate.contentHash), { force: true });
      this.index.delete(candidate.contentHash);
      current -= candidate.sizeBytes;
      this.counters.evictionCount++;
      this.logger.info(
        {
          event: 'CACHE_EVICTED',
          contentHashPrefix: candidate.contentHash.slice(0, 12),
          sizeBytes: candidate.sizeBytes,
        },
        'CACHE_EVICTED',
      );
      if (
        current + requiredBytes <= target &&
        this.diskFreeBytes() - requiredBytes >= this.config.minFreeBytes
      ) {
        break;
      }
    }
    const available =
      current + requiredBytes <= this.config.maxBytes &&
      this.diskFreeBytes() - requiredBytes >= this.config.minFreeBytes;
    if (!available) {
      this.log('warn', 'CACHE_DISK_PRESSURE', reference, undefined, {
        totalBytes: current,
        diskFreeBytes: this.diskFreeBytes(),
      });
    }
    return available;
  }

  async createReadStream(
    reference: TrackStorageReference,
    range?: ByteRange,
    context?: StorageRequestContext,
  ): Promise<Readable> {
    const value = this.cached(reference);
    if (value !== undefined) {
      this.counters.hitCount++;
      this.log('info', 'CACHE_HIT', reference, context, {
        operation: 'read',
        rangeStart: range?.start,
        rangeEnd: range?.end,
      });
      return this.protect(
        reference.contentHash,
        createReadStream(this.objectPath(reference.contentHash), {
          ...(range === undefined ? {} : { start: range.start, end: range.end }),
          highWaterMark: 256 * 1024,
        }),
      );
    }
    this.counters.missCount++;
    this.log('info', 'CACHE_MISS', reference, context, {
      operation: 'read',
      rangeStart: range?.start,
      rangeEnd: range?.end,
    });
    if (
      range !== undefined ||
      !this.config.fillOnFullGet ||
      !SHA256.test(reference.contentHash) ||
      this.shuttingDown ||
      this.fills.has(reference.contentHash)
    ) {
      this.log('info', 'CACHE_BYPASS', reference, context, {
        reason:
          range !== undefined
            ? 'RANGE_MISS'
            : this.fills.has(reference.contentHash)
              ? 'SINGLE_FLIGHT_ACTIVE'
              : 'CACHE_DISABLED_FOR_REQUEST',
      });
      return this.upstream.createReadStream(reference, range, context);
    }
    const info = await this.upstream.stat(reference, context);
    if (!this.ensureCapacity(info.sizeBytes, reference)) {
      return this.upstream.createReadStream(reference, undefined, context);
    }
    const upstream = await this.upstream.createReadStream(reference, undefined, context);
    const directory = join(this.objectsRoot, reference.contentHash.slice(0, 2));
    mkdirSync(directory, { recursive: true });
    const partPath = join(
      this.tempRoot,
      `${reference.contentHash}.${randomUUID()}.part`,
    );
    const handle = await open(partPath, 'wx', 0o600);
    const finalPath = this.objectPath(reference.contentHash);
    const now = Date.now();
    const fill = new CacheFillStream(
      upstream,
      handle,
      partPath,
      finalPath,
      info.sizeBytes,
      reference.contentHash,
      () => {
        this.index.put({
          contentHash: reference.contentHash,
          trackId: reference.trackId,
          sizeBytes: info.sizeBytes,
          contentType: info.contentType ?? null,
          modifiedAtMs: info.modifiedAt.getTime(),
          createdAtMs: now,
          lastAccessMs: Date.now(),
        });
        this.counters.fillCount++;
        this.log('info', 'CACHE_FILL_COMPLETED', reference, context, {
          bytesWritten: info.sizeBytes,
        });
      },
      (reason) => this.log('warn', reason, reference, context),
      () => this.fills.delete(reference.contentHash),
    );
    this.fills.set(reference.contentHash, fill);
    this.log('info', 'CACHE_FILL_STARTED', reference, context, {
      sizeBytes: info.sizeBytes,
    });
    setImmediate(() => fill.emit('open'));
    return fill;
  }

  async healthCheck(): Promise<StorageHealth> {
    const startedAt = performance.now();
    try {
      statSync(this.config.root);
      this.index.totals();
      return {
        status: 'online',
        source: 'cache',
        latencyMs: performance.now() - startedAt,
      };
    } catch {
      return { status: 'degraded', reason: 'Cache audio indisponible.' };
    }
  }

  metrics(): CacheCounters & {
    entryCount: number;
    totalBytes: number;
    maxBytes: number;
    diskFreeBytes: number;
    tempFileCount: number;
  } {
    return {
      ...this.counters,
      ...this.index.totals(),
      maxBytes: this.config.maxBytes,
      diskFreeBytes: this.diskFreeBytes(),
      tempFileCount: readdirSync(this.tempRoot).filter((name) => name.endsWith('.part')).length,
    };
  }

  async close(): Promise<void> {
    this.shuttingDown = true;
    const activeFills = [...this.fills.values()];
    const closed = activeFills.map((fill) =>
      fill.destroyed ? Promise.resolve() : once(fill, 'close').then(() => undefined),
    );
    for (const fill of activeFills) fill.destroy();
    await Promise.all(closed);
    this.fills.clear();
    this.index.close();
    await this.upstream.close?.();
  }
}
