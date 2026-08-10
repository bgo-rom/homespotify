import { readdir, stat } from 'node:fs/promises';
import { basename, extname, isAbsolute, join, relative, resolve } from 'node:path';
import { setTimeout as delay } from 'node:timers/promises';
import { analyzeAudioFile, type AudioFileAnalysis } from '../import/import-service.js';

/**
 * Détection et validation des fichiers réellement produits par un job.
 *
 * Le moteur Antra n'expose PAS le chemin final dans ses événements JSON
 * (`emit_event` de `json_cli.py` n'y recopie pas `EngineEvent.file_path`). La
 * détection repose donc sur un contexte strict, jamais sur « le fichier le plus
 * récent » du disque : chaque job écrit dans SON PROPRE dossier de staging,
 * dont l'inventaire est relevé avant le lancement.
 */

/** Suffixes d'écriture en cours : jamais candidats à l'import. */
const TEMPORARY_SUFFIXES = [
  '.part',
  '.tmp',
  '.temp',
  '.download',
  '.crdownload',
  '.enc.m4a',
  '.partial',
  '.ytdl',
] as const;

/** Un extrait promotionnel dure ~30 s : refusé quand la piste est bien plus longue. */
const EXCERPT_MAX_SECONDS = 45;
const EXCERPT_RATIO_THRESHOLD = 0.6;

export interface DetectedFile {
  absolutePath: string;
  sizeBytes: number;
  analysis: AudioFileAnalysis;
}

export interface RejectedFile {
  absolutePath: string;
  reasonCode:
    | 'unstable'
    | 'unreadable'
    | 'format_rejected'
    | 'no_audio_stream'
    | 'excerpt_too_short'
    | 'empty';
  reason: string;
}

export interface DetectionOutcome {
  accepted: DetectedFile[];
  rejected: RejectedFile[];
}

export interface DetectionOptions {
  /** Extensions acceptées, minuscules avec le point (`.flac`). */
  allowedExtensions: readonly string[];
  /** Chemins déjà présents AVANT le job : jamais réimportés. */
  knownPaths?: ReadonlySet<string>;
  /** Durée attendue de la piste, quand le moteur l'a annoncée. */
  expectedDurationSeconds?: number | null;
  /** Attente de stabilité de taille (injectable pour les tests). */
  stabilityIntervalMs?: number;
  stabilityChecks?: number;
  maxStabilityChecks?: number;
}

function isTemporary(filename: string): boolean {
  const lower = filename.toLowerCase();
  return TEMPORARY_SUFFIXES.some((suffix) => lower.endsWith(suffix));
}

/**
 * Clé de comparaison d'un chemin. Windows est insensible à la casse : comparer
 * les chemins bruts ferait passer pour « nouveau » un fichier déjà connu dont
 * seule la casse diffère.
 */
export function pathKey(path: string): string {
  return resolve(path).toLowerCase();
}

/**
 * Inventaire léger d'un dossier : uniquement les chemins absolus des fichiers.
 * Sert de point de comparaison avant/après, sans lire le moindre octet.
 */
export async function snapshotDirectory(root: string): Promise<string[]> {
  const found: string[] = [];
  const pending = [resolve(root)];
  while (pending.length > 0) {
    const directory = pending.pop()!;
    let entries;
    try {
      entries = await readdir(directory, { withFileTypes: true });
    } catch {
      // Dossier absent au premier lancement : inventaire vide, pas une erreur.
      continue;
    }
    for (const entry of entries) {
      const candidate = join(directory, entry.name);
      if (entry.isDirectory()) pending.push(candidate);
      else if (entry.isFile()) found.push(candidate);
    }
  }
  return found;
}

/** Inventaire prêt à servir de référence « avant job ». */
export async function snapshotDirectoryKeys(root: string): Promise<Set<string>> {
  return new Set((await snapshotDirectory(root)).map(pathKey));
}

/**
 * Attend que la taille ET la date de modification cessent de bouger.
 *
 * Un fichier encore en écriture passerait l'analyse avec une durée tronquée :
 * on préfère attendre, puis échouer explicitement.
 */
