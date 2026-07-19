import { spawn } from 'node:child_process';
import { access } from 'node:fs/promises';
import { resolve, sep } from 'node:path';
import { parseFile } from 'music-metadata';
import { eq, inArray } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import { trackAudioAnalysis, tracks } from '../db/schema.js';

export type BpmSource = 'METADATA' | 'FFMPEG_TEMPO';
export type AudioAnalysisStatus =
  | 'PENDING'
  | 'ANALYZING'
  | 'READY'
  | 'LOW_CONFIDENCE'
  | 'FAILED';
export type AudioAnalysisFailureReason =
  | 'BPM_NOT_DETECTED'
  | 'ANALYSIS_TIMEOUT'
  | 'ANALYZER_UNAVAILABLE'
  | 'ANALYSIS_FAILED';

export interface BpmMeasurement {
  rawBpm: number;
  bpm: number;
  confidence: number;
  source: BpmSource;
}

export interface TrackBpmAnalyzer {
  analyze(filePath: string): Promise<BpmMeasurement>;
}

export type TrackAudioAnalysis = typeof trackAudioAnalysis.$inferSelect;

const sampleRate = 11_025;
const windowSamples = 256;
const maxAnalysisSeconds = 180;
const lowConfidenceThreshold = 0.75;
const defaultAnalysisTimeoutMs = (maxAnalysisSeconds + 25) * 1000;

export function normalizeBpm(rawBpm: number): number {
  if (!Number.isFinite(rawBpm) || rawBpm <= 0) {
    throw new Error('BPM invalide.');
  }
  let normalized = rawBpm;
  while (normalized < 70) normalized *= 2;
  while (normalized > 190) normalized /= 2;
  return Math.round(normalized * 10) / 10;
}

export class MetadataThenFfmpegBpmAnalyzer implements TrackBpmAnalyzer {
  constructor(private readonly ffmpegPath = process.env.FFMPEG_PATH ?? 'ffmpeg') {}

  async analyze(filePath: string): Promise<BpmMeasurement> {
    let metadataError: unknown;
    try {
      const metadata = await parseFile(filePath, {
        duration: false,
        skipCovers: true,
      });
      const rawBpm = metadata.common.bpm;
      if (typeof rawBpm === 'number' && Number.isFinite(rawBpm) && rawBpm > 0) {
        return {
          rawBpm,
          bpm: normalizeBpm(rawBpm),
          confidence: 1,
          source: 'METADATA',
        };
      }
    } catch (error) {
      metadataError = error;
    }

    try {
      return await analyzeTempoFromPcm(filePath, this.ffmpegPath);
    } catch (error) {
      const metadataContext = metadataError
        ? ` Métadonnées illisibles: ${errorMessage(metadataError)}.`
        : '';
      throw new Error(`Analyse BPM impossible.${metadataContext} ${errorMessage(error)}`);
    }
  }
}

export class TrackAudioAnalysisService {
  private readonly running = new Set<number>();
  private readonly queued = new Set<number>();
  private readonly queue: number[] = [];
  private drainScheduled = false;

  constructor(
    private readonly handle: DbHandle,
    private readonly musicDir: string,
    private readonly analyzer: TrackBpmAnalyzer = new MetadataThenFfmpegBpmAnalyzer(),
    private readonly analysisTimeoutMs = defaultAnalysisTimeoutMs,
  ) {
    this.resumeInterrupted();
  }

  getOrSchedule(trackId: number): TrackAudioAnalysis {
    const existing = this.handle.db
      .select()
      .from(trackAudioAnalysis)
      .where(eq(trackAudioAnalysis.trackId, trackId))
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
      .insert(trackAudioAnalysis)
      .values({ trackId, status: 'PENDING', updatedAt: now })
      .onConflictDoNothing()
      .run();
    this.schedule(trackId, true);
    return this.handle.db
      .select()
      .from(trackAudioAnalysis)
      .where(eq(trackAudioAnalysis.trackId, trackId))
      .get()!;
  }

