/**
 * Primitives de confinement des chemins.
 *
 * Portage volontairement AUTONOME des primitives de la Phase 1
 * (`services/api/src/storage/audio-storage.ts` :: `toPortableRelativePath`, et
 * `LocalFileStorageProvider.resolvePath`).
 *
 * Pourquoi ne pas importer directement le module de l'API : le Storage Agent ne
 * doit dépendre ni de Drizzle, ni de better-sqlite3, ni de la configuration de
 * l'API. Un import direct traînerait tout le graphe du backend dans un service
 * qui doit rester minimal et auditable ligne à ligne. Un package partagé serait
 * la solution « propre » mais introduirait un troisième workspace TypeScript
 * pour ~80 lignes de logique pure et figée.
 *
 * Contrepartie assumée : `path-safety.test.ts` rejoue le MÊME jeu de cas que
 * `audio-storage.test.ts`. Toute divergence de comportement entre les deux
 * implémentations est donc un test rouge, pas une dérive silencieuse.
 */
import { resolve, sep } from 'node:path';
import { StorageAgentError } from './errors.js';

/** Lettre de lecteur Windows : `C:`, `F:\`, `c:/`. */
const WINDOWS_DRIVE = /^[A-Za-z]:/;

export class PathSafetyError extends Error {
  constructor(
    readonly reason:
      | 'EMPTY'
      | 'ABSOLUTE'
      | 'WINDOWS_ABSOLUTE'
      | 'UNC'
      | 'TRAVERSAL'
      | 'NO_SEGMENT'
      | 'NOT_A_STRING'
      | 'ESCAPES_ROOT',
    message: string,
  ) {
    super(message);
    this.name = 'PathSafetyError';
  }
}

/**
 * Convertit un chemin d'index en chemin relatif portable, ou lève.
 *
 * Fonction pure, aucun accès disque. Rejets (aucune « réparation » silencieuse) :
 * chemin vide, absolu Unix, absolu Windows, UNC, segment `..`.
 */
export function toPortableRelativePath(storedPath: unknown): string {
  if (typeof storedPath !== 'string') {
    throw new PathSafetyError('NOT_A_STRING', 'Le chemin doit être une chaîne.');
  }

  const unified = storedPath.replace(/\\/g, '/');

  if (unified.trim().length === 0) {
    throw new PathSafetyError('EMPTY', 'Le chemin est vide.');
  }

  // `//serveur/partage` (UNC converti) et `/absolu` sont refusés ensemble : un
  // chemin commençant par un séparateur n'est jamais relatif.
  if (unified.startsWith('//')) {
    throw new PathSafetyError('UNC', 'Un chemin UNC ne peut pas être relatif.');
  }
  if (unified.startsWith('/')) {
    throw new PathSafetyError('ABSOLUTE', 'Un chemin absolu ne peut pas être relatif.');
  }
  if (WINDOWS_DRIVE.test(unified)) {
    throw new PathSafetyError(
      'WINDOWS_ABSOLUTE',
      'Un chemin absolu Windows ne peut pas être relatif.',
    );
  }

  const segments: string[] = [];
  for (const segment of unified.split('/')) {
    if (segment === '' || segment === '.') continue;
    if (segment === '..') {
      throw new PathSafetyError(
        'TRAVERSAL',
        'Le chemin contient une remontée de répertoire interdite.',
      );
    }
    segments.push(segment);
  }

  if (segments.length === 0) {
    throw new PathSafetyError('NO_SEGMENT', 'Le chemin ne contient aucun segment exploitable.');
  }

  return segments.join('/');
}

/**
 * Résout un chemin portable sous une racine, en garantissant le confinement.
 *
 * Seconde barrière après `toPortableRelativePath` : la comparaison se fait avec
 * le séparateur SYSTÈME (`root + sep`), ce qui interdit qu'un dossier voisin
 * dont le nom commence par la racine (`…\music-public`) passe pour un enfant de
 * `…\music`.
 */
export function resolveWithinRoot(root: string, portableRelativePath: string): string {
  const resolvedRoot = resolve(root);
  const candidate = resolve(resolvedRoot, portableRelativePath);

  if (candidate === resolvedRoot) {
    throw new PathSafetyError('ESCAPES_ROOT', 'La référence désigne la racine, pas un fichier.');
  }
  if (!candidate.startsWith(resolvedRoot + sep)) {
    throw new PathSafetyError('ESCAPES_ROOT', 'La référence sort de la racine de stockage.');
  }
  return candidate;
}

/** Traduit une erreur de chemin en erreur typée agent (index invalide). */
export function asIndexInvalidError(error: unknown): StorageAgentError {
  const reason = error instanceof PathSafetyError ? error.reason : 'UNKNOWN';
  return new StorageAgentError('INDEX_INVALID', `chemin refusé (${reason})`);
}