async function waitForStableFile(
  path: string,
  options: DetectionOptions,
): Promise<{ size: number } | null> {
  // 200 ms et non 500 : la détection ne démarre qu'APRÈS la sortie du
  // processus Antra, donc plus aucun écrivain n'existe. Deux échantillons
  // identiques restent exigés — c'est la garde qui compte, pas sa lenteur.
  // Mesuré en production : 1 010 ms d'attente pure par job avant ce réglage.
  const interval = options.stabilityIntervalMs ?? 200;
  const required = options.stabilityChecks ?? 2;
  const maxChecks = options.maxStabilityChecks ?? 40;

  let previous: { size: number; mtimeMs: number } | null = null;
  let stable = 0;
  for (let attempt = 0; attempt < maxChecks; attempt += 1) {
    let current;
    try {
      current = await stat(path);
    } catch {
      return null;
    }
    if (!current.isFile()) return null;
    const snapshot = { size: current.size, mtimeMs: current.mtimeMs };
    if (
      previous !== null &&
      snapshot.size === previous.size &&
      snapshot.mtimeMs === previous.mtimeMs
    ) {
      stable += 1;
      if (stable >= required) return { size: snapshot.size };
    } else {
      stable = 0;
    }
    previous = snapshot;
    await delay(interval);
  }
  return null;
}

/**
 * Retourne les fichiers audio NOUVEAUX et valides du dossier de staging.
 *
 * Aucun fichier existant n'est jamais supprimé ni modifié : la fonction se
 * contente de lire.
 */
export async function detectDownloadedFiles(
  stagingDir: string,
  options: DetectionOptions,
): Promise<DetectionOutcome> {
  const accepted: DetectedFile[] = [];
  const rejected: RejectedFile[] = [];
  const known = options.knownPaths ?? new Set<string>();
  const allowed = new Set(options.allowedExtensions.map((value) => value.toLowerCase()));

  const candidates = (await snapshotDirectory(stagingDir))
    .filter((path) => !known.has(pathKey(path)))
    .filter((path) => !isTemporary(basename(path)))
    .filter((path) => allowed.has(extname(path).toLowerCase()))
    .sort();

  for (const path of candidates) {
    const stable = await waitForStableFile(path, options);
    if (stable === null) {
      rejected.push({
        absolutePath: path,
        reasonCode: 'unstable',
        reason: 'Le fichier était encore en cours d’écriture.',
      });
      continue;
    }
    if (stable.size === 0) {
      rejected.push({
        absolutePath: path,
        reasonCode: 'empty',
        reason: 'Fichier vide.',
      });
      continue;
    }

    let analysis: AudioFileAnalysis;
    try {
      analysis = await analyzeAudioFile(path);
    } catch (error) {
      const message =
        error instanceof Error ? error.message.slice(0, 200) : 'Fichier audio illisible.';
      // Un fichier PARFAITEMENT lisible mais hors specs d'ingestion (FLAC 32
      // bits, WAV non conforme…) n'est pas « illisible » : confondre les deux
      // rend le diagnostic faux et fait chercher un problème inexistant.
      const formatRejected = /Specs|Format refusé/i.test(message);
      rejected.push({
        absolutePath: path,
        reasonCode: formatRejected ? 'format_rejected' : 'unreadable',
        reason: message,
      });
      continue;
    }

    if (analysis.durationSeconds === null || analysis.durationSeconds <= 0) {
      rejected.push({
        absolutePath: path,
        reasonCode: 'no_audio_stream',
        reason: 'Aucune piste audio exploitable dans le fichier.',
      });
      continue;
    }

    const expected = options.expectedDurationSeconds ?? null;
    if (
      expected !== null &&
      expected > 0 &&
      analysis.durationSeconds <= EXCERPT_MAX_SECONDS &&
      analysis.durationSeconds < expected * EXCERPT_RATIO_THRESHOLD
    ) {
      rejected.push({
        absolutePath: path,
        reasonCode: 'excerpt_too_short',
        reason: 'Le fichier reçu est un extrait, pas la piste complète.',
      });
      continue;
    }

    accepted.push({ absolutePath: path, sizeBytes: stable.size, analysis });
  }

  return { accepted, rejected };
}

/**
 * Chemins temporaires supprimables après annulation. Un fichier audio complet
 * n'y figure JAMAIS : une annulation ne détruit pas un enregistrement valide.
 */
export async function listTemporaryArtifacts(stagingDir: string): Promise<string[]> {
  return (await snapshotDirectory(stagingDir)).filter((path) =>
    isTemporary(basename(path)),
  );
}

/** Garde-fou de confinement : refuse tout chemin hors de la racine autorisée. */
export function isConfined(root: string, candidate: string): boolean {
  const rel = relative(resolve(root), resolve(candidate));
  return rel === '' || (!rel.startsWith('..') && !isAbsolute(rel));
}
