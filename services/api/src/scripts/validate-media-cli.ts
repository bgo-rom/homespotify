/**
 * Validation Phase 7 (hors tests) : force un cycle média RÉEL sur une COPIE de
 * la base réelle. Provider iTunes durci (storefront FR) + validation HEAD
 * réelle. Aucune écriture sur la base de production. Usage :
 *   tsx src/scripts/validate-media-cli.ts <chemin-copie.db> [userId] [budget]
 */
import Database from 'better-sqlite3';
import { drizzle } from 'drizzle-orm/better-sqlite3';
import { eq } from 'drizzle-orm';
import * as schema from '../db/schema.js';
import type { DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import { recommendationCandidates, userRecommendationQueue } from '../db/schema.js';
import { ItunesCatalogProvider } from '../discovery/preview-provider.js';
import { validatePreviewUrl } from '../discovery/media-validation.js';
import {
  resolveMediaForCandidates,
  scoreCandidatesForUser,
  composeQueue,
  RECOMMENDATION_MODEL_VERSION,
} from '../discovery/recommendation-engine.js';

const dbPath = process.argv[2];
const userId = Number(process.argv[3] ?? 1);
const budget = Number(process.argv[4] ?? 90);
if (!dbPath) throw new Error('chemin de base requis');

const sqlite = new Database(dbPath);
sqlite.pragma('journal_mode = WAL');
sqlite.pragma('foreign_keys = ON');
const handle: DbHandle = { db: drizzle(sqlite, { schema }), sqlite };

const silent = { info: () => {}, error: () => {} };
runMigrations(handle, silent);

const itunes = new ItunesCatalogProvider({ storefront: 'FR' });
const now = new Date();

function funnel(tag: string) {
  const rows = sqlite
    .prepare(
      `SELECT media_resolution_status s, count(*) n FROM recommendation_candidates WHERE is_active=1 GROUP BY s`,
    )
    .all() as Array<{ s: string; n: number }>;
  const map: Record<string, number> = {};
  for (const r of rows) map[r.s] = r.n;
  console.log(`\n[${tag}] media status:`, JSON.stringify(map));
}

async function main() {
  funnel('AVANT');

  // Ordre de priorité = scoring réel de l'utilisateur.
  const scored = scoreCandidatesForUser(handle, userId);
  const ids = scored.map((s) => s.candidateId);
  console.log(`\nCandidats scorés (éligibles) pour user ${userId} : ${ids.length}`);

  const outcome = await resolveMediaForCandidates(
    handle,
    ids,
    { similarityProvider: null, previewProvider: itunes, previewValidator: validatePreviewUrl },
    now,
    budget,
  );
  console.log('Résolution média :', JSON.stringify(outcome));
  funnel('APRÈS');

  // Raisons d'échec.
  const reasons = sqlite
    .prepare(
      `SELECT media_failure_reason r, count(*) n FROM recommendation_candidates
       WHERE is_active=1 AND media_failure_reason IS NOT NULL GROUP BY r ORDER BY n DESC`,
    )
    .all() as Array<{ r: string; n: number }>;
  console.log('\nRaisons d’échec :', reasons.map((x) => `${x.r}=${x.n}`).join('  '));

  // Compose la file finale sur les MEDIA_READY et l'écrit.
  const rescored = scoreCandidatesForUser(handle, userId);
  const readyIds = new Set(
    (
      sqlite
        .prepare(
          `SELECT id FROM recommendation_candidates WHERE is_active=1 AND media_resolution_status='MEDIA_READY'`,
        )
        .all() as Array<{ id: number }>
    ).map((r) => r.id),
  );
  const eligible = rescored.filter((s) => readyIds.has(s.candidateId));
  const composed = composeQueue(eligible);

  handle.db.transaction((tx) => {
    tx.delete(userRecommendationQueue).where(eq(userRecommendationQueue.userId, userId)).run();
    composed.forEach((item, index) => {
      tx.insert(userRecommendationQueue)
        .values({
          userId,
          candidateId: item.candidateId,
          score: item.score,
          rank: index + 1,
          reasonCode: item.reasonCode,
          reasonText: item.reasonText,
          category: item.category,
          servedAt: null,
          generatedAt: now.toISOString(),
          expiresAt: new Date(now.getTime() + 86400000).toISOString(),
          modelVersion: RECOMMENDATION_MODEL_VERSION,
        })
        .run();
    });
  });

  // Rapport final : au moins 10 cartes, prouve 100 % artwork + extrait.
  const cards = sqlite
    .prepare(
      `SELECT urq.rank, rc.canonical_artist ca, rc.canonical_title ct, rc.artist, rc.title,
              urq.score, urq.category, rc.preview_provider pp, rc.preview_confidence conf,
              rc.artwork_width aw, rc.artwork_height ah, rc.artwork_provider ap,
              rc.preview_url pv, rc.media_resolution_status st
       FROM user_recommendation_queue urq
       JOIN recommendation_candidates rc ON rc.id=urq.candidate_id
       WHERE urq.user_id=? ORDER BY urq.rank`,
    )
    .all(userId) as Array<Record<string, unknown>>;

  console.log(`\n===== FILE FINALE user ${userId} : ${cards.length} cartes =====`);
  let missing = 0;
  for (const c of cards) {
    const hasArt = c.pv && c.aw && (c.aw as number) >= 500 && c.ah && (c.ah as number) >= 500;
    const hasPrev = typeof c.pv === 'string' && (c.pv as string).startsWith('https://');
    if (!hasArt || !hasPrev) missing += 1;
    if ((c.rank as number) <= 12) {
      console.log(
        `#${String(c.rank).padStart(2)} [${c.category}] conf=${c.conf} ${c.ap}/${c.aw}x${c.ah} ` +
          `${c.pp} ${(c.ca as string) || (c.artist as string)} — ${(c.ct as string) || (c.title as string)}`,
      );
    }
  }
  console.log(`\nCartes SANS artwork+extrait valides : ${missing} / ${cards.length}`);
  console.log(missing === 0 && cards.length >= 10 ? '✅ PREUVE : 100% MEDIA_READY' : '❌ ÉCHEC');
  sqlite.close();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
