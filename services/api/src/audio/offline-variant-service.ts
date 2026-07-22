import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { mkdir, rename, stat, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { and, eq, ne } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import { trackOfflineVariants, tracks } from '../db/schema.js';

/**
 * Encodage serveur des variantes hors ligne (Phase 1A — TD-Offline-Opus).
 *
 * Invariants :
 *  - le fichier canonique WAV/FLAC n'est JAMAIS modifié, renommé ni réécrit ;
 *  - single-flight par (sourceSha256, profileVersion, encoderVersion) — 128 et
 *    256 ne partagent jamais une identité ;
 *  - aucun transcodage pendant une réponse HTTP : tout passe par la file ;
 *  - un fichier n'est publié (renommage atomique) qu'après validation ffprobe,
 *    cohérence de durée, taille et SHA-256 calculé en flux ;
 *  - aucun fichier audio complet en RAM (spawn + streams + hash streaming).
 */

export const OFFLINE_PROFILES = ['opus_128', 'opus_256'] as const;
export type OfflineProfileId = (typeof OFFLINE_PROFILES)[number];

export interface OfflineProfileSpec {
  profile: OfflineProfileId;
  profileVersion: string;
  targetBitrateKbps: number;
}

export const OFFLINE_PROFILE_SPECS: Record<OfflineProfileId, OfflineProfileSpec> = {
  opus_128: { profile: 'opus_128', profileVersion: 'opus-128-v1', targetBitrateKbps: 128 },
  opus_256: { profile: 'opus_256', profileVersion: 'opus-256-v1', targetBitrateKbps: 256 },
};

export function isOfflineProfile(value: string): value is OfflineProfileId {
  return (OFFLINE_PROFILES as readonly string[]).includes(value);
}

/**
 * Estimation DÉTERMINISTE de la taille d'une dérivée Opus avant encodage :
 * durée × débit cible. Affichée « estimée » — jamais confondue avec une mesure.
 */
export function estimateOpusSizeBytes(durationSeconds: number, targetBitrateKbps: number): number {
  return Math.ceil(durationSeconds * targetBitrateKbps * 125); // kbps → octets/s = ×1000/8
}

export interface OpusProbeResult {
  formatName: string;
  codecName: string;
  durationSeconds: number | null;
  bitrateKbps: number | null;
}

/**
 * Exécution ffmpeg/ffprobe injectable : les tests ne lancent JAMAIS de vrai
 * processus (même modèle que TrackBpmAnalyzer).
 */
export interface OpusEncoderRunner {
  /** Identité stable de l'encodeur (participe à la clé de variante). */
  encoderVersion(): Promise<string>;
  encode(
    sourceAbsPath: string,
    targetAbsPath: string,
    targetBitrateKbps: number,
    signal?: AbortSignal,
  ): Promise<void>;
  probe(fileAbsPath: string): Promise<OpusProbeResult>;
}

const ENCODE_TIMEOUT_MS = 10 * 60 * 1000;
const PROBE_TIMEOUT_MS = 30 * 1000;

function runProcess(
  command: string,
  args: string[],
  timeoutMs: number,
  signal?: AbortSignal,
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    if (signal?.aborted) {
      reject(new Error(`Exécution annulée pour ${command}.`));
      return;
    }
    const child = spawn(command, args, { stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true });
    let stdout = '';
    let stderr = '';
    let settled = false;
    let terminationError: Error | null = null;
    const finish = (error: Error | null): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener('abort', abortProcess);
      if (error) reject(error);
      else resolve({ stdout, stderr });
    };
    const terminateProcess = (error: Error): void => {
      if (settled || terminationError !== null) return;
      terminationError = error;
      child.kill('SIGKILL');
    };
    const abortProcess = (): void => terminateProcess(new Error(`Exécution annulée pour ${command}.`));
    signal?.addEventListener('abort', abortProcess, { once: true });
    const timer = setTimeout(() => {
      terminateProcess(new Error(`Délai dépassé pour ${command} (${timeoutMs} ms).`));
    }, timeoutMs);
    child.stdout.on('data', (chunk: Buffer) => {
      stdout += chunk.toString('utf-8');
    });
    child.stderr.on('data', (chunk: Buffer) => {
      // Queue bornée : seules les dernières lignes comptent pour le diagnostic.
      stderr = (stderr + chunk.toString('utf-8')).slice(-4000);
    });
    child.once('error', (error) => finish(new Error(`${command} introuvable ou non exécutable : ${error.message}`)));
    child.once('close', (code) => {
      if (terminationError !== null) {
        finish(terminationError);
        return;
      }
      if (code === 0) finish(null);
      else finish(new Error(stderr.trim() || `${command} terminé avec le code ${code ?? 'inconnu'}.`));
    });
  });
}

