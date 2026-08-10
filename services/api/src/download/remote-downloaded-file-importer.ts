import { mkdir, stat, writeFile } from 'node:fs/promises';
import { extname, join } from 'node:path';
import { and, eq } from 'drizzle-orm';
import type { DbHandle } from '../db/client.js';
import {
  trackQuality,
  tracks,
  userHiddenTracks,
  userTracks,
} from '../db/schema.js';
import {
  analyzeAudioFile,
  hashFile,
  type AudioFileAnalysis,
} from '../import/import-service.js';
import { findExistingTrack } from '../import/track-match.js';
import { sameVersion, versionFingerprint } from '../lib/version-identity.js';
import type { RemoteLogger } from '../storage/remote/storage-agent-client.js';
import {
  StorageAgentClient,
  type DurableIndexReceipt,
  type DurableObjectReceipt,
} from '../storage/remote/storage-agent-client.js';
import { buildRemoteStorageIndexDocument } from '../storage/remote/remote-index-document.js';

export interface RemoteStorageWriteClient {
  putObject(input: {
    filePath: string;
    contentHash: string;
    extension: 'flac' | 'wav';
    sizeBytes: number;
    requestId?: string;
  }): Promise<DurableObjectReceipt>;
  putIndex(input: {
    body: Buffer;
    contentSha256: string;
    requestId?: string;
  }): Promise<DurableIndexReceipt>;
  close(): void;
}

export type RemoteDownloadedFileImportResult =
  | { status: 'IMPORTED'; trackId: number }
  | { status: 'REUSED'; trackId: number }
  | { status: 'WAITING_FOR_OWNER_MATCH'; trackIds: number[] };

export class RemoteDownloadedFileImportError extends Error {
  constructor(
    readonly code:
      | 'invalid_file'
      | 'version_mismatch'
      | 'durability_not_confirmed'
      | 'database_failed'
      | 'index_publish_failed',
    message: string,
    override readonly cause?: unknown,
  ) {
    super(message);
    this.name = 'RemoteDownloadedFileImportError';
  }
}

function objectRelativePath(
  contentHash: string,
  extension: 'flac' | 'wav',
): string {
  if (!/^[a-f0-9]{64}$/.test(contentHash)) {
    throw new RemoteDownloadedFileImportError(
      'invalid_file',
      'Empreinte audio invalide.',
    );
  }
  return `.homespotify/objects/${contentHash.slice(0, 2)}/${contentHash}.${extension}`;
}

function mimeType(extension: 'flac' | 'wav'): string {
  return extension === 'flac' ? 'audio/flac' : 'audio/wav';
}

function qualityStatus(): string {
  return 'inconnue';
}

type TrackGrantTransaction = Pick<
  DbHandle['db'],
  'select' | 'update' | 'delete' | 'insert'
>;

function grantTrackInTransaction(
  tx: TrackGrantTransaction,
  userId: number,
  trackId: number,
): void {
  const existing = tx
    .select({ isVisible: userTracks.isVisible })
    .from(userTracks)
    .where(
      and(
        eq(userTracks.userId, userId),
        eq(userTracks.trackId, trackId),
      ),
    )
    .get();

  const values = {
    addedAt: new Date().toISOString(),
    addedByUserId: null,
    source: 'MANUAL_IMPORT',
    isVisible: true,
  } as const;

  if (existing) {
    if (existing.isVisible !== true) {
      tx.update(userTracks)
        .set(values)
        .where(
          and(
            eq(userTracks.userId, userId),
            eq(userTracks.trackId, trackId),
          ),
        )
        .run();
    }
    tx.delete(userHiddenTracks)
      .where(
        and(
          eq(userHiddenTracks.userId, userId),
          eq(userHiddenTracks.trackId, trackId),
        ),
      )
      .run();
    return;
  }

  tx.insert(userTracks)
    .values({
      userId,
      trackId,
      ...values,
    })
    .run();
}

