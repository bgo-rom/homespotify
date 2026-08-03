/**
 * Index local `trackId → chemin relatif`.
 *
 * L'agent ne reçoit JAMAIS de chemin depuis le réseau : le VPS envoie un
 * identifiant numérique, l'agent le traduit via cet index, et lui seul. C'est
 * la propriété de sécurité centrale de la Phase 2.
 *
 * L'index initial peut être produit par le CLI en lecture seule de l'API
 * principale (`pnpm --filter @homespotify/api storage-index:export`). En mode
 * hybride, l'API VPS republie ensuite le document complet par la route interne
 * signée ; le magasin valide, synchronise et remplace atomiquement le fichier.
 */
import { createHash, randomUUID } from 'node:crypto';
import { statSync, readFileSync } from 'node:fs';
import { mkdir, open, rename, rm, stat } from 'node:fs/promises';
import { dirname } from 'node:path';
import { StorageAgentError } from './errors.js';
import { PathSafetyError, toPortableRelativePath } from './path-safety.js';

/** Seule version supportée. Une version inconnue est un rejet, pas une migration. */
export const SUPPORTED_INDEX_VERSION = 1;

/** Clé d'entrée canonique : entier décimal positif, sans zéro initial. */
const CANONICAL_ID = /^[1-9][0-9]{0,14}$/;

const ISO_8601 =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/;

const TOP_LEVEL_KEYS = new Set(['version', 'generatedAt', 'entries']);
const ENTRY_KEYS = new Set(['relativePath']);

export interface ParsedStorageIndex {
  version: number;
  generatedAt: string;
  /** trackId → chemin relatif PORTABLE (séparateur `/`), déjà validé. */
  entries: ReadonlyMap<number, string>;
}

export interface LoadedStorageIndex extends ParsedStorageIndex {
  /** Heure de chargement effectif en mémoire. */
  loadedAt: Date;
  /** Empreinte de la source, pour la détection de modification. */
  fingerprint: string;
}

export interface DurableIndexReceipt {
  contentSha256: string;
  entryCount: number;
  generatedAt: string;
  durable: true;
}

