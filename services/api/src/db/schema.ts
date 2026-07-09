import { index, integer, real, sqliteTable, text } from 'drizzle-orm/sqlite-core';

export const appMeta = sqliteTable('app_meta', {
  key: text('key').primaryKey(),
  value: text('value').notNull(),
  updatedAt: text('updated_at').notNull(),
});

export const tracks = sqliteTable('tracks', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  hash: text('hash').notNull().unique(), // SHA-256 du fichier, calculé en flux
  path: text('path').notNull(), // relatif à musicDir
  originalExtension: text('original_extension'), // .wav | .flac
  mimeType: text('mime_type'), // audio/wav | audio/flac (pour le Content-Type de stream)
  sizeBytes: integer('size_bytes').notNull(),
  durationSeconds: real('duration_seconds'),
  title: text('title').notNull(),
  artist: text('artist').notNull(),
  album: text('album').notNull(),
  year: integer('year'),
  genre: text('genre'),
  coverPath: text('cover_path'), // relatif à coversDir
  createdAt: text('created_at').notNull(),
});

// Qualité MESURÉE (music-metadata), jamais déduite de l'extension — cf. AUDIO_SOURCING.md
export const trackQuality = sqliteTable('track_quality', {
  trackId: integer('track_id')
    .primaryKey()
    .references(() => tracks.id, { onDelete: 'cascade' }),
  container: text('container').notNull(),
  codec: text('codec').notNull(),
  sampleRate: integer('sample_rate').notNull(),
  bitDepth: integer('bit_depth').notNull(),
  channels: integer('channels').notNull(),
  status: text('status').notNull(), // lossless_verifie | lossless_probable | lossy | inconnue
  provenance: text('provenance').notNull(), // rip_cd | achat | libre | upscale_ia | inconnue
  analyzedAt: text('analyzed_at').notNull(),
});

// Enrichissement descriptif externe (MusicBrainz/Cover Art), séparé de la vérité audio mesurée.
export const trackEnrichment = sqliteTable('track_enrichment', {
  trackId: integer('track_id')
    .primaryKey()
    .references(() => tracks.id, { onDelete: 'cascade' }),
  status: text('status').notNull(), // pending | matched | ambiguous | not_found | failed
  musicbrainzRecordingId: text('musicbrainz_recording_id'),
  musicbrainzReleaseId: text('musicbrainz_release_id'),
  musicbrainzReleaseGroupId: text('musicbrainz_release_group_id'),
  musicbrainzArtistId: text('musicbrainz_artist_id'),
  canonicalTitle: text('canonical_title'),
  canonicalArtist: text('canonical_artist'),
  canonicalAlbum: text('canonical_album'),
  albumArtist: text('album_artist'),
  releaseDate: text('release_date'),
  trackNumber: integer('track_number'),
  discNumber: integer('disc_number'),
  genre: text('genre'),
  matchScore: real('match_score'),
  candidatesJson: text('candidates_json'),
  errorMessage: text('error_message'),
  checkedAt: text('checked_at').notNull(),
  enrichedAt: text('enriched_at'),
}, (table) => [
  index('track_enrichment_status_idx').on(table.status),
  index('track_enrichment_recording_idx').on(table.musicbrainzRecordingId),
]);
