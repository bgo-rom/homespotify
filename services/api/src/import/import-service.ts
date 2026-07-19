import { createHash } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import { copyFile, mkdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { basename, dirname, isAbsolute, join, relative, resolve } from 'node:path';
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

export interface EmbeddedCover {
  mimeType: 'image/jpeg' | 'image/png';
  data: Buffer;
  type: string | null;
  width: number | null;
  height: number | null;
}

export interface AudioFileAnalysis {
  title: string;
  fallbackTitle: string;
  artist: string;
  album: string;
  albumArtist: string | null;
  trackNumber: number | null;
  trackTotal: number | null;
  discNumber: number | null;
  discTotal: number | null;
  date: string | null;
  year: number | null;
  isrc: string | null;
  genre: string | null;
  durationSeconds: number | null;
  sampleRate: number;
  bitDepth: number;
  channels: number;
  container: string;
  codec: string;
  kind: 'wav' | 'flac';
  cover: EmbeddedCover | null;
}

function imageDimensions(
  data: Uint8Array,
  mimeType: 'image/jpeg' | 'image/png',
): { width: number | null; height: number | null } {
  if (
    mimeType === 'image/png' &&
    data.length >= 24 &&
    Buffer.from(data.subarray(1, 4)).toString('ascii') === 'PNG'
  ) {
    const view = Buffer.from(data);
    return { width: view.readUInt32BE(16), height: view.readUInt32BE(20) };
  }
  if (mimeType === 'image/jpeg' && data.length >= 10) {
    const view = Buffer.from(data);
    let offset = 2;
    const startOfFrame = new Set([
      0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7,
      0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf,
    ]);
    while (offset + 8 < view.length) {
      if (view[offset] !== 0xff) {
        offset += 1;
        continue;
      }
      const marker = view[offset + 1]!;
      if (startOfFrame.has(marker)) {
        return {
          height: view.readUInt16BE(offset + 5),
          width: view.readUInt16BE(offset + 7),
        };
      }
      if (marker === 0xd8 || marker === 0xd9) {
        offset += 2;
        continue;
      }
      const segmentLength = view.readUInt16BE(offset + 2);
      if (segmentLength < 2) break;
      offset += 2 + segmentLength;
    }
  }
  return { width: null, height: null };
}

function selectEmbeddedCover(
  pictures: Awaited<ReturnType<typeof parseFile>>['common']['picture'],
): EmbeddedCover | null {
  const supported = (pictures ?? []).filter(
    (picture) => picture.format === 'image/jpeg' || picture.format === 'image/png',
  );
  const picture =
    supported.find((candidate) => candidate.type?.toLowerCase().includes('front')) ??
    supported[0];
  if (!picture) return null;
  const mimeType = picture.format as 'image/jpeg' | 'image/png';
  const dimensions = imageDimensions(picture.data, mimeType);
  return {
    mimeType,
    data: Buffer.from(picture.data),
    type: picture.type ?? null,
    width: dimensions.width,
    height: dimensions.height,
  };
}

/** Analyse centrale des tags et caractéristiques audio, sans modifier le fichier. */
export async function analyzeAudioFile(
  filePath: string,
  originalFilename = basename(filePath),
): Promise<AudioFileAnalysis> {
  const meta = await parseFile(filePath, { duration: true }).catch(() => {
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
  } else if (
    meta.format.lossless === false ||
    !ALLOWED_FLAC_BIT_DEPTHS.includes(bitsPerSample ?? 0) ||
    !ALLOWED_FLAC_SAMPLE_RATES.includes(sampleRate ?? 0)
  ) {
    throw new ImportError(
      422,
      `Specs FLAC refusées : ${bitsPerSample ?? '?'} bit / ${sampleRate ?? '?'} Hz (attendu 16/24 bit, 44100–192000 Hz, lossless)`,
    );
  }

  const fallbackTitle = originalFilename.replace(/\.(wav|flac)$/i, '').trim();
  return {
    title: meta.common.title?.trim() || fallbackTitle,
    fallbackTitle,
    artist: meta.common.artist?.trim() || 'Artiste inconnu',
    album: meta.common.album?.trim() || 'Album inconnu',
    albumArtist: meta.common.albumartist?.trim() || null,
    trackNumber: meta.common.track.no ?? null,
    trackTotal: meta.common.track.of ?? null,
    discNumber: meta.common.disk.no ?? null,
    discTotal: meta.common.disk.of ?? null,
    date: meta.common.date?.trim() || null,
    year: meta.common.year ?? null,
    isrc: meta.common.isrc?.[0]?.trim().toUpperCase() ?? null,
    genre: meta.common.genre?.[0]?.trim() || null,
    durationSeconds: duration ?? null,
    sampleRate: sampleRate ?? 0,
    bitDepth: bitsPerSample ?? 0,
    channels: numberOfChannels ?? 0,
    container: container ?? (kind === 'flac' ? 'FLAC' : 'WAVE'),
    codec: codec ?? (kind === 'flac' ? 'FLAC' : 'PCM'),
    kind,
    cover: selectEmbeddedCover(meta.common.picture),
  };
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
  providedAnalysis?: AudioFileAnalysis,
): Promise<IngestOutcome> {
  // 1. Doublon ? (contrôle avant toute analyse/copie → re-scan bon marché)
  const dup = db.select({ id: tracks.id }).from(tracks).where(eq(tracks.hash, hash)).get();
  if (dup) return { status: 'duplicate', existingId: dup.id };

  // Analyse centrale : tags, caractéristiques et image embarquée.
  const analysis =
    providedAnalysis ?? await analyzeAudioFile(localPath, originalFilename);
  const format = audioFormat(analysis.kind);

  // 3. Rangement : Artiste/Album/Titre.ext (extension réelle, fallbacks depuis le nom)
  const title = analysis.title;
  const artist = analysis.artist;
  const album = analysis.album;
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
  const picture = analysis.cover;
  if (picture) {
    const ext = picture.mimeType === 'image/png' ? 'png' : 'jpg';
    coverPath = `${shortHash}.${ext}`;
    const destination = join(dirs.coversDir, coverPath);
    const alreadyStored = await stat(destination).then(() => true, () => false);
    if (!alreadyStored) await writeFile(destination, picture.data);
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
      durationSeconds: analysis.durationSeconds,
      title,
      artist,
      album,
      year: analysis.year,
      genre: analysis.genre,
      isrc: analysis.isrc,
      coverPath,
      createdAt: now,
    })
    .returning({ id: tracks.id })
    .get();
  const quality = {
    container: analysis.container,
    codec: analysis.codec,
    sampleRate: analysis.sampleRate,
    bitDepth: analysis.bitDepth,
    channels: analysis.channels,
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
  analysis?: AudioFileAnalysis,
): Promise<IngestOutcome> {
  const hash = await hashFile(filePath);
  const { size } = await stat(filePath);
  return finalizeIngest(
    db,
    dirs,
    filePath,
    hash,
    size,
    basename(filePath),
    provenance,
    true,
    analysis,
  );
}

export interface TrackReanalysisResult {
  trackId: number;
  filePath: string;
  updatedFields: string[];
  analysis: AudioFileAnalysis;
}

function confinedTrackPath(root: string, storedPath: string): string {
  const absoluteRoot = resolve(root);
  const candidate = resolve(absoluteRoot, storedPath);
  const rel = relative(absoluteRoot, candidate);
  if (rel !== '' && (rel.startsWith('..') || isAbsolute(rel))) {
    throw new ImportError(422, 'Chemin de piste hors de la bibliothèque.');
  }
  return candidate;
}

/**
 * Réanalyse idempotente d'une piste existante. Seuls les champs absents ou
 * explicitement provisoires sont complétés ; le fichier et son identifiant ne
 * changent jamais.
 */
export async function reanalyzeExistingTrack(
  db: Db,
  dirs: Pick<ImportDirs, 'musicDir' | 'coversDir'>,
  trackId: number,
): Promise<TrackReanalysisResult> {
  const row = db.select().from(tracks).where(eq(tracks.id, trackId)).get();
  if (!row) throw new ImportError(404, `Piste ${trackId} introuvable`);
  const filePath = confinedTrackPath(dirs.musicDir, row.path);
  const analysis = await analyzeAudioFile(filePath, basename(filePath));
  const update: Partial<typeof tracks.$inferInsert> = {};
  const updatedFields: string[] = [];
  const provisionalTitle = basename(row.path).replace(/\.(wav|flac)$/i, '');

  const set = <K extends keyof typeof update>(
    key: K,
    value: (typeof update)[K],
  ): void => {
    update[key] = value;
    updatedFields.push(String(key));
  };

  if (
    (row.title.trim().length === 0 || row.title === provisionalTitle) &&
    analysis.title !== analysis.fallbackTitle
  ) {
    set('title', analysis.title);
  }
  if (
    (row.artist.trim().length === 0 || row.artist === 'Artiste inconnu') &&
    analysis.artist !== 'Artiste inconnu'
  ) {
    set('artist', analysis.artist);
  }
  if (
    (row.album.trim().length === 0 || row.album === 'Album inconnu') &&
    analysis.album !== 'Album inconnu'
  ) {
    set('album', analysis.album);
  }
  if (row.year === null && analysis.year !== null) set('year', analysis.year);
  if (row.genre === null && analysis.genre !== null) set('genre', analysis.genre);
  if (row.isrc === null && analysis.isrc !== null) set('isrc', analysis.isrc);
  if (
    (row.durationSeconds === null || row.durationSeconds <= 0) &&
    analysis.durationSeconds !== null
  ) {
    set('durationSeconds', analysis.durationSeconds);
  }
  if (row.coverPath === null && analysis.cover !== null) {
    const extension = analysis.cover.mimeType === 'image/png' ? 'png' : 'jpg';
    const coverPath = `${row.hash.slice(0, 8)}.${extension}`;
    const coverFile = join(dirs.coversDir, coverPath);
    await mkdir(dirs.coversDir, { recursive: true });
    const exists = await stat(coverFile).then(() => true, () => false);
    if (!exists) await writeFile(coverFile, analysis.cover.data);
    set('coverPath', coverPath);
  }
  if (updatedFields.length > 0) {
    db.update(tracks).set(update).where(eq(tracks.id, trackId)).run();
  }

  const quality = db
    .select()
    .from(trackQuality)
    .where(eq(trackQuality.trackId, trackId))
    .get();
  const analyzedAt = new Date().toISOString();
  if (!quality) {
    db.insert(trackQuality).values({
      trackId,
      container: analysis.container,
      codec: analysis.codec,
      sampleRate: analysis.sampleRate,
      bitDepth: analysis.bitDepth,
      channels: analysis.channels,
      status: 'inconnue',
      provenance: 'inconnue',
      analyzedAt,
    }).run();
    updatedFields.push('quality');
  } else {
    const qualityUpdate = {
      ...(quality.container.length === 0 ? { container: analysis.container } : {}),
      ...(quality.codec.length === 0 ? { codec: analysis.codec } : {}),
      ...(quality.sampleRate <= 0 ? { sampleRate: analysis.sampleRate } : {}),
      ...(quality.bitDepth <= 0 ? { bitDepth: analysis.bitDepth } : {}),
      ...(quality.channels <= 0 ? { channels: analysis.channels } : {}),
      analyzedAt,
    };
    db.update(trackQuality)
      .set(qualityUpdate)
      .where(eq(trackQuality.trackId, trackId))
      .run();
  }
  return { trackId, filePath, updatedFields, analysis };
}
