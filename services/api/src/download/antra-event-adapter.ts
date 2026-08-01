/**
 * Adaptateur NDJSON Antra → événements HomeSpotify.
 *
 * `antra.json_cli` écrit UNE ligne JSON par événement sur stdout. Le contrat
 * réel est décrit par `tools/antra/antra/json_cli.py` :
 *   {"type":"log","level":…,"message":…}
 *   {"type":"playlist_loaded","title":…,"artists_string":…,"track_count":…}
 *   {"type":"event","name":"track_started|track_resolved|track_download_attempt|
 *                            track_completed|track_failed|track_skipped",
 *    "payload":{track,artist,track_index,track_total,source,quality_label,…}}
 *   {"type":"progress","stage":…,"tracks_completed":…,"tracks_total":…}
 *   {"type":"playlist_summary","total":…,"downloaded":…,"failed":…,"error":…}
 *   {"type":"done"}
 *
 * Aucune autre couche de HomeSpotify ne lit ce vocabulaire : tout est traduit
 * ici, et une ligne inconnue est ignorée sans casser le job.
 */
import type {
  DownloadProviderEvent,
  DownloadStage,
  DownloadTrackInfo,
} from './download-provider.js';
import { sanitizeMessage, sanitizeShortField } from './log-sanitizer.js';

/** Résumé final émis par Antra, extrait à part des événements de progression. */
export interface AntraSummary {
  total: number;
  downloaded: number;
  skipped: number;
  failed: number;
  errorMessage: string | null;
}

export interface AntraLineResult {
  events: DownloadProviderEvent[];
  /** Renseigné uniquement par `playlist_summary`. */
  summary?: AntraSummary;
  /** `true` sur `{"type":"done"}` : le moteur annonce sa fin. */
  done?: boolean;
}

const EMPTY: AntraLineResult = { events: [] };