function invalid(detail: string): StorageAgentError {
  return new StorageAgentError('INDEX_INVALID', detail);
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

/**
 * Valide et convertit le document d'index. Lève `INDEX_INVALID` au premier
 * défaut : un index partiellement bon est un index refusé.
 *
 * Les détails d'erreur ne contiennent JAMAIS le chemin fautif, seulement
 * l'identifiant de piste et le motif — un chemin musical est une donnée
 * personnelle qui n'a rien à faire dans un log.
 */
export function parseStorageIndex(raw: string): ParsedStorageIndex {
  let document: unknown;
  try {
    document = JSON.parse(raw) as unknown;
  } catch {
    throw invalid('JSON illisible');
  }

  if (!isPlainObject(document)) throw invalid('racine JSON non objet');

  for (const key of Object.keys(document)) {
    if (!TOP_LEVEL_KEYS.has(key)) throw invalid(`clé racine inconnue "${key}"`);
  }

  if (document.version !== SUPPORTED_INDEX_VERSION) {
    throw invalid(`version non supportée (${String(document.version)})`);
  }

  const generatedAt = document.generatedAt;
  if (typeof generatedAt !== 'string' || !ISO_8601.test(generatedAt) || Number.isNaN(Date.parse(generatedAt))) {
    throw invalid('generatedAt absent ou non ISO-8601');
  }

  const rawEntries = document.entries;
  if (!isPlainObject(rawEntries)) throw invalid('entries absent ou non objet');

  const entries = new Map<number, string>();
  for (const [key, value] of Object.entries(rawEntries)) {
    // Forme canonique obligatoire : « 01 », « 1.0 » ou « +1 » désigneraient la
    // même piste que « 1 » et créeraient un alias ambigu. Refusés d'emblée.
    if (!CANONICAL_ID.test(key)) throw invalid(`identifiant non canonique "${key}"`);
    const trackId = Number(key);
    if (!Number.isSafeInteger(trackId)) throw invalid(`identifiant hors bornes "${key}"`);
    if (entries.has(trackId)) throw invalid(`identifiant en doublon "${key}"`);

    if (!isPlainObject(value)) throw invalid(`entrée #${trackId} non objet`);
    for (const entryKey of Object.keys(value)) {
      if (!ENTRY_KEYS.has(entryKey)) {
        throw invalid(`entrée #${trackId} : champ inconnu "${entryKey}"`);
      }
    }

    let portable: string;
    try {
      portable = toPortableRelativePath(value.relativePath);
    } catch (error) {
      const reason = error instanceof PathSafetyError ? error.reason : 'UNKNOWN';
      throw invalid(`entrée #${trackId} : chemin refusé (${reason})`);
    }
    entries.set(trackId, portable);
  }

  return { version: SUPPORTED_INDEX_VERSION, generatedAt, entries };
}

export type IndexEvent =
  | { event: 'STORAGE_AGENT_INDEX_LOADED'; entryCount: number; indexVersion: number; generatedAt: string }
  | { event: 'STORAGE_AGENT_INDEX_REJECTED'; reason: string; keptPreviousIndex: boolean };

export interface StorageIndexStoreOptions {
  indexPath: string;
  /** 0 = aucune scrutation ; le rechargement reste appelable manuellement. */
  pollIntervalMs?: number;
  onEvent?: (event: IndexEvent) => void;
  now?: () => Date;
}

/**
 * Conserve le dernier index VALIDE.
 *
 * Invariant : un fichier invalide ne remplace jamais un index déjà chargé. Le
 * remplacement est un simple échange de référence — atomique de fait, le
 * moteur étant mono-thread : aucune requête ne peut observer un index à moitié
 * construit.
 */
export class StorageIndexStore {
  private index: LoadedStorageIndex | null = null;
  private lastRejection: string | null = null;
  private timer: NodeJS.Timeout | null = null;
  private lastFingerprint: string | null = null;
  private publicationTail: Promise<void> = Promise.resolve();
  private readonly now: () => Date;

  constructor(private readonly options: StorageIndexStoreOptions) {
    this.now = options.now ?? (() => new Date());
  }

  get current(): LoadedStorageIndex | null {
    return this.index;
  }

  get lastRejectionReason(): string | null {
    return this.lastRejection;
  }

  lookup(trackId: number): string | undefined {
    return this.index?.entries.get(trackId);
  }

  /**
   * Charge l'index si le fichier a changé (mtime + taille).
   * Retourne `true` si un nouvel index valide a été installé.
   *
   * Ne lève jamais : un échec est journalisé et laisse l'index précédent en
   * place. Le démarrage lui-même n'est donc pas bloqué par un index absent —
   * l'agent démarre, `/health` répond `unhealthy`, et l'exploitant voit
   * pourquoi.
   */
  reloadIfChanged(): boolean {
    let fingerprint: string;
    try {
      const info = statSync(this.options.indexPath);
      if (!info.isFile()) {
        this.reject('index inexistant ou non régulier');
        return false;
      }
      fingerprint = `${info.mtimeMs}:${info.size}`;
    } catch {
      this.reject('index illisible');
      return false;
    }

    if (fingerprint === this.lastFingerprint && this.index !== null) return false;

    let raw: string;
    try {
      raw = readFileSync(this.options.indexPath, 'utf-8');
    } catch {
      this.reject('index illisible');
      return false;
    }

    let parsed: ParsedStorageIndex;
    try {
      parsed = parseStorageIndex(raw);
    } catch (error) {
      this.reject(error instanceof StorageAgentError ? (error.detail ?? 'index invalide') : 'index invalide');
      return false;
    }

    // Échange atomique : la nouvelle valeur est complète avant d'être publiée.
    this.index = { ...parsed, loadedAt: this.now(), fingerprint };
    this.lastFingerprint = fingerprint;
    this.lastRejection = null;
    this.options.onEvent?.({
      event: 'STORAGE_AGENT_INDEX_LOADED',
      entryCount: parsed.entries.size,
      indexVersion: parsed.version,
      generatedAt: parsed.generatedAt,
    });
    return true;
  }

  /**
   * Publie un index reçu du VPS après validation complète.
   *
   * L'écriture est sérialisée et durable : fichier temporaire sur le même
   * volume, fsync, renommage atomique, réouverture du nom final, fsync, puis
   * échange de la référence en mémoire. Un index plus ancien que celui déjà
   * chargé est refusé.
   */
  publish(
    raw: Buffer,
    expectedSha256: string,
  ): Promise<DurableIndexReceipt> {
    const operation = this.publicationTail.then(() =>
      this.publishOnce(raw, expectedSha256),
    );
    this.publicationTail = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }

  private async publishOnce(
    raw: Buffer,
    expectedSha256: string,
  ): Promise<DurableIndexReceipt> {
    const observedSha256 = createHash('sha256').update(raw).digest('hex');
    if (observedSha256 !== expectedSha256) {
      throw new StorageAgentError('INDEX_HASH_MISMATCH');
    }

    const parsed = parseStorageIndex(raw.toString('utf8'));
    if (
      this.index !== null &&
      Date.parse(parsed.generatedAt) < Date.parse(this.index.generatedAt)
    ) {
      throw new StorageAgentError('INDEX_STALE_UPLOAD');
    }

    const directory = dirname(this.options.indexPath);
    const temporaryPath =
      `${this.options.indexPath}.${randomUUID()}.part`;
    try {
      await mkdir(directory, { recursive: true });
      const temporary = await open(temporaryPath, 'wx', 0o600);
      try {
        await temporary.writeFile(raw);
        await temporary.sync();
      } finally {
        await temporary.close();
      }

      await rename(temporaryPath, this.options.indexPath);

      const finalHandle = await open(this.options.indexPath, 'r+');
      try {
        await finalHandle.sync();
      } finally {
        await finalHandle.close();
      }

      const info = await stat(this.options.indexPath);
      const fingerprint = `${info.mtimeMs}:${info.size}`;
      this.index = {
        ...parsed,
        loadedAt: this.now(),
        fingerprint,
      };
      this.lastFingerprint = fingerprint;
      this.lastRejection = null;
      this.options.onEvent?.({
        event: 'STORAGE_AGENT_INDEX_LOADED',
        entryCount: parsed.entries.size,
        indexVersion: parsed.version,
        generatedAt: parsed.generatedAt,
      });
      return {
        contentSha256: observedSha256,
        entryCount: parsed.entries.size,
        generatedAt: parsed.generatedAt,
        durable: true,
      };
    } catch (error) {
      await rm(temporaryPath, { force: true }).catch(() => undefined);
      if (error instanceof StorageAgentError) throw error;
      throw new StorageAgentError('INDEX_WRITE_FAILED');
    }
  }

  private reject(reason: string): void {
    this.lastRejection = reason;
    // L'empreinte n'est pas mémorisée : un fichier refusé doit être réessayé au
    // prochain tour, sinon une correction sur place passerait inaperçue.
    this.options.onEvent?.({
      event: 'STORAGE_AGENT_INDEX_REJECTED',
      reason,
      keptPreviousIndex: this.index !== null,
    });
  }

  /** Démarre la scrutation périodique. Timer `unref` : ne retient pas le process. */
  start(): void {
    this.reloadIfChanged();
    const interval = this.options.pollIntervalMs ?? 0;
    if (interval <= 0 || this.timer !== null) return;
    this.timer = setInterval(() => {
      this.reloadIfChanged();
    }, interval);
    this.timer.unref();
  }

  stop(): void {
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
  }
}