async function persistCover(
  coversDir: string,
  contentHash: string,
  analysis: AudioFileAnalysis,
): Promise<string | null> {
  if (analysis.cover === null) return null;
  await mkdir(coversDir, { recursive: true });
  const extension =
    analysis.cover.mimeType === 'image/png' ? 'png' : 'jpg';
  const relativePath = `${contentHash.slice(0, 8)}.${extension}`;
  const destination = join(coversDir, relativePath);
  await writeFile(destination, analysis.cover.data, { flag: 'wx' }).catch(
    (error: NodeJS.ErrnoException) => {
      if (error.code !== 'EEXIST') throw error;
    },
  );
  return relativePath;
}

/** Tentatives de publication de l'index, la première comprise. */
export const INDEX_PUBLISH_ATTEMPTS = 3;
/** Attente avant la n-ième tentative (index 0 = avant la deuxième). */
export const INDEX_PUBLISH_BACKOFF_MS = [250, 1_000] as const;

class RemoteStorageIndexPublisher {
  private tail: Promise<void> = Promise.resolve();

  constructor(
    private readonly handle: DbHandle,
    private readonly client: RemoteStorageWriteClient,
    private readonly logger: RemoteLogger,
    private readonly sleep: (ms: number) => Promise<void> = (ms) =>
      new Promise((resolve) => {
        setTimeout(resolve, ms).unref?.();
      }),
  ) {}

  publish(requestId?: string): Promise<DurableIndexReceipt> {
    const operation = this.tail.then(async () => {
      const document = buildRemoteStorageIndexDocument(this.handle);
      if (document.omittedTrackIds.length > 0) {
        this.logger.warn(
          {
            event: 'REMOTE_STORAGE_INDEX_ENTRIES_OMITTED',
            trackIds: document.omittedTrackIds.slice(0, 50),
            omittedCount: document.omittedTrackIds.length,
          },
          'REMOTE_STORAGE_INDEX_ENTRIES_OMITTED',
        );
      }

      // La publication est IDEMPOTENTE : le document est adressé par son
      // SHA-256 et l'agent accepte un `generatedAt` identique. Réessayer ne
      // peut donc rien corrompre — et une indisponibilité passagère du poste
      // Windows ne doit pas transformer un import réussi en échec.
      let lastError: unknown;
      for (let attempt = 1; attempt <= INDEX_PUBLISH_ATTEMPTS; attempt += 1) {
        try {
          return await this.putIndexOnce(document, requestId);
        } catch (error) {
          lastError = error;
          if (attempt === INDEX_PUBLISH_ATTEMPTS) break;
          this.logger.warn(
            {
              event: 'REMOTE_STORAGE_INDEX_PUBLISH_RETRY',
              attempt,
              maxAttempts: INDEX_PUBLISH_ATTEMPTS,
              ...(requestId === undefined ? {} : { requestId }),
            },
            'REMOTE_STORAGE_INDEX_PUBLISH_RETRY',
          );
          await this.sleep(INDEX_PUBLISH_BACKOFF_MS[attempt - 1] ?? 1_000);
        }
      }
      throw lastError;
    });
    this.tail = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }

  private async putIndexOnce(
    document: ReturnType<typeof buildRemoteStorageIndexDocument>,
    requestId?: string,
  ): Promise<DurableIndexReceipt> {
    const receipt = await this.client.putIndex({
      body: document.body,
      contentSha256: document.contentSha256,
      ...(requestId === undefined ? {} : { requestId }),
    });
    if (
      receipt.durable !== true ||
      receipt.contentSha256 !== document.contentSha256 ||
      receipt.entryCount !== document.entryCount
    ) {
      throw new RemoteDownloadedFileImportError(
        'index_publish_failed',
        'Le reçu durable de l’index est incohérent.',
      );
    }
    return receipt;
  }
}

/**
 * Pipeline Antra en mode remote/cached :
 *
 * analyse locale du staging VPS
 * -> objet durable Windows
 * -> transaction SQLite (track + qualité + attribution)
 * -> index durable Windows
 *
 * Le fichier de staging n'est jamais supprimé ici. DownloadService ne le
 * supprime qu'après le retour réussi, donc après l'index durable.
 */