  private resumeInterrupted(): void {
    const interrupted = this.handle.db
      .select({ trackId: trackAudioAnalysis.trackId })
      .from(trackAudioAnalysis)
      .where(inArray(trackAudioAnalysis.status, ['PENDING', 'ANALYZING']))
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

  /**
   * Une seule analyse PCM à la fois : ffmpeg reste entièrement hors du chemin
   * des requêtes et ne peut pas saturer le mini-PC si plusieurs pistes sont
   * consultées rapidement.
   */
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
        .update(trackAudioAnalysis)
        .set({ status: 'ANALYZING', errorMessage: null, updatedAt: startedAt })
        .where(eq(trackAudioAnalysis.trackId, trackId))
        .run();

      const filePath = safeTrackPath(this.musicDir, track.path);
      try {
        await access(filePath);
      } catch {
        throw new Error('Fichier audio introuvable.');
      }
      const measurement = await withTimeout(
        this.analyzer.analyze(filePath),
        this.analysisTimeoutMs,
        'Delai maximal de l analyse BPM depasse.',
      );
      validateMeasurement(measurement);
      const now = new Date().toISOString();
      const confidence = clamp(measurement.confidence, 0, 1);
      this.handle.db
        .update(trackAudioAnalysis)
        .set({
          rawBpm: measurement.rawBpm,
          bpm: measurement.bpm,
          bpmConfidence: confidence,
          bpmSource: measurement.source,
          status: confidence < lowConfidenceThreshold ? 'LOW_CONFIDENCE' : 'READY',
          errorMessage: null,
          analyzedAt: now,
          updatedAt: now,
        })
        .where(eq(trackAudioAnalysis.trackId, trackId))
        .run();
    } catch (error) {
      const now = new Date().toISOString();
      this.handle.db
        .update(trackAudioAnalysis)
        .set({
          rawBpm: null,
          bpm: null,
          bpmConfidence: null,
          bpmSource: null,
          status: 'FAILED',
          errorMessage: errorMessage(error).slice(0, 500),
          analyzedAt: now,
          updatedAt: now,
        })
        .where(eq(trackAudioAnalysis.trackId, trackId))
        .run();
    }
  }
}

export function publicAudioAnalysisFailureReason(
  error: string | null,
): AudioAnalysisFailureReason {
  if (error === null) return 'ANALYSIS_FAILED';
  const normalized = error
    .normalize('NFD')
    .replace(/\p{Diacritic}/gu, '')
    .toLocaleLowerCase('fr');
  if (
    normalized.includes('signal trop court') ||
    normalized.includes('bpm invalide') ||
    normalized.includes('tempo non detecte')
  ) {
    return 'BPM_NOT_DETECTED';
  }
  if (normalized.includes('delai') || normalized.includes('timeout')) {
    return 'ANALYSIS_TIMEOUT';
  }
  if (
    normalized.includes('enoent') ||
    normalized.includes('ffmpeg introuvable') ||
    normalized.includes('not recognized as an internal or external command')
  ) {
    return 'ANALYZER_UNAVAILABLE';
  }
  return 'ANALYSIS_FAILED';
}

function safeTrackPath(musicDir: string, relativePath: string): string {
  const root = resolve(musicDir);
  const candidate = resolve(root, relativePath);
  if (candidate !== root && !candidate.startsWith(`${root}${sep}`)) {
    throw new Error('Chemin de piste invalide.');
  }
  return candidate;
}

