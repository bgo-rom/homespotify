import { spawn } from 'node:child_process';
import { access } from 'node:fs/promises';
import { resolve, sep } from 'node:path';
import { eq, inArray } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import { trackLoudnessAnalysis, tracks } from '../db/schema.js';

export type LoudnessAnalysisStatus =
  | 'PENDING'
  | 'ANALYZING'
  | 'READY'
  | 'FAILED';

export interface LoudnessMeasurement {
  integratedLufs: number;
  truePeakDbfs: number;
}

export interface TrackLoudnessAnalyzer {
  analyze(filePath: string): Promise<LoudnessMeasurement>;
}

export type TrackLoudnessAnalysis =
  typeof trackLoudnessAnalysis.$inferSelect;

export const replayGainTargetLufs = -18;
export const replayGainPeakCeilingDbfs = -1;
const minReplayGainDb = -24;
const maxReplayGainDb = 12;
const defaultAnalysisTimeoutMs = 180_000;

export interface ReplayGainResult {
  replayGainDb: number;
  peakLimited: boolean;
}

export function computeReplayGain(
  measurement: LoudnessMeasurement,
): ReplayGainResult {
  validateMeasurement(measurement);
  const loudnessGain = replayGainTargetLufs - measurement.integratedLufs;
  const peakSafeGain =
    replayGainPeakCeilingDbfs - measurement.truePeakDbfs;
  const peakLimited = peakSafeGain < loudnessGain;
  const replayGainDb = roundTenth(
    clamp(Math.min(loudnessGain, peakSafeGain), minReplayGainDb, maxReplayGainDb),
  );
  return { replayGainDb, peakLimited };
}

export class FfmpegR128Analyzer implements TrackLoudnessAnalyzer {
  constructor(
    private readonly ffmpegPath = process.env.FFMPEG_PATH ?? 'ffmpeg',
    private readonly timeoutMs = defaultAnalysisTimeoutMs,
  ) {}

  analyze(filePath: string): Promise<LoudnessMeasurement> {
    return analyzeWithLoudnorm(filePath, this.ffmpegPath, this.timeoutMs);
  }
}

/**
 * File persistante et bornée à une seule mesure R128. Une requête ne décode
 * jamais l'audio elle-même : elle crée/lit l'état puis rend immédiatement.
 */
export class TrackLoudnessAnalysisService {
  private readonly running = new Set<number>();
  private readonly queued = new Set<number>();
  private readonly queue: number[] = [];
  private drainScheduled = false;

  constructor(
    private readonly handle: DbHandle,
    private readonly musicDir: string,
    private readonly analyzer: TrackLoudnessAnalyzer =
      new FfmpegR128Analyzer(),
    private readonly analysisTimeoutMs = defaultAnalysisTimeoutMs,
  ) {
    this.resumeInterrupted();
  }

  getOrSchedule(trackId: number): TrackLoudnessAnalysis {
    const existing = this.handle.db
      .select()
      .from(trackLoudnessAnalysis)
      .where(eq(trackLoudnessAnalysis.trackId, trackId))
      .get();
    if (existing) {
      if (existing.status === 'PENDING' || existing.status === 'ANALYZING') {
        this.schedule(trackId, true);
      }
      return existing;
    }

    const track = this.handle.db
      .select({ id: tracks.id })
      .from(tracks)
      .where(eq(tracks.id, trackId))
      .get();
    if (!track) throw new Error('Piste inconnue.');

    const now = new Date().toISOString();
    this.handle.db
      .insert(trackLoudnessAnalysis)
      .values({ trackId, status: 'PENDING', updatedAt: now })
      .onConflictDoNothing()
      .run();
    this.schedule(trackId, true);
    return this.handle.db
      .select()
      .from(trackLoudnessAnalysis)
      .where(eq(trackLoudnessAnalysis.trackId, trackId))
      .get()!;
  }

  private resumeInterrupted(): void {
    const interrupted = this.handle.db
      .select({ trackId: trackLoudnessAnalysis.trackId })
      .from(trackLoudnessAnalysis)
      .where(
        inArray(trackLoudnessAnalysis.status, ['PENDING', 'ANALYZING']),
      )
      .all();
    for (const row of interrupted) this.schedule(row.trackId);
  }

  private schedule(trackId: number, prioritized = false): void {
    if (this.running.has(trackId)) return;
    if (this.queued.has(trackId)) {
      if (prioritized) {
        const index = this.queue.indexOf(trackId);
        if (index > 0) {
          this.queue.splice(index, 1);
          this.queue.unshift(trackId);
        }
      }
      return;
    }
    this.queued.add(trackId);
    if (prioritized) this.queue.unshift(trackId);
    else this.queue.push(trackId);
    this.scheduleDrain();
  }

  private scheduleDrain(): void {
    if (this.drainScheduled) return;
    this.drainScheduled = true;
    setImmediate(() => {
      this.drainScheduled = false;
      this.drain();
    });
  }

  private drain(): void {
    if (this.running.size > 0) return;
    const trackId = this.queue.shift();
    if (trackId === undefined) return;
    this.queued.delete(trackId);
    this.running.add(trackId);
    void this.run(trackId).finally(() => {
      this.running.delete(trackId);
      this.scheduleDrain();
    });
  }