export class RemoteDownloadedFileImporter {
  private readonly indexPublisher: RemoteStorageIndexPublisher;

  constructor(
    private readonly handle: DbHandle,
    private readonly options: {
      coversDir: string;
      client: RemoteStorageWriteClient;
      logger: RemoteLogger;
    },
  ) {
    this.indexPublisher = new RemoteStorageIndexPublisher(
      handle,
      options.client,
      options.logger,
    );
  }

  static fromStorageAgentClient(
    handle: DbHandle,
    options: {
      coversDir: string;
      client: StorageAgentClient;
      logger: RemoteLogger;
    },
  ): RemoteDownloadedFileImporter {
    return new RemoteDownloadedFileImporter(handle, options);
  }

  close(): void {
    this.options.client.close();
  }

  async importDownloadedFile(input: {
    userId: number;
    filePath: string;
    requestId?: string;
    /**
     * Empreinte de version DEMANDÉE par l'utilisateur (`''` = studio).
     * Absente = intention inconnue (URL collée) : aucun contrôle possible.
     */
    expectedVersionFingerprint?: string;
  }): Promise<RemoteDownloadedFileImportResult> {
    const lowerExtension = extname(input.filePath).toLowerCase();
    if (lowerExtension !== '.flac' && lowerExtension !== '.wav') {
      throw new RemoteDownloadedFileImportError(
        'invalid_file',
        'Seuls FLAC et WAV peuvent être importés à distance.',
      );
    }

    const analysis = await analyzeAudioFile(input.filePath).catch((error) => {
      throw new RemoteDownloadedFileImportError(
        'invalid_file',
        'Le fichier audio téléchargé est invalide.',
        error,
      );
    });

    // Dernière barrière avant TOUTE écriture : le fichier réellement obtenu
    // doit porter la version demandée. Elle est placée ici, sur le chemin
    // distant réel (`AUDIO_STORAGE_MODE=cached`), et non dans le seul
    // `UserImportService` : c'est ce chemin qui a installé `addiction (Slowed)`
    // à la place de `addiction` en production (LESSONS L-081).
    if (input.expectedVersionFingerprint !== undefined) {
      const downloadedVersion = versionFingerprint(analysis.title);
      if (!sameVersion(downloadedVersion, input.expectedVersionFingerprint)) {
        throw new RemoteDownloadedFileImportError(
          'version_mismatch',
          'Le fichier obtenu n’est pas la version demandée.',
        );
      }
    }
    const extension = analysis.kind;
    const [contentHash, fileInfo] = await Promise.all([
      hashFile(input.filePath),
      stat(input.filePath),
    ]);
    if (!fileInfo.isFile() || fileInfo.size <= 0) {
      throw new RemoteDownloadedFileImportError(
        'invalid_file',
        'Le fichier audio téléchargé est indisponible.',
      );
    }

    const metadata = {
      title: analysis.title,
      artist: analysis.artist,
      durationMs:
        analysis.durationSeconds === null
          ? null
          : Math.round(analysis.durationSeconds * 1000),
      isrc: analysis.isrc,
    };
    const match = findExistingTrack(
      this.handle.db,
      contentHash,
      metadata,
    );
    if (match.kind === 'ambiguous') {
      return {
        status: 'WAITING_FOR_OWNER_MATCH',
        trackIds: match.trackIds,
      };
    }

    const deterministicPath = objectRelativePath(contentHash, extension);
    if (match.kind === 'unique') {
      const existing = this.handle.db
        .select({
          id: tracks.id,
          hash: tracks.hash,
          path: tracks.path,
        })
        .from(tracks)
        .where(eq(tracks.id, match.trackId))
        .get();
      if (!existing) {
        throw new RemoteDownloadedFileImportError(
          'database_failed',
          'La piste réutilisée a disparu.',
        );
      }

      // Une reprise d'un import content-addressed refait le PUT idempotent :
      // elle prouve que l'objet existe même si la réponse précédente a été
      // perdue après publication. Un ancien chemin de bibliothèque reste
      // inchangé et n'est pas migré implicitement.
      if (
        existing.hash === contentHash &&
        existing.path.replace(/\\/g, '/') === deterministicPath
      ) {
        await this.requireDurableObject({
          filePath: input.filePath,
          contentHash,
          extension,
          sizeBytes: fileInfo.size,
          ...(input.requestId === undefined
            ? {}
            : { requestId: input.requestId }),
        });
      }

      this.handle.db.transaction((tx) => {
        grantTrackInTransaction(tx, input.userId, existing.id);
      });
      await this.publishIndex(input.requestId);
      return { status: 'REUSED', trackId: existing.id };
    }

    await this.requireDurableObject({
      filePath: input.filePath,
      contentHash,
      extension,
      sizeBytes: fileInfo.size,
      ...(input.requestId === undefined
        ? {}
        : { requestId: input.requestId }),
    });

    const coverPath = await persistCover(
      this.options.coversDir,
      contentHash,
      analysis,
    );

    let result: { status: 'IMPORTED' | 'REUSED'; trackId: number };
    try {
      result = this.handle.db.transaction((tx) => {
        // Course entre deux imports identiques : le second réutilise la ligne
        // déjà commise, sans créer de doublon.
        const raced = tx
          .select({ id: tracks.id })
          .from(tracks)
          .where(eq(tracks.hash, contentHash))
          .get();
        if (raced) {
          grantTrackInTransaction(tx, input.userId, raced.id);
          return { status: 'REUSED' as const, trackId: raced.id };
        }

        const now = new Date().toISOString();
        const inserted = tx
          .insert(tracks)
          .values({
            hash: contentHash,
            path: deterministicPath,
            originalExtension: `.${extension}`,
            mimeType: mimeType(extension),
            sizeBytes: fileInfo.size,
            durationSeconds: analysis.durationSeconds,
            title: analysis.title,
            artist: analysis.artist,
            album: analysis.album,
            year: analysis.year,
            genre: analysis.genre,
            isrc: analysis.isrc,
            coverPath,
            createdAt: now,
          })
          .returning({ id: tracks.id })
          .get();

        tx.insert(trackQuality)
          .values({
            trackId: inserted.id,
            container: analysis.container,
            codec: analysis.codec,
            sampleRate: analysis.sampleRate,
            bitDepth: analysis.bitDepth,
            channels: analysis.channels,
            status: qualityStatus(),
            provenance: 'inconnue',
            analyzedAt: now,
          })
          .run();
        grantTrackInTransaction(tx, input.userId, inserted.id);
        return { status: 'IMPORTED' as const, trackId: inserted.id };
      });
    } catch (error) {
      throw new RemoteDownloadedFileImportError(
        'database_failed',
        'L’objet est durable mais SQLite n’a pas pu être mise à jour.',
        error,
      );
    }

    await this.publishIndex(input.requestId);
    return result;
  }

  private async requireDurableObject(input: {
    filePath: string;
    contentHash: string;
    extension: 'flac' | 'wav';
    sizeBytes: number;
    requestId?: string;
  }): Promise<void> {
    let receipt: DurableObjectReceipt;
    try {
      receipt = await this.options.client.putObject(input);
    } catch (error) {
      throw new RemoteDownloadedFileImportError(
        'durability_not_confirmed',
        'Le Storage Agent n’a pas confirmé la durabilité du fichier.',
        error,
      );
    }
    if (
      receipt.durable !== true ||
      receipt.contentHash !== input.contentHash ||
      receipt.extension !== input.extension ||
      receipt.sizeBytes !== input.sizeBytes
    ) {
      throw new RemoteDownloadedFileImportError(
        'durability_not_confirmed',
        'Le reçu durable du fichier est incohérent.',
      );
    }
  }

  private async publishIndex(requestId?: string): Promise<void> {
    try {
      await this.indexPublisher.publish(requestId);
    } catch (error) {
      if (error instanceof RemoteDownloadedFileImportError) throw error;
      throw new RemoteDownloadedFileImportError(
        'index_publish_failed',
        'SQLite est à jour mais l’index distant n’a pas été publié.',
        error,
      );
    }
  }
}
