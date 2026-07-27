/**
 * Copie SQLite cohérente par VACUUM INTO, avec contrôles et rapport JSON.
 *
 * POURQUOI PAS UNE COPIE DE FICHIER
 * ---------------------------------
 * `runtime.db` est en WAL et vivant : un `cp` peut capturer une base sans son
 * WAL, donc un état qui n'a jamais existé (L-095). `VACUUM INTO` demande à
 * SQLite lui-même d'écrire une base NEUVE, cohérente, à partir d'une lecture
 * transactionnelle. La source n'est jamais modifiée : elle est ouverte en
 * lecture seule, et le seul fichier écrit est la destination.
 *
 * SUR user_version
 * ----------------
 * `user_version` vaut 0 sur cette base : ce n'est pas une anomalie. Drizzle
 * suit les migrations dans la table `__drizzle_migrations`. Un contrôle de
 * version portant sur `user_version` ne vérifierait rien du tout.
 *
 * CONFIDENTIALITÉ
 * ---------------
 * Le chemin source n'est jamais publié en entier : seul son nom de fichier
 * apparaît. Le rapport ne contient aucune donnée utilisateur.
 */
import { createHash } from 'node:crypto';
import { createReadStream } from 'node:fs';
import { stat, unlink, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { basename, dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);

function fail(code, detail) {
  console.log(JSON.stringify({ ok: false, error: code, detail: detail ?? null }));
  process.exit(1);
}

async function sha256(path) {
  const digest = createHash('sha256');
  for await (const chunk of createReadStream(path)) digest.update(chunk);
  return digest.digest('hex');
}

const [, , sourceArg, targetArg, modulePath] = process.argv;
if (!sourceArg || !targetArg) fail('USAGE', 'source et destination requis');

const source = resolve(sourceArg);
const target = resolve(targetArg);
if (!existsSync(source)) fail('SOURCE_ABSENTE', basename(source));
// Refus d'écraser : une destination existante peut être une copie en cours
// d'utilisation, ou la trace d'un échec précédent qu'il faut examiner.
if (existsSync(target)) fail('DESTINATION_EXISTE', basename(target));
if (resolve(source) === resolve(target)) fail('SOURCE_EGALE_DESTINATION');

let Database;
try {
  Database = require(modulePath || 'better-sqlite3');
} catch (error) {
  fail('BETTER_SQLITE3_INDISPONIBLE', String(error?.message).slice(0, 200));
}

await mkdir(dirname(target), { recursive: true });

const report = { ok: false, sourceName: basename(source), targetName: basename(target) };
let db = null;
let copy = null;
try {
  // readonly: la source ne peut pas être modifiée, même par erreur de code.
  db = new Database(source, { readonly: true, fileMustExist: true });
  report.sourceSizeBytes = (await stat(source)).size;
  report.sourceJournalMode = db.pragma('journal_mode', { simple: true });
  report.sourceUserVersion = db.pragma('user_version', { simple: true });
  report.userVersionExpectedZero = report.sourceUserVersion === 0;

  db.prepare('VACUUM INTO ?').run(target);
  db.close();
  db = null;

  copy = new Database(target, { readonly: true, fileMustExist: true });
  report.integrityCheck = copy.pragma('integrity_check', { simple: true });
  report.foreignKeyViolations = copy.pragma('foreign_key_check').length;
  report.drizzleMigrations = copy
    .prepare('SELECT count(*) AS n FROM __drizzle_migrations')
    .get().n;
  report.tableCount = copy
    .prepare("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
    .get().n;
  copy.close();
  copy = null;

  report.targetSizeBytes = (await stat(target)).size;
  report.targetSha256 = await sha256(target);
  report.sourceSha256AfterCopy = await sha256(source);
  report.sourceSizeAfterCopy = (await stat(source)).size;
  report.sourceUnchanged = report.sourceSizeAfterCopy === report.sourceSizeBytes;

  report.ok =
    report.integrityCheck === 'ok' &&
    report.foreignKeyViolations === 0 &&
    report.drizzleMigrations > 0 &&
    report.sourceUnchanged;
  if (!report.ok) throw new Error('CONTROLES_ECHOUES');
  console.log(JSON.stringify(report));
} catch (error) {
  try { db?.close(); } catch {}
  try { copy?.close(); } catch {}
  // Une copie non validée ne doit jamais rester : elle serait promue par
  // erreur à l'étape suivante.
  try { if (existsSync(target)) await unlink(target); } catch {}
  report.error = String(error?.message).slice(0, 200);
  report.targetRemoved = !existsSync(target);
  console.log(JSON.stringify(report));
  process.exit(1);
} finally {
  try { db?.close(); } catch {}
  try { copy?.close(); } catch {}
}
