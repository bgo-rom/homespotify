import { mkdtempSync, rmSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  CoverArtArchiveClient,
  CoverArtArchiveNotFoundError,
  downloadReleaseGroupCoverArt,
} from './cover-art-archive-client.js';

const releaseGroupId = '48140466-cff6-3222-bd55-63c27e43190d';
const jpg = Buffer.from([0xff, 0xd8, 0xff, 0xdb, 0x00, 0x43]);

let base: string;

beforeEach(() => {
  base = mkdtempSync(join(tmpdir(), 'homespotify-cover-'));
});

afterEach(() => {
  rmSync(base, { recursive: true, force: true });
});

describe('downloadReleaseGroupCoverArt', () => {
  it('télécharge la pochette front 1200 en release_group_id.jpg puis réutilise le cache local', async () => {
    let calls = 0;
    const client = new CoverArtArchiveClient({
      fetchImpl: async (url) => {
        calls += 1;
        expect(String(url)).toContain(`/release-group/${releaseGroupId}/front-1200`);
        return new Response(jpg, {
          status: 200,
          headers: { 'content-type': 'image/jpeg' },
        });
      },
    });

    const first = await downloadReleaseGroupCoverArt(client, base, releaseGroupId);
    expect(first).toMatchObject({
      relativePath: `${releaseGroupId}.jpg`,
      sizeBytes: jpg.length,
      downloaded: true,
    });
    await expect(readFile(first.absolutePath)).resolves.toEqual(jpg);

    const second = await downloadReleaseGroupCoverArt(client, base, releaseGroupId);
    expect(second.downloaded).toBe(false);
    expect(calls).toBe(1);
  });

  it('remonte un 404 Cover Art Archive comme absence de pochette', async () => {
    const client = new CoverArtArchiveClient({
      fetchImpl: async () => new Response('', { status: 404 }),
    });

    await expect(downloadReleaseGroupCoverArt(client, base, releaseGroupId))
      .rejects
      .toBeInstanceOf(CoverArtArchiveNotFoundError);
  });
});
