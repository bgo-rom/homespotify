import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { afterEach, describe, expect, it } from 'vitest';
import { eq, sql } from 'drizzle-orm';
import { createDb, type DbHandle } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import {
  auditLogs,
  importJobs,
  musicRequestItems,
  tracks,
  users,
  userImportDirectories,
  userTracks,
} from '../db/schema.js';
import { makeFlac } from '../test/flac.js';
import { makeWav } from '../test/wav.js';
import { UserImportService } from './user-import-service.js';
import {
  assignMusicRequestItemTrack,
  createMusicRequest,
  MusicRequestError,
  ownerUpdateMusicRequest,
  ownerUpdateMusicRequestItem,
  reconcileMusicRequestStatus,
} from '../discovery/music-request-service.js';

const roots: string[] = [];

function setup(options: { stableChecks?: number; maxStableChecks?: number } = {}) {
  const root = mkdtempSync(join(tmpdir(), 'homespotify-user-import-'));
  roots.push(root);
  const handle = createDb(':memory:');
  runMigrations(handle);
  const importRoot = join(root, 'imports');
  const musicDir = join(root, 'music');
  const coversDir = join(root, 'covers');
  mkdirSync(coversDir, { recursive: true });
  const service = new UserImportService(handle, {
    importRoot,
    musicDir,
    coversDir,
    stableIntervalMs: 1,
    stableChecks: options.stableChecks ?? 1,
    maxStableChecks: options.maxStableChecks ?? 5,
  });
  return { root, handle, service, importRoot, musicDir, coversDir };
}

function insertUser(handle: DbHandle, username: string, role = 'USER'): number {
  const now = new Date().toISOString();
  return handle.db.insert(users).values({
    username,
    displayName: username,
    passwordHash: 'test-only',
    role,
    isActive: true,
    mustChangePassword: false,
    createdAt: now,
    updatedAt: now,
  }).returning({ id: users.id }).get().id;
}

function insertTrack(
  handle: DbHandle,
  input: { hash: string; title: string; artist: string; durationSeconds?: number },
): number {
  return handle.db.insert(tracks).values({
    hash: input.hash,
    path: `${input.hash}.wav`,
    originalExtension: '.wav',
    mimeType: 'audio/wav',
    sizeBytes: 100,
    durationSeconds: input.durationSeconds ?? 0.08,
    title: input.title,
    artist: input.artist,
    album: 'Album',
    createdAt: new Date().toISOString(),
  }).returning({ id: tracks.id }).get().id;
}

afterEach(() => {
  for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true });
});

