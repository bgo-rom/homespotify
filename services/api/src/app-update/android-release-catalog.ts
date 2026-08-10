import { readFile, stat } from 'node:fs/promises';
import { isAbsolute, join, resolve, sep } from 'node:path';

/**
 * Catalogue des releases Android publiées (auto-update privé).
 *
 * Le catalogue est un simple arborescence de fichiers — aucune table SQL, rien
 * à migrer, rollback trivial :
 *
 *   <racine>/
 *   ├── releases/homespotify-<versionCode>.apk
 *   ├── metadata/<versionCode>.json
 *   └── latest.json          (copie du metadata de la version publiée)
 *
 * INVARIANT DE SÉCURITÉ : aucun chemin ne vient jamais du client. Le seul
 * paramètre accepté est un ENTIER `versionCode` ; le nom de fichier est
 * RECONSTRUIT côté serveur à partir de cet entier. Il n'existe donc pas de
 * surface de traversée de chemin, et aucune extension autre que `.apk` n'est
 * atteignable.
 */

/** Nom de fichier canonique d'une release. Jamais lu depuis le client. */
const APK_FILE_PATTERN = /^homespotify-(\d+)\.apk$/u;

const SHA256_PATTERN = /^[0-9a-f]{64}$/u;

/** Un versionCode Android est un entier positif borné (int32 signé). */
const MAX_VERSION_CODE = 2_100_000_000;

export interface AndroidReleaseManifest {
  platform: 'android';
  packageName: string;
  versionCode: number;
  versionName: string;
  /** `true` : le client ne propose pas « Plus tard ». */
  required: boolean;
  /** Toute version strictement inférieure est considérée obsolète. */
  minSupportedVersionCode: number;
  sizeBytes: number;
  sha256: string;
  /**
   * Empreinte SHA-256 du certificat de signature attendu. Publiée pour que le
   * client puisse refuser une APK qui n'a pas l'identité de signature de
   * HomeSpotify — Android refuserait de toute façon l'installation.
   */
  signingCertSha256: string;
  releaseNotes: string[];
  publishedAt: string;
}

export class AndroidReleaseManifestError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AndroidReleaseManifestError';
  }
}

function requireString(value: unknown, field: string): string {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new AndroidReleaseManifestError(`Champ "${field}" absent ou vide`);
  }
  return value;
}

function requireVersionCode(value: unknown, field: string): number {
  if (
    typeof value !== 'number' ||
    !Number.isInteger(value) ||
    value < 1 ||
    value > MAX_VERSION_CODE
  ) {
    throw new AndroidReleaseManifestError(
      `Champ "${field}" invalide (entier 1..${MAX_VERSION_CODE} attendu)`,
    );
  }
  return value;
}

/**
 * Valide STRICTEMENT un manifeste lu sur disque. Un manifeste douteux n'est
 * jamais « réparé » : il est refusé, et l'appelant décide quoi répondre.
 */
export function parseAndroidReleaseManifest(raw: unknown): AndroidReleaseManifest {
  if (raw === null || typeof raw !== 'object' || Array.isArray(raw)) {
    throw new AndroidReleaseManifestError('Manifeste : objet JSON attendu');
  }
  const record = raw as Record<string, unknown>;

  if (record.platform !== 'android') {
    throw new AndroidReleaseManifestError('Champ "platform" doit valoir "android"');
  }
  const packageName = requireString(record.packageName, 'packageName');
  if (!/^[a-zA-Z][\w]*(\.[a-zA-Z][\w]*)+$/u.test(packageName)) {
    throw new AndroidReleaseManifestError('Champ "packageName" invalide');
  }

  const versionCode = requireVersionCode(record.versionCode, 'versionCode');
  const minSupportedVersionCode = requireVersionCode(
    record.minSupportedVersionCode,
    'minSupportedVersionCode',
  );
  if (minSupportedVersionCode > versionCode) {
    throw new AndroidReleaseManifestError(
      'Champ "minSupportedVersionCode" ne peut pas dépasser "versionCode"',
    );
  }

  const versionName = requireString(record.versionName, 'versionName');

  if (typeof record.required !== 'boolean') {
    throw new AndroidReleaseManifestError('Champ "required" booléen attendu');
  }

  const sizeBytes = record.sizeBytes;
  if (typeof sizeBytes !== 'number' || !Number.isInteger(sizeBytes) || sizeBytes <= 0) {
    throw new AndroidReleaseManifestError('Champ "sizeBytes" invalide (entier > 0 attendu)');
  }

  const sha256 = requireString(record.sha256, 'sha256').toLowerCase();
  if (!SHA256_PATTERN.test(sha256)) {
    throw new AndroidReleaseManifestError('Champ "sha256" invalide (64 hexadécimaux attendus)');
  }
  const signingCertSha256 = requireString(
    record.signingCertSha256,
    'signingCertSha256',
  ).toLowerCase();
  if (!SHA256_PATTERN.test(signingCertSha256)) {
    throw new AndroidReleaseManifestError('Champ "signingCertSha256" invalide');
  }

  const rawNotes = record.releaseNotes;
  if (!Array.isArray(rawNotes) || rawNotes.some((note) => typeof note !== 'string')) {
    throw new AndroidReleaseManifestError('Champ "releaseNotes" : tableau de chaînes attendu');
  }

  const publishedAt = requireString(record.publishedAt, 'publishedAt');
  if (Number.isNaN(Date.parse(publishedAt))) {
    throw new AndroidReleaseManifestError('Champ "publishedAt" : date ISO 8601 attendue');
  }

  return {
    platform: 'android',
    packageName,
    versionCode,
    versionName,
    required: record.required,
    minSupportedVersionCode,
    sizeBytes,
    sha256,
    signingCertSha256,
    releaseNotes: (rawNotes as string[]).map((note) => note.trim()).filter((note) => note.length > 0),
    publishedAt,
  };
}

