import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { copyFile, mkdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, join } from 'node:path';
import { pipeline } from 'node:stream/promises';
import type { Readable } from 'node:stream';
import { parseFile } from 'music-metadata';
import { eq } from 'drizzle-orm';
import type { Db } from '../db/client.js';
import { tracks, trackQuality } from '../db/schema.js';
import { audioFormat, detectAudioKind } from './audio-format.js';

// WAV PCM : la contrainte historique du projet (qualité CD).
const ALLOWED_WAV_SAMPLE_RATES = [44100, 48000];
const ALLOWED_WAV_BIT_DEPTH = 16;
// FLAC lossless : on accepte les résolutions courantes sans conversion.
const ALLOWED_FLAC_SAMPLE_RATES = [44100, 48000, 88200, 96000, 176400, 192000];
const ALLOWED_FLAC_BIT_DEPTHS = [16, 24];

export const PROVENANCES = ['rip_cd', 'achat', 'libre', 'upscale_ia', 'inconnue'] as const;
export type Provenance = (typeof PROVENANCES)[number];

// La provenance module le statut : un conteneur PCM ne prouve pas l'origine (AUDIO_SOURCING.md)
const STATUS_BY_PROVENANCE: Record<Provenance, string> = {
  rip_cd: 'lossless_verifie',
  achat: 'lossless_verifie',
  libre: 'lossless_probable',
  upscale_ia: 'lossy',
  inconnue: 'inconnue',
};

export class ImportError extends Error {
  constructor(
    public statusCode: number,
    message: string,
  ) {
    super(message);
  }
}