describe('imports locaux isolés par utilisateur', () => {
  it('crée les dossiers manquants une fois et conserve le nom après changement de username', async () => {
    const { handle, service } = setup();
    const userId = insertUser(handle, 'alice');
    const first = await service.ensureUserDirectory(userId, 'alice');
    expect(existsSync(first.inbox)).toBe(true);
    expect(existsSync(first.rejected)).toBe(true);
    expect(existsSync(first.processed)).toBe(true);
    handle.db.update(users).set({ username: 'alice2' }).where(eq(users.id, userId)).run();
    const second = await service.ensureUserDirectory(userId, 'alice2');
    expect(second.directoryName).toBe(`${userId}_alice`);
    expect(handle.db.select().from(userImportDirectories).all()).toHaveLength(1);
    handle.sqlite.close();
  });

  it('importe WAV et FLAC, puis réutilise un hash exact pour le second compte', async () => {
    const { handle, service } = setup();
    const alice = insertUser(handle, 'alice');
    const bob = insertUser(handle, 'bob');
    const alicePaths = await service.ensureUserDirectory(alice, 'alice');
    const bobPaths = await service.ensureUserDirectory(bob, 'bob');
    const wav = makeWav({ title: 'Unique', artist: 'Artist', seconds: 0.08 });
    const aliceWav = join(alicePaths.inbox, 'unique.wav');
    writeFileSync(aliceWav, wav);
    await service.processInboxFile(alice, aliceWav);

    const bobWav = join(bobPaths.inbox, 'same.wav');
    writeFileSync(bobWav, wav);
    await service.processInboxFile(bob, bobWav);
    const flacPath = join(alicePaths.inbox, 'sample.flac');
    writeFileSync(flacPath, makeFlac({ seconds: 0.2 }));
    await service.processInboxFile(alice, flacPath);

    expect(handle.db.select({ n: sql<number>`count(*)` }).from(tracks).get()?.n).toBe(2);
    expect(handle.db.select().from(userTracks).all()).toHaveLength(3);
    const bobJob = handle.db.select().from(importJobs).where(eq(importJobs.userId, bob)).get();
    expect(bobJob?.status).toBe('REUSED');
    expect(handle.db.select().from(auditLogs).all().map((row) => row.action))
      .toContain('import.track_reused');
    handle.sqlite.close();
  });

  it('importe une seule fois les tags Vorbis et la cover frontale d’un FLAC', async () => {
    const { handle, service, coversDir } = setup();
    const userId = insertUser(handle, 'tagged');
    const paths = await service.ensureUserDirectory(userId, 'tagged');
    const jpeg = Buffer.from([
      0xff, 0xd8,
      0xff, 0xc0, 0x00, 0x0b, 0x08, 0x00, 0x02, 0x00, 0x02,
      0x01, 0x01, 0x11, 0x00,
      0xff, 0xd9,
    ]);
    const file = join(paths.inbox, 'fallback.flac');
    writeFileSync(file, makeFlac({
      seconds: 0.2,
      tags: {
        title: 'Titre balisé',
        artist: 'Artiste balisé',
        album: 'Album balisé',
        albumartist: 'Artiste album',
        tracknumber: '3/12',
        discnumber: '2/2',
        date: '2025-04-03',
        isrc: 'FRABC2500001',
        genre: 'Electro',
      },
      picture: { data: jpeg, width: 2, height: 2 },
    }));

    const [firstJobId, secondJobId] = await Promise.all([
      service.processInboxFile(userId, file),
      service.processInboxFile(userId, file),
    ]);
    expect(secondJobId).toBe(firstJobId);
    const row = handle.db.select().from(tracks).get();
    expect(row).toMatchObject({
      title: 'Titre balisé',
      artist: 'Artiste balisé',
      album: 'Album balisé',
      year: 2025,
      genre: 'Electro',
      isrc: 'FRABC2500001',
    });
    expect(row?.coverPath).toMatch(/\.jpg$/);
    expect(readFileSync(join(coversDir, row!.coverPath!))).toEqual(jpeg);
    const job = handle.db.select().from(importJobs).where(eq(importJobs.id, firstJobId)).get();
    expect(JSON.parse(job?.metadataJson ?? '{}')).toMatchObject({
      albumArtist: 'Artiste album',
      trackPosition: 3,
      trackTotal: 12,
      discNumber: 2,
      discTotal: 2,
      date: '2025-04-03',
      cover: { mimeType: 'image/jpeg', width: 2, height: 2 },
    });
    expect(handle.db.select().from(tracks).all()).toHaveLength(1);
    handle.sqlite.close();
  });

  it('attend un fichier instable et ne crée aucune piste', async () => {
    const { handle, service } = setup({ stableChecks: 3, maxStableChecks: 2 });
    const userId = insertUser(handle, 'unstable');
    const paths = await service.ensureUserDirectory(userId, 'unstable');
    const file = join(paths.inbox, 'writing.wav');
    writeFileSync(file, makeWav());
    const jobId = await service.processInboxFile(userId, file);
    const job = handle.db.select().from(importJobs).where(eq(importJobs.id, jobId)).get();
    expect(job?.status).toBe('FAILED');
    expect(job?.errorMessage).toMatch(/cours d'écriture/);
    expect(handle.db.select().from(tracks).all()).toHaveLength(0);
    handle.sqlite.close();
  });

  it('laisse une correspondance titre/artiste ambiguë au OWNER', async () => {
    const { handle, service } = setup();
    const userId = insertUser(handle, 'ambiguous');
    insertTrack(handle, { hash: 'a'.repeat(64), title: 'Same', artist: 'Artist' });
    insertTrack(handle, { hash: 'b'.repeat(64), title: 'Same', artist: 'Artist' });
    const paths = await service.ensureUserDirectory(userId, 'ambiguous');
    const file = join(paths.inbox, 'same.wav');
    writeFileSync(file, makeWav({ title: 'Same', artist: 'Artist', seconds: 0.08 }));
    const jobId = await service.processInboxFile(userId, file);
    const job = handle.db.select().from(importJobs).where(eq(importJobs.id, jobId)).get();
    expect(job?.status).toBe('WAITING_FOR_OWNER_MATCH');
    expect(JSON.parse(job?.matchCandidatesJson ?? '[]')).toHaveLength(2);
    expect(handle.db.select().from(userTracks).all()).toHaveLength(0);
    handle.sqlite.close();
  });
});

describe('demandes TRACK, ALBUM et PLAYLIST', () => {
  it('conserve le snapshot ordonné et calcule PARTIALLY_COMPLETED puis COMPLETED', () => {
    const { handle } = setup();
    const ownerId = insertUser(handle, 'owner', 'OWNER');
    const userId = insertUser(handle, 'listener');
    const trackRequest = createMusicRequest(handle, {
      userId,
      requestType: 'TRACK',
      title: 'Single',
      artist: 'Artist',
    });
    const albumRequest = createMusicRequest(handle, {
      userId,
      requestType: 'ALBUM',
      title: 'Album',
      artist: 'Artist',
      items: [{ title: 'A' }, { title: 'B' }],
    });
    const playlist = createMusicRequest(handle, {
      userId,
      requestType: 'PLAYLIST',
      title: 'Playlist',
      externalUrl: 'https://example.com/list',
      items: [{ title: 'First' }, { title: 'Second' }],
    });
    expect(trackRequest.requestType).toBe('TRACK');
    expect(albumRequest.requestType).toBe('ALBUM');
    expect(playlist.items.map((item) => item.title)).toEqual(['First', 'Second']);

    const firstTrack = insertTrack(handle, {
      hash: 'c'.repeat(64),
      title: 'First',
      artist: 'Artist',
    });
    const secondTrack = insertTrack(handle, {
      hash: 'd'.repeat(64),
      title: 'Second',
      artist: 'Artist',
    });
    assignMusicRequestItemTrack(handle, {
      ownerId,
      requestId: playlist.id,
      itemId: playlist.items[0]!.id,
      trackId: firstTrack,
    });
    ownerUpdateMusicRequestItem(handle, {
      ownerId,
      itemId: playlist.items[1]!.id,
      status: 'UNAVAILABLE',
    });
    expect(reconcileMusicRequestStatus(handle, playlist.id).status).toBe('PARTIALLY_COMPLETED');
    assignMusicRequestItemTrack(handle, {
      ownerId,
      requestId: playlist.id,
      itemId: playlist.items[1]!.id,
      trackId: secondTrack,
    });
    expect(reconcileMusicRequestStatus(handle, playlist.id).status).toBe('COMPLETED');
    expect(handle.db.select().from(userTracks).where(eq(userTracks.userId, userId)).all())
      .toHaveLength(2);

    expect(() => ownerUpdateMusicRequest(handle, {
      ownerId,
      requestId: albumRequest.id,
      status: 'COMPLETED',
    })).toThrowError(MusicRequestError);
    expect(handle.db.select().from(musicRequestItems).where(
      eq(musicRequestItems.musicRequestId, playlist.id),
    ).all()).toHaveLength(2);
    handle.sqlite.close();
  });
});