function asRecord(value: unknown): Record<string, unknown> | null {
  if (typeof value !== 'object' || value === null || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
}

function asFiniteNumber(value: unknown): number | null {
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

function percentFrom(completed: number | null, total: number | null): number | null {
  if (completed === null || total === null || total <= 0) return null;
  const ratio = completed / total;
  return Math.max(0, Math.min(100, Math.round(ratio * 100)));
}

function trackInfoFromPayload(
  payload: Record<string, unknown>,
): DownloadTrackInfo {
  const durationMs = asFiniteNumber(
    asRecord(payload.track_data)?.duration_ms ?? null,
  );
  return {
    title: sanitizeShortField(payload.track),
    artist: sanitizeShortField(payload.artist),
    album: sanitizeShortField(asRecord(payload.track_data)?.album ?? null),
    source: sanitizeShortField(payload.source, 60),
    quality: sanitizeShortField(payload.quality_label, 60),
    durationSeconds:
      durationMs === null ? null : Math.max(0, Math.round(durationMs / 1000)),
  };
}

/** Ne conserve que les champs réellement renseignés : évite d'écraser un acquis. */
function compactTrack(track: DownloadTrackInfo): DownloadTrackInfo | undefined {
  const entries = Object.entries(track).filter(
    ([, value]) => value !== null && value !== undefined,
  );
  return entries.length === 0
    ? undefined
    : (Object.fromEntries(entries) as DownloadTrackInfo);
}

const ENGINE_STAGE_BY_EVENT: Record<string, DownloadStage> = {
  track_started: 'resolving',
  track_resolved: 'selecting_source',
  track_download_attempt: 'downloading',
  track_completed: 'processing',
  track_skipped: 'processing',
  track_failed: 'downloading',
  playlist_started: 'resolving',
  playlist_completed: 'processing',
  playlist_cancelled: 'cancelled',
};

const PROGRESS_STAGE_MAP: Record<string, DownloadStage> = {
  fetching: 'resolving',
  fetched: 'resolving',
  downloading: 'downloading',
  completed: 'processing',
  failed: 'failed',
  fetch_failed: 'failed',
};

const LOG_LEVELS = new Set(['debug', 'info', 'warn', 'warning', 'error', 'critical']);

function normalizeLevel(raw: unknown): 'debug' | 'info' | 'warn' | 'error' {
  const value = typeof raw === 'string' ? raw.toLowerCase() : 'info';
  if (!LOG_LEVELS.has(value)) return 'info';
  if (value === 'warning') return 'warn';
  if (value === 'critical') return 'error';
  return value as 'debug' | 'info' | 'warn' | 'error';
}

/**
 * Traduit UNE ligne de stdout. Une ligne vide, non-JSON ou de forme inconnue
 * renvoie un résultat vide : le moteur peut écrire n'importe quoi sans faire
 * échouer le job.
 */
export function adaptAntraLine(line: string): AntraLineResult {
  const trimmed = line.trim();
  if (trimmed.length === 0) return EMPTY;

  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    // Antra peut écrire une bannière ou une trace non JSON : ignorée
    // proprement, sans interrompre la lecture du flux.
    return EMPTY;
  }

  const record = asRecord(parsed);
  if (record === null) return EMPTY;

  switch (record.type) {
    case 'log': {
      const message = sanitizeMessage(record.message);
      if (message === null) return EMPTY;
      return {
        events: [{ type: 'log', level: normalizeLevel(record.level), message }],
      };
    }

    case 'playlist_loaded': {
      const track = compactTrack({
        title: sanitizeShortField(record.title),
        artist: sanitizeShortField(record.artists_string),
      });
      return {
        events: [
          {
            type: 'stage',
            stage: 'resolving',
            message: 'Métadonnées récupérées.',
            ...(track === undefined ? {} : { track }),
          },
        ],
      };
    }

    case 'event': {
      const payload = asRecord(record.payload) ?? {};
      const name = typeof record.name === 'string' ? record.name : '';
      const stage = ENGINE_STAGE_BY_EVENT[name];
      const track = compactTrack(trackInfoFromPayload(payload));
      const events: DownloadProviderEvent[] = [];

      if (name === 'track_failed') {
        const message =
          sanitizeMessage(payload.error) ??
          sanitizeMessage(payload.message) ??
          'Le moteur n’a pas pu récupérer cette piste.';
        events.push({ type: 'error', code: 'ANTRA_TRACK_FAILED', message });
      }

      const percent = percentFrom(
        // `track_index` est 0-based ; une piste terminée compte pour une unité.
        (() => {
          const index = asFiniteNumber(payload.track_index);
          if (index === null) return null;
          return name === 'track_completed' || name === 'track_skipped'
            ? index + 1
            : index;
        })(),
        asFiniteNumber(payload.track_total),
      );

      if (stage !== undefined) {
        events.push({
          type: 'stage',
          stage,
          message: sanitizeMessage(payload.message),
          ...(track === undefined ? {} : { track }),
        });
      } else if (track !== undefined) {
        events.push({ type: 'track', track });
      }

      if (percent !== null) {
        events.push({
          type: 'progress',
          percent,
          ...(stage === undefined ? {} : { stage }),
        });
      }

      return { events };
    }

    case 'progress': {
      const stage =
        typeof record.stage === 'string'
          ? PROGRESS_STAGE_MAP[record.stage]
          : undefined;
      const percent = percentFrom(
        asFiniteNumber(record.tracks_completed),
        asFiniteNumber(record.tracks_total),
      );
      const events: DownloadProviderEvent[] = [];
      if (stage !== undefined) {
        events.push({
          type: 'stage',
          stage,
          message: sanitizeMessage(record.message),
        });
      }
      if (percent !== null) {
        events.push({
          type: 'progress',
          percent,
          ...(stage === undefined ? {} : { stage }),
        });
      }
      return { events };
    }

    case 'playlist_summary': {
      const errorMessage = sanitizeMessage(record.error);
      const summary: AntraSummary = {
        total: asFiniteNumber(record.total) ?? 0,
        downloaded: asFiniteNumber(record.downloaded) ?? 0,
        skipped: asFiniteNumber(record.skipped) ?? 0,
        failed: asFiniteNumber(record.failed) ?? 0,
        errorMessage,
      };
      const events: DownloadProviderEvent[] = [];
      if (errorMessage !== null) {
        events.push({
          type: 'error',
          code: 'ANTRA_SUMMARY_ERROR',
          message: errorMessage,
        });
      }
      const track = compactTrack({ album: sanitizeShortField(record.title) });
      if (track !== undefined) events.push({ type: 'track', track });
      return { events, summary };
    }

    case 'done':
      return { events: [], done: true };

    case 'error': {
      const message =
        sanitizeMessage(record.message) ?? 'Le moteur a signalé une erreur.';
      return {
        events: [{ type: 'error', code: 'ANTRA_ERROR', message }],
      };
    }

    default:
      return EMPTY;
  }
}

/**
 * Découpe un flux stdout en lignes complètes.
 *
 * Une ligne JSON peut arriver en plusieurs morceaux : le reste incomplet est
 * conservé pour le prochain chunk, sinon un événement serait perdu à chaque
 * frontière de buffer.
 */
export class NdjsonLineSplitter {
  private buffer = '';

  /** Longueur maximale d'une ligne en cours : garde-fou anti-mémoire. */
  constructor(private readonly maxLineLength = 1_000_000) {}

  push(chunk: string): string[] {
    this.buffer += chunk;
    const lines = this.buffer.split(/\r?\n/);
    this.buffer = lines.pop() ?? '';
    if (this.buffer.length > this.maxLineLength) {
      // Ligne aberrante (binaire, boucle de log) : on repart proprement plutôt
      // que d'accumuler indéfiniment.
      this.buffer = '';
    }
    return lines;
  }

  /** Vide le reste après fermeture du flux. */
  flush(): string[] {
    const rest = this.buffer;
    this.buffer = '';
    return rest.trim().length > 0 ? [rest] : [];
  }
}