/** Nom de fichier canonique — construit, jamais reçu. */
export function apkFileName(versionCode: number): string {
  return `homespotify-${versionCode}.apk`;
}

/** Vrai uniquement pour un nom de fichier de release canonique. */
export function isApkFileName(name: string): boolean {
  return APK_FILE_PATTERN.test(name);
}

/**
 * Convertit une valeur de route en versionCode utilisable. Refuse tout ce qui
 * n'est pas exactement un entier décimal : « 11 » passe, « 11.apk »,
 * « ../../etc/passwd », « 0x0b », « +11 » et « 011 » ne passent pas.
 */
export function parseVersionCodeParam(raw: string): number | null {
  if (!/^(0|[1-9][0-9]{0,9})$/u.test(raw)) return null;
  const value = Number(raw);
  if (!Number.isInteger(value) || value < 1 || value > MAX_VERSION_CODE) return null;
  return value;
}

export interface ResolvedAndroidRelease {
  manifest: AndroidReleaseManifest;
  /** Chemin absolu du fichier, jamais renvoyé au client. */
  filePath: string;
  sizeBytes: number;
}

export class AndroidReleaseCatalog {
  private readonly root: string;

  constructor(root: string) {
    this.root = resolve(root);
  }

  private get releasesDir(): string {
    return join(this.root, 'releases');
  }

  private get metadataDir(): string {
    return join(this.root, 'metadata');
  }

  /**
   * Manifeste de la version publiée. `null` si aucune publication n'a encore
   * eu lieu (catalogue vide : ce n'est pas une erreur).
   * Lève [AndroidReleaseManifestError] si `latest.json` existe mais est invalide.
   */
  async readLatest(): Promise<AndroidReleaseManifest | null> {
    const raw = await this.readJsonIfPresent(join(this.root, 'latest.json'));
    if (raw === null) return null;
    return parseAndroidReleaseManifest(raw);
  }

  /**
   * Résout une version DEMANDÉE par le client. `null` si cette version n'est
   * pas au catalogue : le client ne peut donc atteindre que des releases
   * réellement publiées, jamais un fichier arbitraire.
   */
  async resolve(versionCode: number): Promise<ResolvedAndroidRelease | null> {
    if (!Number.isInteger(versionCode) || versionCode < 1 || versionCode > MAX_VERSION_CODE) {
      return null;
    }
    const raw = await this.readJsonIfPresent(join(this.metadataDir, `${versionCode}.json`));
    if (raw === null) return null;
    const manifest = parseAndroidReleaseManifest(raw);
    if (manifest.versionCode !== versionCode) {
      throw new AndroidReleaseManifestError(
        `Metadata ${versionCode}.json déclare versionCode=${manifest.versionCode}`,
      );
    }

    const filePath = join(this.releasesDir, apkFileName(manifest.versionCode));
    // Ceinture ET bretelles : le chemin est déjà construit, on vérifie quand
    // même qu'il ne sort pas du dossier des releases.
    if (!isAbsolute(filePath) || !filePath.startsWith(this.releasesDir + sep)) {
      return null;
    }
    const stats = await stat(filePath).catch(() => null);
    if (stats === null || !stats.isFile()) return null;

    return { manifest, filePath, sizeBytes: stats.size };
  }

  private async readJsonIfPresent(path: string): Promise<unknown> {
    let text: string;
    try {
      text = await readFile(path, 'utf-8');
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') return null;
      throw error;
    }
    try {
      return JSON.parse(text);
    } catch {
      throw new AndroidReleaseManifestError(`JSON illisible : ${path}`);
    }
  }
}
