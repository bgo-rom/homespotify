/**
 * Magasin d'objets audio immuables du Storage Agent.
 *
 * Un objet est adressé uniquement par son SHA-256 et son extension contrôlée.
 * Aucun chemin choisi par le réseau n'est accepté. La publication suit :
 *
 *   flux -> fichier .part unique -> SHA/taille -> fsync -> rename atomique
 *        -> réouverture du nom final -> fsync -> reçu durable
 *
 * Le nom final est déterministe et confiné sous MUSIC_ROOT :
 * `.homespotify/objects/ab/<sha256>.flac`.
 */
import { createHash, randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream } from 'node:fs';
import {
  mkdir,
  open,
  rename,
  rm,
  stat,
  type FileHandle,
} from 'node:fs/promises';
import { dirname, isAbsolute, relative, resolve } from 'node:path';
import { Transform, type Readable, type TransformCallback } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const SHA256 = /^[a-f0-9]{64}$/;
const EXTENSIONS = new Set(['flac', 'wav']);

export type ObjectExtension = 'flac' | 'wav';

export type ObjectStoreErrorCode =
  | 'INVALID_OBJECT'
  | 'OBJECT_TOO_LARGE'
  | 'OBJECT_HASH_MISMATCH'
  | 'OBJECT_SIZE_MISMATCH'
  | 'OBJECT_WRITE_FAILED';

export class ObjectStoreError extends Error {
  constructor(
    readonly code: ObjectStoreErrorCode,
    readonly detail?: string,
  ) {
    super(code);
    this.name = 'ObjectStoreError';
  }
}

export interface DurableObjectReceipt {
  contentHash: string;
  extension: ObjectExtension;
  sizeBytes: number;
  relativePath: string;
  reused: boolean;
  durable: true;
}

export interface DurableObjectInfo {
  contentHash: string;
  extension: ObjectExtension;
  sizeBytes: number;
  relativePath: string;
  absolutePath: string;
  modifiedAt: Date;
}

export interface StoreObjectInput {
  contentHash: string;
  extension: ObjectExtension;
  expectedSizeBytes: number;
  source: Readable;
}

function validateHash(contentHash: string): string {
  const normalized = contentHash.toLowerCase();
  if (!SHA256.test(normalized)) {
    throw new ObjectStoreError('INVALID_OBJECT', 'empreinte invalide');
  }
  return normalized;
}

function validateExtension(extension: string): ObjectExtension {
  const normalized = extension.toLowerCase();
  if (!EXTENSIONS.has(normalized)) {
    throw new ObjectStoreError('INVALID_OBJECT', 'extension invalide');
  }
  return normalized as ObjectExtension;
}

function confined(root: string, candidate: string): string {
  const absoluteRoot = resolve(root);
  const absoluteCandidate = resolve(candidate);
  const rel = relative(absoluteRoot, absoluteCandidate);
  if (rel === '' || (!rel.startsWith('..') && !isAbsolute(rel))) {
    return absoluteCandidate;
  }
  throw new ObjectStoreError('INVALID_OBJECT', 'confinement refusé');
}

export function objectRelativePath(
  contentHash: string,
  extension: string,
): string {
  const hash = validateHash(contentHash);
  const ext = validateExtension(extension);
  return `.homespotify/objects/${hash.slice(0, 2)}/${hash}.${ext}`;
}

export function objectAbsolutePath(
  musicRoot: string,
  contentHash: string,
  extension: string,
): string {
  return confined(
    musicRoot,
    resolve(musicRoot, objectRelativePath(contentHash, extension)),
  );
}

async function hashFile(path: string): Promise<string> {
  const hasher = createHash('sha256');
  for await (const chunk of createReadStream(path)) {
    hasher.update(chunk as Buffer);
  }
  return hasher.digest('hex');
}