/** Runner réel : FFMPEG_PATH / FFPROBE_PATH (.env) sinon binaires du PATH. */
export class FfmpegOpusEncoderRunner implements OpusEncoderRunner {
  private versionPromise: Promise<string> | null = null;

  constructor(
    private readonly ffmpegPath = process.env.FFMPEG_PATH ?? 'ffmpeg',
    private readonly ffprobePath = process.env.FFPROBE_PATH ?? 'ffprobe',
  ) {}

  encoderVersion(): Promise<string> {
    this.versionPromise ??= runProcess(this.ffmpegPath, ['-version'], PROBE_TIMEOUT_MS).then(
      ({ stdout }) => {
        const firstLine = stdout.split(/\r?\n/, 1)[0]?.trim() ?? '';
        const match = /ffmpeg version (\S+)/.exec(firstLine);
        if (!match || match[1] === undefined) {
          throw new Error(`Version ffmpeg illisible : "${firstLine}"`);
        }
        return `ffmpeg-${match[1]}`;
      },
    );
    return this.versionPromise;
  }

  async encode(
    sourceAbsPath: string,
    targetAbsPath: string,
    targetBitrateKbps: number,
    signal?: AbortSignal,
  ): Promise<void> {
    // libopus VBR, application audio, conteneur Ogg. Lecture/écriture en flux :
    // ffmpeg ne charge jamais le fichier entier en mémoire.
    await runProcess(
      this.ffmpegPath,
      [
        '-hide_banner',
        '-nostdin',
        '-y',
        '-i', sourceAbsPath,
        '-vn',
        '-map_metadata', '0',
        '-c:a', 'libopus',
        '-b:a', `${targetBitrateKbps}k`,
        '-vbr', 'on',
        '-application', 'audio',
        '-f', 'ogg',
        targetAbsPath,
      ],
      ENCODE_TIMEOUT_MS,
      signal,
    );
  }

  async probe(fileAbsPath: string): Promise<OpusProbeResult> {
    const { stdout } = await runProcess(
      this.ffprobePath,
      [
        '-v', 'error',
        '-show_entries', 'format=format_name,duration,bit_rate',
        '-show_entries', 'stream=codec_name,codec_type',
        '-of', 'json',
        fileAbsPath,
      ],
      PROBE_TIMEOUT_MS,
    );
    const parsed = JSON.parse(stdout) as {
      format?: { format_name?: string; duration?: string; bit_rate?: string };
      streams?: Array<{ codec_name?: string; codec_type?: string }>;
    };
    const audioStream = parsed.streams?.find((s) => s.codec_type === 'audio');
    const duration = Number(parsed.format?.duration);
    const bitRate = Number(parsed.format?.bit_rate);
    return {
      formatName: parsed.format?.format_name ?? '',
      codecName: audioStream?.codec_name ?? '',
      durationSeconds: Number.isFinite(duration) ? duration : null,
      bitrateKbps: Number.isFinite(bitRate) && bitRate > 0 ? Math.round(bitRate / 1000) : null,
    };
  }
}

function sha256OfFile(absPath: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const hash = createHash('sha256');
    const stream = createReadStream(absPath);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.once('error', reject);
    stream.once('end', () => resolve(hash.digest('hex')));
  });
}

export interface OfflineVariantLogger {
  info(context: Record<string, unknown>, message: string): void;
  warn(context: Record<string, unknown>, message: string): void;
  error(context: Record<string, unknown>, message: string): void;
}