function sanitize(name: string): string {
  const clean = name
    .replace(/[<>:"/\\|?* -]/g, '_')
    .replace(/^[. ]+|[. ]+$/g, '')
    .slice(0, 120);
  return clean.length > 0 ? clean : 'Inconnu';
}

export interface ImportedTrack {
  id: number;
  title: string;
  artist: string;
  album: string;
  path: string;
  mimeType: string;
  quality: {
    container: string;
    codec: string;
    sampleRate: number;
    bitDepth: number;
    channels: number;
    status: string;
    provenance: Provenance;
  };
}

// Résultat non-exceptionnel du cœur d'ingestion : le doublon est un cas normal (surtout au scan)
export type IngestOutcome =
  | { status: 'imported'; track: ImportedTrack }
  | { status: 'duplicate'; existingId: number };

export interface ImportDirs {
  musicDir: string;
  incomingDir: string;
  coversDir: string;
}

/** Hash SHA-256 d'un fichier en flux — jamais le fichier entier en mémoire. */
export async function hashFile(path: string): Promise<string> {
  const hasher = createHash('sha256');
  await pipeline(createReadStream(path), hasher);
  return hasher.digest('hex');
}

/**
 * Cœur d'ingestion depuis un fichier DÉJÀ sur disque (staging pour l'upload, ou source pour le scan),
 * avec hash + taille précalculés. `keepSource` : true = copier (scan, on préserve l'original),
 * false = déplacer (upload, le staging est consommé).
 */
async function finalizeIngest(
  db: Db,
  dirs: ImportDirs,
  localPath: string,
  hash: string,
  size: number,
  originalFilename: string,
  provenance: Provenance,
  keepSource: boolean,
): Promise<IngestOutcome> {
  // 1. Doublon ? (contrôle avant toute analyse/copie → re-scan bon marché)
  const dup = db.select({ id: tracks.id }).from(tracks).where(eq(tracks.hash, hash)).get();
  if (dup) return { status: 'duplicate', existingId: dup.id };

  // 2. Analyse réelle : WAV PCM 16 bit ou FLAC lossless (aucune conversion).
  const meta = await parseFile(localPath, { duration: true }).catch(() => {
    throw new ImportError(422, 'Fichier illisible : ni WAV ni FLAC valide');
  });
  const { container, codec, sampleRate, bitsPerSample, numberOfChannels, duration } = meta.format;
  const kind = detectAudioKind(container, codec);
  if (kind === null) {
    throw new ImportError(422, `Format refusé : "${container ?? codec ?? 'inconnu'}" (WAV ou FLAC attendu)`);
  }
  if (kind === 'wav') {
    if (bitsPerSample !== ALLOWED_WAV_BIT_DEPTH || !ALLOWED_WAV_SAMPLE_RATES.includes(sampleRate ?? 0)) {
      throw new ImportError(
        422,
        `Specs WAV refusées : ${bitsPerSample ?? '?'} bit / ${sampleRate ?? '?'} Hz (attendu 16 bit / 44100 ou 48000 Hz)`,
      );
    }
  } else {
    if (
      meta.format.lossless === false ||
      !ALLOWED_FLAC_BIT_DEPTHS.includes(bitsPerSample ?? 0) ||
      !ALLOWED_FLAC_SAMPLE_RATES.includes(sampleRate ?? 0)
    ) {
      throw new ImportError(
        422,
        `Specs FLAC refusées : ${bitsPerSample ?? '?'} bit / ${sampleRate ?? '?'} Hz (attendu 16/24 bit, 44100–192000 Hz, lossless)`,
      );
    }
  }
  const format = audioFormat(kind);

  // 3. Rangement : Artiste/Album/Titre.ext (extension réelle, fallbacks depuis le nom)
  const fallbackTitle = originalFilename.replace(/\.(wav|flac)$/i, '');
  const title = meta.common.title?.trim() || fallbackTitle;
  const artist = meta.common.artist?.trim() || 'Artiste inconnu';
  const album = meta.common.album?.trim() || 'Album inconnu';
  const shortHash = hash.slice(0, 8);
  let relPath = join(sanitize(artist), sanitize(album), `${sanitize(title)}${format.extension}`);
  let destPath = join(dirs.musicDir, relPath);
  const exists = await stat(destPath).then(() => true, () => false);
  if (exists) {
    relPath = join(sanitize(artist), sanitize(album), `${sanitize(title)} [${shortHash}]${format.extension}`);
    destPath = join(dirs.musicDir, relPath);
  }
  await mkdir(dirname(destPath), { recursive: true });
  if (keepSource) {
    await copyFile(localPath, destPath);
  } else {
    await rename(localPath, destPath).catch(async () => {
      await copyFile(localPath, destPath); // volumes différents (EXDEV)
      await rm(localPath);
    });
  }

  // 4. Pochette embarquée éventuelle
  let coverPath: string | null = null;
  const picture = meta.common.picture?.[0];
  if (picture) {
    const ext = picture.format === 'image/png' ? 'png' : 'jpg';
    coverPath = `${shortHash}.${ext}`;
    await writeFile(join(dirs.coversDir, coverPath), picture.data);
  }

  // 5. Insertion
  const now = new Date().toISOString();
  const inserted = db
    .insert(tracks)
    .values({
      hash,
      path: relPath,
      originalExtension: format.extension,
      mimeType: format.mimeType,
      sizeBytes: size,
      durationSeconds: duration ?? null,
      title,
      artist,
      album,
      year: meta.common.year ?? null,
      genre: meta.common.genre?.[0] ?? null,
      coverPath,
      createdAt: now,
    })
    .returning({ id: tracks.id })
    .get();
  const quality = {
    container: container ?? (kind === 'flac' ? 'FLAC' : 'WAVE'),
    codec: codec ?? (kind === 'flac' ? 'FLAC' : 'PCM'),
    sampleRate: sampleRate ?? 0,
    bitDepth: bitsPerSample ?? 0,
    channels: numberOfChannels ?? 0,
    status: STATUS_BY_PROVENANCE[provenance],
    provenance,
  };
  db.insert(trackQuality)
    .values({ trackId: inserted.id, ...quality, analyzedAt: now })
    .run();

  return {
    status: 'imported',
    track: { id: inserted.id, title, artist, album, path: relPath, mimeType: format.mimeType, quality },
  };
}

/** Import depuis un flux HTTP (upload multipart). Lève ImportError (409/413/422). */
export async function importWav(
  db: Db,
  dirs: ImportDirs,
  source: Readable & { truncated?: boolean },
  originalFilename: string,
  provenance: Provenance,
): Promise<ImportedTrack> {
  const stagingPath = join(dirs.incomingDir, `${crypto.randomUUID()}.part`);
  try {
    const hasher = createHash('sha256');
    source.on('data', (chunk: Buffer) => hasher.update(chunk));
    await pipeline(source, createWriteStream(stagingPath));
    if (source.truncated) {
      throw new ImportError(413, 'Fichier tronqué : limite de taille dépassée');
    }
    const hash = hasher.digest('hex');
    const { size } = await stat(stagingPath);

    const outcome = await finalizeIngest(
      db, dirs, stagingPath, hash, size, originalFilename, provenance, false,
    );
    if (outcome.status === 'duplicate') {
      throw new ImportError(409, `Doublon : piste déjà importée (id ${outcome.existingId})`);
    }
    return outcome.track;
  } finally {
    await rm(stagingPath, { force: true });
  }
}

/**
 * Import depuis un fichier local existant (scanner). Copie le fichier dans la bibliothèque
 * gérée, préserve l'original. Renvoie un IngestOutcome (le doublon n'est pas une erreur).
 */
export async function importFromPath(
  db: Db,
  dirs: ImportDirs,
  filePath: string,
  provenance: Provenance,
): Promise<IngestOutcome> {
  const hash = await hashFile(filePath);
  const { size } = await stat(filePath);
  return finalizeIngest(db, dirs, filePath, hash, size, basename(filePath), provenance, true);
}