  private async run(trackId: number): Promise<void> {
    try {
      const track = this.handle.db
        .select({ path: tracks.path })
        .from(tracks)
        .where(eq(tracks.id, trackId))
        .get();
      if (!track) throw new Error('Piste inconnue.');

      const startedAt = new Date().toISOString();
      this.handle.db
        .update(trackLoudnessAnalysis)
        .set({
          status: 'ANALYZING',
          errorMessage: null,
          updatedAt: startedAt,
        })
        .where(eq(trackLoudnessAnalysis.trackId, trackId))
        .run();

      const filePath = safeTrackPath(this.musicDir, track.path);
      await access(filePath);
      const measurement = await withTimeout(
        this.analyzer.analyze(filePath),
        this.analysisTimeoutMs,
        'Délai maximal de l’analyse R128 dépassé.',
      );
      const gain = computeReplayGain(measurement);
      const now = new Date().toISOString();
      this.handle.db
        .update(trackLoudnessAnalysis)
        .set({
          status: 'READY',
          integratedLufs: roundTenth(measurement.integratedLufs),
          truePeakDbfs: roundTenth(measurement.truePeakDbfs),
          replayGainDb: gain.replayGainDb,
          targetLufs: replayGainTargetLufs,
          peakCeilingDbfs: replayGainPeakCeilingDbfs,
          errorMessage: null,
          analyzedAt: now,
          updatedAt: now,
        })
        .where(eq(trackLoudnessAnalysis.trackId, trackId))
        .run();
    } catch (error) {
      const now = new Date().toISOString();
      this.handle.db
        .update(trackLoudnessAnalysis)
        .set({
          status: 'FAILED',
          integratedLufs: null,
          truePeakDbfs: null,
          replayGainDb: null,
          errorMessage: errorMessage(error).slice(0, 500),
          analyzedAt: now,
          updatedAt: now,
        })
        .where(eq(trackLoudnessAnalysis.trackId, trackId))
        .run();
    }
  }
}

function analyzeWithLoudnorm(
  filePath: string,
  ffmpegPath: string,
  timeoutMs: number,
): Promise<LoudnessMeasurement> {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(
      ffmpegPath,
      [
        '-hide_banner',
        '-nostats',
        '-i',
        filePath,
        '-vn',
        '-af',
        `loudnorm=I=${replayGainTargetLufs}:TP=${replayGainPeakCeilingDbfs}:LRA=11:print_format=json`,
        '-f',
        'null',
        '-',
      ],
      { shell: false, windowsHide: true, stdio: ['ignore', 'ignore', 'pipe'] },
    );
    let stderr = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      child.kill();
      finish(new Error('Délai maximal de l’analyse R128 dépassé.'));
    }, timeoutMs);

    const finish = (error?: Error, measurement?: LoudnessMeasurement) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      if (error) rejectPromise(error);
      else if (measurement) resolvePromise(measurement);
      else rejectPromise(new Error('Mesure R128 absente.'));
    };

    child.stderr.on('data', (chunk: Buffer) => {
      stderr = `${stderr}${chunk.toString('utf8')}`.slice(-32_768);
    });
    child.on('error', (error) => finish(error));
    child.on('close', (code) => {
      if (code !== 0) {
        finish(
          new Error(
            stderr.trim() ||
              `ffmpeg terminé avec le code ${code ?? 'inconnu'}.`,
          ),
        );
        return;
      }
      try {
        finish(undefined, parseLoudnormOutput(stderr));
      } catch (error) {
        finish(
          error instanceof Error ? error : new Error(String(error)),
        );
      }
    });
  });
}

export function parseLoudnormOutput(stderr: string): LoudnessMeasurement {
  const end = stderr.lastIndexOf('}');
  const start = stderr.lastIndexOf('{', end);
  if (start < 0 || end <= start) {
    throw new Error('Résumé JSON loudnorm introuvable.');
  }
  const payload = JSON.parse(stderr.slice(start, end + 1)) as {
    input_i?: string | number;
    input_tp?: string | number;
  };
  const measurement = {
    integratedLufs: Number(payload.input_i),
    truePeakDbfs: Number(payload.input_tp),
  };
  validateMeasurement(measurement);
  return measurement;
}

function validateMeasurement(measurement: LoudnessMeasurement): void {
  if (
    !Number.isFinite(measurement.integratedLufs) ||
    measurement.integratedLufs < -70 ||
    measurement.integratedLufs > 5 ||
    !Number.isFinite(measurement.truePeakDbfs) ||
    measurement.truePeakDbfs < -120 ||
    measurement.truePeakDbfs > 20
  ) {
    throw new Error('Mesure R128 invalide ou signal silencieux.');
  }
}

function safeTrackPath(musicDir: string, relativePath: string): string {
  const root = resolve(musicDir);
  const candidate = resolve(root, relativePath);
  if (candidate !== root && !candidate.startsWith(`${root}${sep}`)) {
    throw new Error('Chemin de piste invalide.');
  }
  return candidate;
}

function withTimeout<T>(
  promise: Promise<T>,
  timeoutMs: number,
  message: string,
): Promise<T> {
  return new Promise<T>((resolvePromise, rejectPromise) => {
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      rejectPromise(new Error(message));
    }, timeoutMs);
    promise.then(
      (value) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        resolvePromise(value);
      },
      (error: unknown) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        rejectPromise(error);
      },
    );
  });
}

function roundTenth(value: number): number {
  return Math.round(value * 10) / 10;
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