const silentLogger: OfflineVariantLogger = { info: () => {}, warn: () => {}, error: () => {} };

export interface OfflineVariantServiceOptions {
  musicDir: string;
  derivedCacheDir: string;
  encodeConcurrency: number;
  runner: OpusEncoderRunner;
  logger?: OfflineVariantLogger;
}

export type OfflineVariantRow = typeof trackOfflineVariants.$inferSelect;
type TrackRow = typeof tracks.$inferSelect;

/** Tolérance de durée : 2 s ou 5 % de la source (la plus grande des deux). */
function durationToleranceSeconds(sourceDuration: number): number {
  return Math.max(2, sourceDuration * 0.05);
}

export class OfflineVariantService {
  private readonly queue: number[] = [];
  private readonly inFlight = new Set<number>();
  private readonly activeEncodes = new Map<number, AbortController>();
  private running = 0;
  private stopped = false;

  constructor(
    private readonly handle: DbHandle,
    private readonly options: OfflineVariantServiceOptions,
  ) {}

  private get log(): OfflineVariantLogger {
    return this.options.logger ?? silentLogger;
  }

  /** Chemin absolu d'une variante publiée. `row.path` est toujours relatif. */
  absolutePathFor(row: OfflineVariantRow): string | null {
    if (row.path === null) return null;
    return join(this.options.derivedCacheDir, row.path);
  }

  /**
   * Variante correspondant à l'IDENTITÉ COURANTE de la piste (hash source
   * actuel + version d'encodeur active), ou undefined. Marque au passage STALE
   * toute variante de la piste dont la source a changé.
   */
  async getCurrentVariant(track: TrackRow, profile: OfflineProfileId): Promise<OfflineVariantRow | undefined> {
    this.markStaleVariants(track);
    const spec = OFFLINE_PROFILE_SPECS[profile];
    const encoderVersion = await this.options.runner.encoderVersion();
    const row = this.handle.db
      .select()
      .from(trackOfflineVariants)
      .where(
        and(
          eq(trackOfflineVariants.sourceSha256, track.hash),
          eq(trackOfflineVariants.profileVersion, spec.profileVersion),
          eq(trackOfflineVariants.encoderVersion, encoderVersion),
        ),
      )
      .get();
    if (row?.status !== 'READY') return row;

    const absPath = this.absolutePathFor(row);
    const fileExists = absPath !== null && await stat(absPath).then((info) => info.isFile() && info.size > 0, () => false);
    if (fileExists) return row;

    const now = new Date().toISOString();
    this.handle.db
      .update(trackOfflineVariants)
      .set({
        status: 'PENDING',
        path: null,
        sha256: null,
        sizeBytes: null,
        measuredBitrateKbps: null,
        errorMessage: null,
        readyAt: null,
        updatedAt: now,
      })
      .where(eq(trackOfflineVariants.id, row.id))
      .run();
    this.enqueue(row.id);
    this.log.warn(
      { variantId: row.id, trackId: track.id, profile },
      'variante READY absente du disque : régénération planifiée',
    );
    return {
      ...row,
      status: 'PENDING',
      path: null,
      sha256: null,
      sizeBytes: null,
      measuredBitrateKbps: null,
      errorMessage: null,
      readyAt: null,
      updatedAt: now,
    };
  }

  /** Source remplacée (hash différent) → toutes ses anciennes variantes deviennent STALE. */
  markStaleVariants(track: TrackRow): void {
    this.handle.db
      .update(trackOfflineVariants)
      .set({ status: 'STALE', updatedAt: new Date().toISOString() })
      .where(
        and(
          eq(trackOfflineVariants.trackId, track.id),
          ne(trackOfflineVariants.sourceSha256, track.hash),
          ne(trackOfflineVariants.status, 'STALE'),
        ),
      )
      .run();
  }

