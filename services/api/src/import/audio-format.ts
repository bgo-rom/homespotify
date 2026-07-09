// Formats audio supportés en bit-perfect (aucune conversion) : WAV PCM et FLAC.

export type AudioKind = 'wav' | 'flac';

export interface AudioFormatInfo {
  kind: AudioKind;
  extension: string; // .wav | .flac
  mimeType: string; // audio/wav | audio/flac
}

const FORMATS: Record<AudioKind, AudioFormatInfo> = {
  wav: { kind: 'wav', extension: '.wav', mimeType: 'audio/wav' },
  flac: { kind: 'flac', extension: '.flac', mimeType: 'audio/flac' },
};

export const audioFormat = (kind: AudioKind): AudioFormatInfo => FORMATS[kind];

/** Déduit le type de format depuis les métadonnées music-metadata (container/codec). */
export function detectAudioKind(
  container: string | undefined,
  codec: string | undefined,
): AudioKind | null {
  const c = (container ?? '').toUpperCase();
  const cod = (codec ?? '').toUpperCase();
  if (c.includes('WAVE') || cod === 'PCM') return 'wav';
  if (c.includes('FLAC') || cod.includes('FLAC')) return 'flac';
  return null;
}

/** MIME de streaming à partir de l'extension d'un chemin (fallback si non stocké). */
export function mimeTypeForPath(path: string): string {
  const lower = path.toLowerCase();
  if (lower.endsWith('.flac')) return FORMATS.flac.mimeType;
  return FORMATS.wav.mimeType; // défaut historique
}
