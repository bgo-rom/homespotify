import { sqliteTable, text } from 'drizzle-orm/sqlite-core';

// Table de validation de la fondation DB. Les tables musique arrivent en Phase 2/3.
export const appMeta = sqliteTable('app_meta', {
  key: text('key').primaryKey(),
  value: text('value').notNull(),
  updatedAt: text('updated_at').notNull(),
});