async function analyzeTempoFromPcm(
  filePath: string,
  ffmpegPath: string,
): Promise<BpmMeasurement> {
  const energies = await decodeEnergyEnvelope(filePath, ffmpegPath);
  if (energies.length < 200) throw new Error('Signal trop court pour estimer le tempo.');

  const onset = energies.map((energy, index) =>
    index === 0 ? 0 : Math.max(0, energy - energies[index - 1]!),
  );
  const mean = onset.reduce((sum, value) => sum + value, 0) / onset.length;
  const centered = onset.map((value) => value - mean);
  const envelopeRate = sampleRate / windowSamples;
  const minLag = Math.floor((envelopeRate * 60) / 200);
  const maxLag = Math.ceil((envelopeRate * 60) / 60);
  let bestLag = minLag;
  let bestCorrelation = -1;

  for (let lag = minLag; lag <= maxLag; lag += 1) {
    let numerator = 0;
    let leftEnergy = 0;
    let rightEnergy = 0;
    for (let index = lag; index < centered.length; index += 1) {
      const left = centered[index]!;
      const right = centered[index - lag]!;
      numerator += left * right;
      leftEnergy += left * left;
      rightEnergy += right * right;
    }
    const denominator = Math.sqrt(leftEnergy * rightEnergy);
    const correlation = denominator > 0 ? numerator / denominator : 0;
    if (correlation > bestCorrelation) {
      bestCorrelation = correlation;
      bestLag = lag;
    }
  }

  const rawBpm = (60 * envelopeRate) / bestLag;
  return {
    rawBpm: Math.round(rawBpm * 10) / 10,
    bpm: normalizeBpm(rawBpm),
    confidence: Math.round(clamp((bestCorrelation - 0.12) / 0.58, 0, 1) * 1000) / 1000,
    source: 'FFMPEG_TEMPO',
  };
}

function decodeEnergyEnvelope(filePath: string, ffmpegPath: string): Promise<number[]> {
  return new Promise((resolvePromise, rejectPromise) => {
    const child = spawn(
      ffmpegPath,
      [
        '-hide_banner',
        '-loglevel',
        'error',
        '-i',
        filePath,
        '-t',
        String(maxAnalysisSeconds),
        '-vn',
        '-ac',
        '1',
        '-ar',
        String(sampleRate),
        '-f',
        'f32le',
        'pipe:1',
      ],
      { shell: false, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] },
    );
    const energies: number[] = [];
    let remainder = Buffer.alloc(0);
    let windowEnergy = 0;
    let windowCount = 0;
    let stderr = '';
    let settled = false;

    const timeout = setTimeout(() => {
      child.kill();
      finish(new Error('Délai ffmpeg dépassé.'));
    }, (maxAnalysisSeconds + 20) * 1000);

    const finish = (error?: Error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      if (error) rejectPromise(error);
      else resolvePromise(energies);
    };

    child.stdout.on('data', (chunk: Buffer) => {
      const data = remainder.length === 0 ? chunk : Buffer.concat([remainder, chunk]);
      const floatBytes = data.length - (data.length % 4);
      for (let offset = 0; offset < floatBytes; offset += 4) {
        const sample = data.readFloatLE(offset);
        if (!Number.isFinite(sample)) continue;
        windowEnergy += sample * sample;
        windowCount += 1;
        if (windowCount === windowSamples) {
          energies.push(Math.sqrt(windowEnergy / windowSamples));
          windowEnergy = 0;
          windowCount = 0;
        }
      }
      remainder = Buffer.from(data.subarray(floatBytes));
    });
    child.stderr.on('data', (chunk: Buffer) => {
      stderr = `${stderr}${chunk.toString('utf8')}`.slice(-4096);
    });
    child.on('error', (error) => finish(error));
    child.on('close', (code) => {
      if (code !== 0) {
        finish(new Error(stderr.trim() || `ffmpeg terminé avec le code ${code ?? 'inconnu'}.`));
      } else {
        finish();
      }
    });
  });
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(max, Math.max(min, value));
}

function validateMeasurement(measurement: BpmMeasurement): void {
  if (
    !Number.isFinite(measurement.rawBpm) ||
    !Number.isFinite(measurement.bpm) ||
    measurement.bpm < 40 ||
    measurement.bpm > 240 ||
    !Number.isFinite(measurement.confidence)
  ) {
    throw new Error('BPM invalide.');
  }
}

function withTimeout<T>(promise: Promise<T>, timeoutMs: number, message: string): Promise<T> {
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

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
