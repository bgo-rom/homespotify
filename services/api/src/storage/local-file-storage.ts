import { createReadStream } from 'node:fs';
import { stat } from 'node:fs/promises';
import { resolve, sep } from 'node:path';
import { performance } from 'node:perf_hooks';
import type { Readable } from 'node:stream';
import {
  AudioStorageError,
  type AudioFileInfo,
  type AudioStorageProvider,
  type ByteRange,
  type StorageHealth,
  type TrackStorageReference,
} from './audio-storage.js';

/** Taille de tampon du flux — reprise à l'identique du streaming actuel. */
const DEFAULT_HIGH_WATER_MARK = 256 * 1024;

/**
 * Stockage sur le système de fichiers local.
 *
 * C'est le provider utilisé aujourd'hui en production Windows, et il restera
 * utilisé sur le VPS pour les variantes hors ligne (dérivées régénérables, qui
 * n'ont aucune raison de transiter par le PC).
 *
 * Une instance = une racine. Le backend en crée deux : la bibliothèque
 * (`musicDir`) et le cache de dérivées (`offlineCacheDir`).
 */
export class LocalFileStorageProvider implements AudioStorageProvider {
  private readonly root: string;

  constructor(
    root: string,
    private readonly highWaterMark: number = DEFAULT_HIGH_WATER_MARK,
  ) {
    // Résolue une fois : toutes les comparaisons de confinement s'y réfèrent.
    this.root = resolve(root);
  }

  /**
   * Résout une référence en chemin absolu, en garantissant le confinement.
   *
   * Double barrière :
   * 1. `toPortableRelativePath` a déjà rejeté `..`, les chemins absolus et UNC
   *    à la construction de la référence ;
   * 2. ici, on vérifie que le chemin RÉSOLU est bien sous la racine.
   *
   * La seconde barrière attrape ce que la première ne peut pas voir : liens
   * symboliques exclus (traités par `stat` qui suit les liens), et surtout
   * toute référence fabriquée sans passer par le constructeur normal.
   */
  resolvePath(reference: TrackStorageReference): string {
    const candidate = resolve(this.root, reference.relativePath);

    // Égal à la racine = on désigne le dossier lui-même, jamais un fichier.
    if (candidate === this.root) {
      throw new AudioStorageError(
        'PATH_TRAVERSAL',
        'La référence désigne la racine de stockage, pas un fichier.',
      );
    }
    if (!candidate.startsWith(this.root + sep)) {
      throw new AudioStorageError(
        'PATH_TRAVERSAL',
        'La référence sort de la racine de stockage.',
      );
    }
    return candidate;
  }

  async stat(reference: TrackStorageReference): Promise<AudioFileInfo> {
    const absolutePath = this.resolvePath(reference);

    let info;
    try {
      info = await stat(absolutePath);
    } catch (error) {
      const code =
        error instanceof Error && 'code' in error
          ? String((error as NodeJS.ErrnoException).code)
          : 'STAT_FAILED';
      throw new AudioStorageError(
        code === 'ENOENT' ? 'NOT_FOUND' : 'READ_FAILED',
        'Fichier audio introuvable ou illisible.',
        error,
      );
    }

    if (!info.isFile()) {
      throw new AudioStorageError(
        'NOT_A_FILE',
        'La référence ne désigne pas un fichier régulier.',
      );
    }

    return {
      sizeBytes: info.size,
      modifiedAt: info.mtime,
      source: 'local',
    };
  }

  async createReadStream(
    reference: TrackStorageReference,
    range?: ByteRange,
  ): Promise<Readable> {
    const absolutePath = this.resolvePath(reference);

    // Les bornes sont transmises telles quelles à `createReadStream`, dont la
    // sémantique (inclusive des deux côtés) est identique à celle d'HTTP.
    return createReadStream(absolutePath, {
      ...(range ? { start: range.start, end: range.end } : {}),
      highWaterMark: this.highWaterMark,
    });
  }

  /**
   * Vérifie que la racine est accessible.
   *
   * Ne teste aucun fichier en particulier : un fichier manquant est une erreur
   * de référence, pas une panne de stockage.
   */
  async healthCheck(): Promise<StorageHealth> {
    const startedAt = performance.now();
    try {
      const info = await stat(this.root);
      if (!info.isDirectory()) {
        return {
          status: 'degraded',
          reason: 'La racine de stockage n’est pas un répertoire.',
        };
      }
      return {
        status: 'online',
        source: 'local',
        latencyMs: performance.now() - startedAt,
      };
    } catch (error) {
      return {
        status: 'offline',
        reason:
          error instanceof Error
            ? `Racine de stockage inaccessible (${error.message}).`
            : 'Racine de stockage inaccessible.',
      };
    }
  }
}