async function verifySource(
  source: Readable,
  expectedHash: string,
  expectedSize: number,
): Promise<void> {
  const hasher = createHash('sha256');
  let bytes = 0;
  for await (const chunk of source) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    bytes += buffer.length;
    if (bytes > expectedSize) {
      throw new ObjectStoreError(
        'OBJECT_SIZE_MISMATCH',
        'corps plus grand que déclaré',
      );
    }
    hasher.update(buffer);
  }
  if (bytes !== expectedSize) {
    throw new ObjectStoreError('OBJECT_SIZE_MISMATCH', 'corps tronqué');
  }
  if (hasher.digest('hex') !== expectedHash) {
    throw new ObjectStoreError(
      'OBJECT_HASH_MISMATCH',
      'empreinte observée différente',
    );
  }
}

async function syncAndClose(handle: FileHandle): Promise<void> {
  try {
    await handle.sync();
  } finally {
    await handle.close();
  }
}

/**
 * Réouvre le nom FINAL et le synchronise. Sous Windows, cela appelle
 * FlushFileBuffers sur le fichier après le renommage : le reçu n'est renvoyé
 * qu'après cette barrière.
 */
async function syncFinalName(path: string): Promise<void> {
  const handle = await open(path, 'r+');
  await syncAndClose(handle);
}

export class DurableObjectStore {
  private readonly inFlight = new Map<string, Promise<DurableObjectReceipt>>();

  constructor(
    private readonly options: {
      musicRoot: string;
      maxBytes: number;
    },
  ) {}

  get activeWrites(): number {
    return this.inFlight.size;
  }

  async stat(
    contentHash: string,
    extension: string,
  ): Promise<DurableObjectInfo> {
    const hash = validateHash(contentHash);
    const ext = validateExtension(extension);
    const relativePath = objectRelativePath(hash, ext);
    const absolutePath = objectAbsolutePath(this.options.musicRoot, hash, ext);
    const info = await stat(absolutePath);
    if (!info.isFile()) {
      throw new ObjectStoreError('INVALID_OBJECT', 'objet non fichier');
    }
    return {
      contentHash: hash,
      extension: ext,
      sizeBytes: info.size,
      relativePath,
      absolutePath,
      modifiedAt: info.mtime,
    };
  }

  async store(input: StoreObjectInput): Promise<DurableObjectReceipt> {
    let hash: string;
    let ext: ObjectExtension;
    try {
      hash = validateHash(input.contentHash);
      ext = validateExtension(input.extension);
      if (
        !Number.isSafeInteger(input.expectedSizeBytes) ||
        input.expectedSizeBytes <= 0
      ) {
        throw new ObjectStoreError('OBJECT_SIZE_MISMATCH', 'taille invalide');
      }
      if (input.expectedSizeBytes > this.options.maxBytes) {
        throw new ObjectStoreError('OBJECT_TOO_LARGE', 'objet trop volumineux');
      }
    } catch (error) {
      // Un refus avant consommation ne doit jamais laisser une source ouverte.
      input.source.destroy();
      throw error;
    }

    const normalizedInput = {
      ...input,
      contentHash: hash,
      extension: ext,
    };
    const key = `${hash}.${ext}`;
    const current = this.inFlight.get(key);
    if (current !== undefined) {
      // Chaque requête reste vérifiée et entièrement consommée, même si une
      // écriture identique est déjà en cours. Le suiveur attend la preuve
      // durable du leader mais reçoit `reused: true` : deux clients ne doivent
      // jamais croire qu'ils ont tous deux créé le même objet immuable.
      await verifySource(
        input.source,
        hash,
        input.expectedSizeBytes,
      );
      const receipt = await current;
      return { ...receipt, reused: true };
    }

    const operation = this.storeOnce(normalizedInput);
    this.inFlight.set(key, operation);
    operation.then(
      () => {
        if (this.inFlight.get(key) === operation) this.inFlight.delete(key);
      },
      () => {
        if (this.inFlight.get(key) === operation) this.inFlight.delete(key);
      },
    );
    return operation;
  }

