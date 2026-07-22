import { createHash } from 'node:crypto';
import {
  copyFileSync,
  cpSync,
  createReadStream,
  existsSync,
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import Database from 'better-sqlite3';

export const SERVER_BACKUP_FORMAT_VERSION = 1;

export interface ServerBackupManifest {
  formatVersion: number;
  createdAt: string;
  database: {
    filename: string;
    bytes: number;
    sha256: string;
  };
  covers: { included: boolean; directory: string };
  media: { included: boolean; directory: string };
}

export interface CreateServerBackupOptions {
  dbPath: string;
  coversDir: string;
  musicDir: string;
  destinationDir: string;
  includeMedia: boolean;
  now?: Date;
}

export interface RestoreServerBackupOptions {
  backupDir: string;
  dbPath: string;
  coversDir: string;
  musicDir: string;
  restoreMedia: boolean;
  now?: Date;
}

export async function createServerBackup(
  options: CreateServerBackupOptions,
): Promise<ServerBackupManifest> {
  const destinationDir = resolve(options.destinationDir);
  const dbPath = resolve(options.dbPath);
  if (destinationDir === dbPath || destinationDir.startsWith(`${dbPath}\\`)) {
    throw new Error('Destination de sauvegarde invalide.');
  }
  if (existsSync(destinationDir)) {
    throw new Error(`La destination existe déjà : ${destinationDir}`);
  }
  mkdirSync(destinationDir, { recursive: true });
  const databaseFilename = 'homespotify.db';
  const databaseDestination = join(destinationDir, databaseFilename);
  try {
    await createVerifiedDatabaseBackup(dbPath, databaseDestination);
    const coversDestination = join(destinationDir, 'covers');
    if (existsSync(options.coversDir)) {
      cpSync(resolve(options.coversDir), coversDestination, {
        recursive: true,
        errorOnExist: false,
      });
    } else {
      mkdirSync(coversDestination, { recursive: true });
    }
    if (options.includeMedia) {
      if (!existsSync(options.musicDir)) {
        throw new Error(`Répertoire musical introuvable : ${options.musicDir}`);
      }
      cpSync(resolve(options.musicDir), join(destinationDir, 'music'), {
        recursive: true,
        errorOnExist: false,
      });
    }
    const manifest: ServerBackupManifest = {
      formatVersion: SERVER_BACKUP_FORMAT_VERSION,
      createdAt: (options.now ?? new Date()).toISOString(),
      database: {
        filename: databaseFilename,
        bytes: statSync(databaseDestination).size,
        sha256: await sha256File(databaseDestination),
      },
      covers: { included: true, directory: 'covers' },
      media: { included: options.includeMedia, directory: 'music' },
    };
    writeFileSync(
      join(destinationDir, 'manifest.json'),
      `${JSON.stringify(manifest, null, 2)}\n`,
      { encoding: 'utf8', flag: 'wx' },
    );
    return manifest;
  } catch (error) {
    rmSync(destinationDir, { recursive: true, force: true });
    throw error;
  }
}

export async function verifyServerBackup(backupDir: string): Promise<ServerBackupManifest> {
  const root = resolve(backupDir);
  const manifestPath = join(root, 'manifest.json');
  if (!existsSync(manifestPath)) throw new Error('Manifest de sauvegarde introuvable.');
  const parsed: unknown = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const manifest = parseManifest(parsed);
  const databasePath = join(root, manifest.database.filename);
  if (!existsSync(databasePath)) throw new Error('Base sauvegardée introuvable.');
  const stats = statSync(databasePath);
  if (stats.size !== manifest.database.bytes) {
    throw new Error('Taille de la base sauvegardée invalide.');
  }
  if ((await sha256File(databasePath)) !== manifest.database.sha256) {
    throw new Error('Empreinte SHA-256 de la sauvegarde invalide.');
  }
  verifySqliteIntegrity(databasePath);
  if (manifest.covers.included && !existsSync(join(root, manifest.covers.directory))) {
    throw new Error('Répertoire de pochettes sauvegardé introuvable.');
  }
  if (manifest.media.included && !existsSync(join(root, manifest.media.directory))) {
    throw new Error('Répertoire musical sauvegardé introuvable.');
  }
  return manifest;
}

export async function restoreServerBackup(
  options: RestoreServerBackupOptions,
): Promise<{ safetyCopyPath: string | null; manifest: ServerBackupManifest }> {
  const manifest = await verifyServerBackup(options.backupDir);
  if (options.restoreMedia && !manifest.media.included) {
    throw new Error('Cette sauvegarde ne contient pas les fichiers audio.');
  }
  const dbPath = resolve(options.dbPath);
  mkdirSync(dirname(dbPath), { recursive: true });
  const timestamp = (options.now ?? new Date()).toISOString().replace(/[:.]/g, '-');
  const safetyCopyPath = existsSync(dbPath) ? `${dbPath}.pre-restore-${timestamp}` : null;
  const temporaryPath = `${dbPath}.restore-${process.pid}.tmp`;
  try {
    copyFileSync(join(resolve(options.backupDir), manifest.database.filename), temporaryPath);
    verifySqliteIntegrity(temporaryPath);
    if (safetyCopyPath !== null) renameSync(dbPath, safetyCopyPath);
    rmSync(`${dbPath}-wal`, { force: true });
    rmSync(`${dbPath}-shm`, { force: true });
    renameSync(temporaryPath, dbPath);
    if (manifest.covers.included) {
      mkdirSync(resolve(options.coversDir), { recursive: true });
      cpSync(join(resolve(options.backupDir), manifest.covers.directory), resolve(options.coversDir), {
        recursive: true,
        force: true,
      });
    }
    if (options.restoreMedia) {
      mkdirSync(resolve(options.musicDir), { recursive: true });
      cpSync(join(resolve(options.backupDir), manifest.media.directory), resolve(options.musicDir), {
        recursive: true,
        force: true,
      });
    }
    return { safetyCopyPath, manifest };
  } catch (error) {
    rmSync(temporaryPath, { force: true });
    if (!existsSync(dbPath) && safetyCopyPath !== null && existsSync(safetyCopyPath)) {
      renameSync(safetyCopyPath, dbPath);
    }
    throw error;
  }
}

async function createVerifiedDatabaseBackup(sourcePath: string, destinationPath: string) {
  if (!existsSync(sourcePath)) throw new Error(`Base SQLite introuvable : ${sourcePath}`);
  mkdirSync(dirname(destinationPath), { recursive: true });
  const source = new Database(sourcePath, { readonly: true, fileMustExist: true });
  try {
    await source.backup(destinationPath);
  } finally {
    source.close();
  }
  verifySqliteIntegrity(destinationPath);
}

function verifySqliteIntegrity(path: string) {
  const database = new Database(path, { readonly: true, fileMustExist: true });
  try {
    const rows = database.pragma('integrity_check') as Array<Record<string, unknown>>;
    if (rows.length !== 1 || rows[0]?.integrity_check !== 'ok') {
      throw new Error('PRAGMA integrity_check a échoué.');
    }
  } finally {
    database.close();
    // SQLite peut créer ces fichiers techniques même lors d'une ouverture en
    // lecture seule d'une base configurée en WAL. Ils ne font pas partie de la
    // sauvegarde autonome produite par l'API backup de SQLite.
    rmSync(`${path}-wal`, { force: true });
    rmSync(`${path}-shm`, { force: true });
  }
}

function sha256File(path: string): Promise<string> {
  return new Promise((resolveHash, reject) => {
    const hash = createHash('sha256');
    const stream = createReadStream(path);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('error', reject);
    stream.on('end', () => resolveHash(hash.digest('hex')));
  });
}

function parseManifest(raw: unknown): ServerBackupManifest {
  if (typeof raw !== 'object' || raw === null) throw new Error('Manifest invalide.');
  const value = raw as Record<string, unknown>;
  const database = value.database as Record<string, unknown> | undefined;
  const covers = value.covers as Record<string, unknown> | undefined;
  const media = value.media as Record<string, unknown> | undefined;
  if (
    value.formatVersion !== SERVER_BACKUP_FORMAT_VERSION ||
    typeof value.createdAt !== 'string' ||
    Number.isNaN(Date.parse(value.createdAt)) ||
    typeof database?.filename !== 'string' ||
    database.filename !== 'homespotify.db' ||
    typeof database.bytes !== 'number' ||
    !Number.isInteger(database.bytes) ||
    database.bytes <= 0 ||
    typeof database.sha256 !== 'string' ||
    !/^[a-f0-9]{64}$/.test(database.sha256) ||
    typeof covers?.included !== 'boolean' ||
    covers.directory !== 'covers' ||
    typeof media?.included !== 'boolean' ||
    media.directory !== 'music'
  ) {
    throw new Error('Manifest invalide ou version non prise en charge.');
  }
  return raw as ServerBackupManifest;
}