  /**
   * Demande (ou retrouve) la variante pour l'identité courante. Single-flight :
   * une identité déjà PENDING/ENCODING/READY est réutilisée telle quelle ; un
   * FAILED est réarmé. Retourne la ligne à jour.
   */
  async requestVariant(track: TrackRow, profile: OfflineProfileId): Promise<OfflineVariantRow> {
    const spec = OFFLINE_PROFILE_SPECS[profile];
    const existing = await this.getCurrentVariant(track, profile);
    const now = new Date().toISOString();
    if (existing !== undefined) {
      if (existing.status === 'FAILED' || existing.status === 'STALE') {
        // STALE ici = même hash source : réarmement après changement d'état manuel.
        this.handle.db
          .update(trackOfflineVariants)
          .set({ status: 'PENDING', errorMessage: null, updatedAt: now })
          .where(eq(trackOfflineVariants.id, existing.id))
          .run();
        this.enqueue(existing.id);
        return { ...existing, status: 'PENDING', errorMessage: null, updatedAt: now };
      }
      if (existing.status === 'PENDING') this.enqueue(existing.id);
      return existing;
    }
    const encoderVersion = await this.options.runner.encoderVersion();
    const inserted = this.handle.db
      .insert(trackOfflineVariants)
      .values({
        trackId: track.id,
        sourceSha256: track.hash,
        profile: spec.profile,
        profileVersion: spec.profileVersion,
        encoderVersion,
        status: 'PENDING',
        targetBitrateKbps: spec.targetBitrateKbps,
        durationSeconds: track.durationSeconds,
        createdAt: now,
        updatedAt: now,
      })
      .onConflictDoNothing()
      .returning()
      .get();
    if (inserted === undefined) {
      // Course perdue : une insertion concurrente a créé la même identité.
      const winner = await this.getCurrentVariant(track, profile);
      if (winner === undefined) throw new Error('Variante introuvable après conflit d’insertion.');
      return winner;
    }
    this.enqueue(inserted.id);
    return inserted;
  }

  /** Reprise au démarrage : les ENCODING interrompus redeviennent PENDING puis repartent. */
  resumePendingJobs(): void {
    const now = new Date().toISOString();
    this.handle.db
      .update(trackOfflineVariants)
      .set({ status: 'PENDING', updatedAt: now })
      .where(eq(trackOfflineVariants.status, 'ENCODING'))
      .run();
    const pending = this.handle.db
      .select({ id: trackOfflineVariants.id })
      .from(trackOfflineVariants)
      .where(eq(trackOfflineVariants.status, 'PENDING'))
      .all();
    for (const row of pending) this.enqueue(row.id);
  }

  stop(): void {
    this.stopped = true;
    this.queue.length = 0;
    for (const controller of this.activeEncodes.values()) controller.abort();
  }

  /** Attend la fin de tous les encodages en file (tests + arrêt propre). */
  async drain(): Promise<void> {
    while (this.running > 0 || this.queue.length > 0) {
      await new Promise((resolve) => setTimeout(resolve, 10));
    }
  }

  private enqueue(variantId: number): void {
    if (this.stopped || this.inFlight.has(variantId) || this.queue.includes(variantId)) return;
    this.queue.push(variantId);
    queueMicrotask(() => void this.processNext());
  }

  private async processNext(): Promise<void> {
    if (this.stopped || this.running >= this.options.encodeConcurrency) return;
    const variantId = this.queue.shift();
    if (variantId === undefined) return;
    if (this.inFlight.has(variantId)) return;
    this.inFlight.add(variantId);
    this.running += 1;
    try {
      await this.encodeVariant(variantId);
    } catch (error) {
      this.log.error({ err: error, variantId }, 'encodage hors ligne : erreur inattendue');
    } finally {
      this.running -= 1;
      this.inFlight.delete(variantId);
      if (this.queue.length > 0) queueMicrotask(() => void this.processNext());
    }
  }

  private variantFileName(row: OfflineVariantRow): string {
    const encoderHash = createHash('sha256').update(row.encoderVersion).digest('hex').slice(0, 8);
    return `${row.sourceSha256}.${row.profileVersion}.${encoderHash}.ogg`;
  }