  private async storeOnce(
    input: StoreObjectInput & {
      contentHash: string;
      extension: ObjectExtension;
    },
  ): Promise<DurableObjectReceipt> {
    const relativePath = objectRelativePath(
      input.contentHash,
      input.extension,
    );
    const finalPath = objectAbsolutePath(
      this.options.musicRoot,
      input.contentHash,
      input.extension,
    );

    const existing = await this.inspectExisting(
      finalPath,
      input.contentHash,
      input.expectedSizeBytes,
    );
    if (existing) {
      await verifySource(
        input.source,
        input.contentHash,
        input.expectedSizeBytes,
      );
      return {
        contentHash: input.contentHash,
        extension: input.extension,
        sizeBytes: input.expectedSizeBytes,
        relativePath,
        reused: true,
        durable: true,
      };
    }

    await mkdir(dirname(finalPath), { recursive: true });
    const incomingDir = confined(
      this.options.musicRoot,
      resolve(this.options.musicRoot, '.homespotify', 'incoming'),
    );
    await mkdir(incomingDir, { recursive: true });
    const partPath = confined(
      incomingDir,
      resolve(
        incomingDir,
        `${input.contentHash}.${input.extension}.${randomUUID()}.part`,
      ),
    );

    try {
      const hasher = createHash('sha256');
      let bytes = 0;
      const meter = new Transform({
        transform(
          chunk: Buffer,
          _encoding: BufferEncoding,
          callback: TransformCallback,
        ) {
          bytes += chunk.length;
          if (bytes > input.expectedSizeBytes) {
            callback(
              new ObjectStoreError(
                'OBJECT_SIZE_MISMATCH',
                'corps plus grand que déclaré',
              ),
            );
            return;
          }
          hasher.update(chunk);
          callback(null, chunk);
        },
      });
      // Le WriteStream gère et ferme son propre descripteur. Utiliser
      // FileHandle.createWriteStream(autoClose=false) ferait attendre `pipeline`
      // indéfiniment sur l'événement close.
      const destination = createWriteStream(partPath, {
        flags: 'wx',
        mode: 0o600,
      });
      await pipeline(input.source, meter, destination);

      if (bytes !== input.expectedSizeBytes) {
        throw new ObjectStoreError(
          'OBJECT_SIZE_MISMATCH',
          'corps tronqué',
        );
      }
      if (hasher.digest('hex') !== input.contentHash) {
        throw new ObjectStoreError(
          'OBJECT_HASH_MISMATCH',
          'empreinte observée différente',
        );
      }

      const partialHandle = await open(partPath, 'r+');
      await syncAndClose(partialHandle);

      try {
        await rename(partPath, finalPath);
      } catch (error) {
        // Un autre processus peut avoir publié le même objet entre le stat et
        // le rename. On n'écrase rien : on vérifie le nom final puis on réutilise.
        const raced = await this.inspectExisting(
          finalPath,
          input.contentHash,
          input.expectedSizeBytes,
        );
        if (!raced) throw error;
        await rm(partPath, { force: true });
        return {
          contentHash: input.contentHash,
          extension: input.extension,
          sizeBytes: input.expectedSizeBytes,
          relativePath,
          reused: true,
          durable: true,
        };
      }

      await syncFinalName(finalPath);
      return {
        contentHash: input.contentHash,
        extension: input.extension,
        sizeBytes: input.expectedSizeBytes,
        relativePath,
        reused: false,
        durable: true,
      };
    } catch (error) {
      // Couvre aussi les refus sur un objet final préexistant corrompu : la
      // requête entrante ne doit jamais conserver un descripteur ouvert.
      input.source.destroy();
      if (error instanceof ObjectStoreError) throw error;
      throw new ObjectStoreError(
        'OBJECT_WRITE_FAILED',
        error instanceof Error ? error.name : 'erreur inconnue',
      );
    } finally {
      await rm(partPath, { force: true }).catch(() => undefined);
    }
  }

  private async inspectExisting(
    finalPath: string,
    expectedHash: string,
    expectedSize: number,
  ): Promise<boolean> {
    let info;
    try {
      info = await stat(finalPath);
    } catch {
      return false;
    }
    if (!info.isFile() || info.size !== expectedSize) {
      throw new ObjectStoreError(
        'OBJECT_SIZE_MISMATCH',
        'objet final incompatible',
      );
    }
    if ((await hashFile(finalPath)) !== expectedHash) {
      throw new ObjectStoreError(
        'OBJECT_HASH_MISMATCH',
        'objet final corrompu',
      );
    }
    await syncFinalName(finalPath);
    return true;
  }
}
