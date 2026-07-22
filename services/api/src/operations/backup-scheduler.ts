import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync } from 'node:fs';
import { join, resolve, sep } from 'node:path';
import type { BackupConfig } from '../config.js';
import {
  createServerBackup,
  type CreateServerBackupOptions,
  type ServerBackupManifest,
} from './server-backup.js';

export interface BackupSchedulerStatus {
  enabled: boolean;
  running: boolean;
  nextRunAt: string | null;
  lastSuccessAt: string | null;
  lastDestination: string | null;
  lastErrorAt: string | null;
  lastError: string | null;
  retentionCount: number;
}

type BackupCreator = (
  options: CreateServerBackupOptions,
) => Promise<ServerBackupManifest>;

export class ServerBackupScheduler {
  private timer: NodeJS.Timeout | null = null;
  private inFlight: Promise<ServerBackupManifest> | null = null;
  private nextRunAt: Date | null = null;
  private lastSuccessAt: string | null = null;
  private lastDestination: string | null = null;
  private lastErrorAt: string | null = null;
  private lastError: string | null = null;

  constructor(
    private readonly config: BackupConfig,
    private readonly paths: { dbPath: string; coversDir: string; musicDir: string },
    private readonly logger: {
      info(context: Record<string, unknown>, message: string): void;
      error(context: Record<string, unknown>, message: string): void;
    },
    private readonly createBackup: BackupCreator = createServerBackup,
    private readonly now: () => Date = () => new Date(),
  ) {
    this.restoreLastKnownSuccess();
  }

  start(): void {
    if (!this.config.enabled || this.timer !== null) return;
    this.scheduleNext();
  }

  stop(): void {
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    this.nextRunAt = null;
  }

  status(): BackupSchedulerStatus {
    return {
      enabled: this.config.enabled,
      running: this.inFlight !== null,
      nextRunAt: this.nextRunAt?.toISOString() ?? null,
      lastSuccessAt: this.lastSuccessAt,
      lastDestination: this.lastDestination,
      lastErrorAt: this.lastErrorAt,
      lastError: this.lastError,
      retentionCount: this.config.retentionCount,
    };
  }

  runNow(): Promise<ServerBackupManifest> {
    const active = this.inFlight;
    if (active !== null) return active;
    const run = this.execute().finally(() => {
      if (this.inFlight === run) this.inFlight = null;
    });
    this.inFlight = run;
    return run;
  }

  private async execute(): Promise<ServerBackupManifest> {
    const startedAt = this.now();
    const destination = join(
      resolve(this.config.root),
      `homespotify-${timestamp(startedAt)}`,
    );
    try {
      const manifest = await this.createBackup({
        dbPath: this.paths.dbPath,
        coversDir: this.paths.coversDir,
        musicDir: this.paths.musicDir,
        destinationDir: destination,
        includeMedia: false,
        now: startedAt,
      });
      this.lastSuccessAt = manifest.createdAt;
      this.lastDestination = destination;
      this.lastErrorAt = null;
      this.lastError = null;
      this.prune();
      this.logger.info(
        { destination, databaseBytes: manifest.database.bytes },
        'DAILY_BACKUP_COMPLETED',
      );
      return manifest;
    } catch (error) {
      this.lastErrorAt = this.now().toISOString();
      this.lastError = error instanceof Error ? error.message.slice(0, 300) : 'Erreur inconnue.';
      this.logger.error({ error: this.lastError }, 'DAILY_BACKUP_FAILED');
      throw error;
    }
  }

  private scheduleNext(): void {
    const now = this.now();
    const next = new Date(now);
    next.setHours(this.config.hourLocal, 0, 0, 0);
    if (next.getTime() <= now.getTime()) next.setDate(next.getDate() + 1);
    this.nextRunAt = next;
    const delayMs = Math.max(1_000, next.getTime() - now.getTime());
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.runNow()
        .catch(() => undefined)
        .finally(() => this.scheduleNext());
    }, delayMs);
    this.timer.unref();
  }

  private prune(): void {
    const root = resolve(this.config.root);
    if (!existsSync(root)) return;
    const candidates = readdirSync(root, { withFileTypes: true })
      .filter(
        (entry) =>
          entry.isDirectory() &&
          entry.name.startsWith('homespotify-') &&
          existsSync(join(root, entry.name, 'manifest.json')),
      )
      .map((entry) => entry.name)
      .sort()
      .reverse();
    for (const name of candidates.slice(this.config.retentionCount)) {
      const target = resolve(root, name);
      if (!target.startsWith(`${root}${sep}`)) continue;
      rmSync(target, { recursive: true, force: true });
    }
  }

  private restoreLastKnownSuccess(): void {
    const root = resolve(this.config.root);
    if (!existsSync(root)) return;
    const candidates = readdirSync(root, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && entry.name.startsWith('homespotify-'))
      .map((entry) => join(root, entry.name, 'manifest.json'))
      .filter(existsSync);
    for (const manifestPath of candidates) {
      try {
        const manifest = JSON.parse(readFileSync(manifestPath, 'utf8')) as {
          createdAt?: unknown;
        };
        if (
          typeof manifest.createdAt === 'string' &&
          (this.lastSuccessAt === null || manifest.createdAt > this.lastSuccessAt)
        ) {
          this.lastSuccessAt = manifest.createdAt;
          this.lastDestination = resolve(manifestPath, '..');
        }
      } catch {
        // Un dossier incomplet n'est ni considéré comme succès ni supprimé.
      }
    }
  }
}

function timestamp(value: Date): string {
  const pad = (part: number, length = 2) => String(part).padStart(length, '0');
  return [
    value.getFullYear(),
    pad(value.getMonth() + 1),
    pad(value.getDate()),
    '-',
    pad(value.getHours()),
    pad(value.getMinutes()),
    pad(value.getSeconds()),
    '-',
    pad(value.getMilliseconds(), 3),
  ].join('');
}