  private async encodeVariant(variantId: number): Promise<void> {
    const row = this.handle.db
      .select()
      .from(trackOfflineVariants)
      .where(eq(trackOfflineVariants.id, variantId))
      .get();
    if (row === undefined || row.status !== 'PENDING') return;
    const track = this.handle.db.select().from(tracks).where(eq(tracks.id, row.trackId)).get();
    const now = new Date().toISOString();
    if (track === undefined || track.hash !== row.sourceSha256) {
      this.handle.db
        .update(trackOfflineVariants)
        .set({ status: 'STALE', updatedAt: now })
        .where(eq(trackOfflineVariants.id, variantId))
        .run();
      return;
    }
    this.handle.db
      .update(trackOfflineVariants)
      .set({ status: 'ENCODING', attempts: row.attempts + 1, updatedAt: now })
      .where(eq(trackOfflineVariants.id, variantId))
      .run();

    const fileName = this.variantFileName(row);
    const finalAbsPath = join(this.options.derivedCacheDir, fileName);
    // `.part` confiné sous le cache : jamais publié tel quel.
    const partAbsPath = `${finalAbsPath}.part`;
    const sourceAbsPath = join(this.options.musicDir, track.path);
    const abortController = new AbortController();
    this.activeEncodes.set(variantId, abortController);
    try {
      await mkdir(this.options.derivedCacheDir, { recursive: true });
      await this.options.runner.encode(
        sourceAbsPath,
        partAbsPath,
        row.targetBitrateKbps,
        abortController.signal,
      );
      const probe = await this.options.runner.probe(partAbsPath);
      this.validateProbe(probe, track);
      const info = await stat(partAbsPath);
      if (info.size <= 0) throw new Error('Dérivée vide après encodage.');
      const sha256 = await sha256OfFile(partAbsPath);
      await rename(partAbsPath, finalAbsPath); // publication atomique
      this.handle.db
        .update(trackOfflineVariants)
        .set({
          status: 'READY',
          measuredBitrateKbps: probe.bitrateKbps,
          durationSeconds: probe.durationSeconds ?? track.durationSeconds,
          sizeBytes: info.size,
          sha256,
          path: fileName,
          errorMessage: null,
          updatedAt: new Date().toISOString(),
          readyAt: new Date().toISOString(),
        })
        .where(eq(trackOfflineVariants.id, variantId))
        .run();
      this.log.info(
        { variantId, trackId: track.id, profile: row.profile, sizeBytes: info.size },
        'variante hors ligne publiée',
      );
    } catch (error) {
      await unlink(partAbsPath).catch(() => {});
      const message = error instanceof Error ? error.message : String(error);
      this.handle.db
        .update(trackOfflineVariants)
        .set(this.stopped
          ? { status: 'PENDING', errorMessage: null, updatedAt: new Date().toISOString() }
          : { status: 'FAILED', errorMessage: message.slice(0, 500), updatedAt: new Date().toISOString() })
        .where(eq(trackOfflineVariants.id, variantId))
        .run();
      if (!this.stopped) {
        this.log.warn({ variantId, trackId: track.id, err: error }, 'encodage hors ligne échoué');
      }
    } finally {
      this.activeEncodes.delete(variantId);
    }
  }

  /** Rejette toute dérivée non conforme AVANT publication. */
  private validateProbe(probe: OpusProbeResult, track: TrackRow): void {
    if (!probe.formatName.toLowerCase().includes('ogg')) {
      throw new Error(`Conteneur inattendu "${probe.formatName}" (Ogg requis).`);
    }
    if (probe.codecName.toLowerCase() !== 'opus') {
      throw new Error(`Codec inattendu "${probe.codecName}" (opus requis).`);
    }
    if (probe.durationSeconds === null || probe.durationSeconds <= 0) {
      throw new Error('Durée de la dérivée absente ou invalide dans ffprobe.');
    }
    if (probe.bitrateKbps === null || probe.bitrateKbps <= 0) {
      throw new Error('Débit de la dérivée absent ou invalide dans ffprobe.');
    }
    if (track.durationSeconds !== null) {
      const delta = Math.abs(probe.durationSeconds - track.durationSeconds);
      if (delta > durationToleranceSeconds(track.durationSeconds)) {
        throw new Error(
          `Durée incohérente : source ${track.durationSeconds.toFixed(1)} s, dérivée ${probe.durationSeconds.toFixed(1)} s.`,
        );
      }
    }
  }
}
