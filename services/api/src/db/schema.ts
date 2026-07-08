import { integer, real, sqliteTable, text } from 'drizzle-orm/sqlite-core';

export const appMeta = sqliteTable('app_meta', {
  key: text('key').primaryKey(),
  value: text('value').notNull(),
  updatedAt: text('updated_at').notNull(),
});

export const tracks = sqliteTable('tracks', {
  id: integer('id').primaryKey({ autoIncrement: true }),
  hash: text('hash').notNull().unique(), // SHA-256 du fichier, calculé en flux
  path: text('path').notNull(), // relatif à musicDir
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
