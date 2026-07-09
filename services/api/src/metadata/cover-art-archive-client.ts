import { mkdir, rename, rm, stat, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';

const MUSICBRAINZ_UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/iu;

export interface CoverArtArchiveClientOptions {
  baseUrl?: string;
  timeoutMs?: number;
  fetchImpl?: typeof fetch;
}

export interface DownloadedCoverArt {
  releaseGroupId: string;
  relativePath: string;
  absolutePath: string;
  sizeBytes: number;
  downloaded: boolean;
}

export class CoverArtArchiveNotFoundError extends Error {
  constructor(releaseGroupId: string) {
    super(`Aucune pochette front 1200 trouvée pour le release group ${releaseGroupId}`);
  }
}

export class CoverArtArchiveHttpError extends Error {
  constructor(
    public statusCode: number,
    message: string,
  ) {
    super(message);
  }
}

function normalizeBaseUrl(baseUrl: string): string {
  return baseUrl.replace(/\/+$/u, '');
}

function assertReleaseGroupId(releaseGroupId: string): void {
  if (!MUSICBRAINZ_UUID_RE.test(releaseGroupId)) {
    throw new Error(`release_group_id MusicBrainz invalide : ${releaseGroupId}`);
  }
}

function relativeCoverPath(releaseGroupId: string): string {
  assertReleaseGroupId(releaseGroupId);
  return `${releaseGroupId.toLowerCase()}.jpg`;
}

export function coverArtPath(coversDir: string, releaseGroupId: string): string {
  return join(coversDir, relativeCoverPath(releaseGroupId));
}

export async function coverArtExists(coversDir: string, releaseGroupId: string): Promise<boolean> {
  return stat(coverArtPath(coversDir, releaseGroupId)).then(() => true, () => false);
}

export class CoverArtArchiveClient {
  private readonly baseUrl: string;
  private readonly timeoutMs: number;
  private readonly fetchImpl: typeof fetch;

  constructor(options: CoverArtArchiveClientOptions = {}) {
    this.baseUrl = normalizeBaseUrl(options.baseUrl ?? 'https://coverartarchive.org');
    this.timeoutMs = options.timeoutMs ?? 15_000;
    this.fetchImpl = options.fetchImpl ?? fetch;
  }

  async fetchReleaseGroupFront1200(releaseGroupId: string): Promise<Buffer> {
    assertReleaseGroupId(releaseGroupId);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), this.timeoutMs);
    try {
      const response = await this.fetchImpl(
        `${this.baseUrl}/release-group/${releaseGroupId}/front-1200`,
        {
          headers: { accept: 'image/jpeg,image/*;q=0.8' },
          redirect: 'follow',
          signal: controller.signal,
        },
      );
      if (response.status === 404) {
        throw new CoverArtArchiveNotFoundError(releaseGroupId);
      }
      if (!response.ok) {
        const body = await response.text().catch(() => '');
        const message = body.trim().slice(0, 300) || response.statusText || 'Cover Art Archive request failed';
        throw new CoverArtArchiveHttpError(response.status, message);
      }
      const contentType = response.headers.get('content-type') ?? '';
      if (!contentType.toLowerCase().startsWith('image/')) {
        throw new CoverArtArchiveHttpError(502, `Réponse Cover Art Archive non-image : ${contentType || 'inconnue'}`);
      }
      return Buffer.from(await response.arrayBuffer());
    } finally {
      clearTimeout(timeout);
    }
  }
}

export async function downloadReleaseGroupCoverArt(
  client: CoverArtArchiveClient,
  coversDir: string,
  releaseGroupId: string,
): Promise<DownloadedCoverArt> {
  const relativePath = relativeCoverPath(releaseGroupId);
  const absolutePath = join(coversDir, relativePath);
  const existing = await stat(absolutePath).then((info) => info, () => null);
  if (existing) {
    return {
      releaseGroupId,
      relativePath,
      absolutePath,
      sizeBytes: existing.size,
      downloaded: false,
    };
  }

  const image = await client.fetchReleaseGroupFront1200(releaseGroupId);
  await mkdir(dirname(absolutePath), { recursive: true });
  const tmpPath = `${absolutePath}.${process.pid}.${Date.now()}.tmp`;
  try {
    await writeFile(tmpPath, image);
    await rename(tmpPath, absolutePath);
  } catch (error) {
    await rm(tmpPath, { force: true });
    throw error;
  }
  return {
    releaseGroupId,
    relativePath,
    absolutePath,
    sizeBytes: image.byteLength,
    downloaded: true,
  };
}
