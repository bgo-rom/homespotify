import { createDb } from '../db/client.js';
import { runMigrations } from '../db/migrate.js';
import { loadConfig } from '../config.js';
import {
  CoverArtArchiveClient,
  CoverArtArchiveNotFoundError,
  downloadReleaseGroupCoverArt,
} from '../metadata/cover-art-archive-client.js';
import { MusicBrainzClient } from '../metadata/musicbrainz-client.js';
import {
  analyzeTrackWithMusicBrainz,
  enrichTrackWithMusicBrainz,
  type EnrichmentAnalysis,
  type TrackForEnrichment,
} from '../metadata/musicbrainz-enrichment.js';

interface CliOptions {
  limit: number;
  trackId: number | null;
  dryRun: boolean;
  force: boolean;
  minScore: number;
  userAgent: string | null;
}

const DEFAULT_USER_AGENT = 'HomeSpotify/0.1.0 (personal local library; set MUSICBRAINZ_USER_AGENT for contact)';

function usage(): string {
  return [
    'Usage: pnpm --filter @homespotify/api enrich:musicbrainz -- [options]',
    '',
    'Options:',
    '  --limit <n>       Nombre maximal de pistes à traiter (défaut: 50)',
    '  --track-id <id>   Traite une piste précise',
    '  --dry-run         Interroge MusicBrainz sans écrire en base',
    '  --force           Retraite les pistes déjà enrichies',
    '  --min-score <n>   Seuil de match automatique 0-100 (défaut: 82)',
    '  --user-agent <ua> User-Agent MusicBrainz explicite',
    '  --help            Affiche cette aide',
  ].join('\n');
}

function readNumber(name: string, raw: string | undefined): number {
  const value = Number(raw);
  if (!Number.isFinite(value)) throw new Error(`${name} invalide : ${raw ?? '<vide>'}`);
  return value;
}

function parseArgs(argv: string[]): CliOptions {
  const options: CliOptions = {
    limit: 50,
    trackId: null,
    dryRun: false,
    force: false,
    minScore: 82,
    userAgent: null,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case '--help':
      case '-h':
        console.log(usage());
        process.exit(0);
      case '--dry-run':
        options.dryRun = true;
        break;
      case '--force':
        options.force = true;
        break;
      case '--limit':
        options.limit = Math.max(1, Math.floor(readNumber('--limit', argv[++i])));
        break;
      case '--track-id':
        options.trackId = Math.max(1, Math.floor(readNumber('--track-id', argv[++i])));
        break;
      case '--min-score':
        options.minScore = Math.max(0, Math.min(100, readNumber('--min-score', argv[++i])));
        break;
      case '--user-agent':
        options.userAgent = argv[++i] ?? null;
        break;
      default:
        throw new Error(`Option inconnue : ${arg}\n\n${usage()}`);
    }
  }

  return options;
}

function selectTracks(sqlite: import('better-sqlite3').Database, options: CliOptions): TrackForEnrichment[] {
  const rows = sqlite.prepare(`
    SELECT
      t.id,
      t.title,
      t.artist,
      t.album,
      t.duration_seconds AS durationSeconds,
      t.year,
      t.genre
    FROM tracks t
    LEFT JOIN track_enrichment e ON e.track_id = t.id
    WHERE (:trackId IS NULL OR t.id = :trackId)
      AND (:force = 1 OR e.track_id IS NULL)
    ORDER BY t.id ASC
    LIMIT :limit
  `).all({
    trackId: options.trackId,
    force: options.force ? 1 : 0,
    limit: options.trackId ? 1 : options.limit,
  }) as TrackForEnrichment[];
  return rows;
}

function formatAnalysis(analysis: EnrichmentAnalysis): string {
  const score = analysis.matchScore === null ? '-' : analysis.matchScore.toFixed(1);
  const match = analysis.matched
    ? `${analysis.matched.canonicalArtist ?? 'Artiste inconnu'} - ${analysis.matched.canonicalTitle}`
    : analysis.errorMessage ?? 'aucune correspondance sûre';
  return `#${analysis.trackId} ${analysis.status} score=${score} ${match}`;
}

async function main(): Promise<void> {
  const options = parseArgs(process.argv.slice(2));
  const config = loadConfig();
  const handle = createDb(config.dbPath);
  const userAgent = options.userAgent ?? process.env.MUSICBRAINZ_USER_AGENT ?? DEFAULT_USER_AGENT;

  try {
    runMigrations(handle);
    const tracks = selectTracks(handle.sqlite, options);
    if (tracks.length === 0) {
      console.log(options.trackId
        ? `Aucune piste à enrichir pour id=${options.trackId} (déjà traitée ? utiliser --force)`
        : 'Aucune piste à enrichir');
      return;
    }

    const client = new MusicBrainzClient({ userAgent });
    const coverClient = new CoverArtArchiveClient();
    const summary = { matched: 0, ambiguous: 0, not_found: 0, failed: 0 };
    const coverSummary = { downloaded: 0, cached: 0, not_found: 0, failed: 0 };

    for (const track of tracks) {
      const label = `${track.artist} - ${track.title}`;
      console.log(`MusicBrainz: ${track.id} ${label}`);
      const analysis = options.dryRun
        ? await analyzeTrackWithMusicBrainz(client, track, { minScore: options.minScore })
        : await enrichTrackWithMusicBrainz(handle.db, client, track, { minScore: options.minScore });
      if (analysis.status in summary) summary[analysis.status as keyof typeof summary] += 1;
      console.log(formatAnalysis(analysis));

      const releaseGroupId = analysis.matched?.musicbrainzReleaseGroupId;
      if (!options.dryRun && releaseGroupId) {
        try {
          const cover = await downloadReleaseGroupCoverArt(coverClient, config.coversDir, releaseGroupId);
          if (cover.downloaded) {
            coverSummary.downloaded += 1;
            console.log(`Cover Art Archive: téléchargé ${cover.relativePath} (${cover.sizeBytes} octets)`);
          } else {
            coverSummary.cached += 1;
            console.log(`Cover Art Archive: déjà présent ${cover.relativePath}`);
          }
        } catch (error) {
          if (error instanceof CoverArtArchiveNotFoundError) {
            coverSummary.not_found += 1;
            console.log(`Cover Art Archive: aucune pochette HD pour ${releaseGroupId}`);
          } else {
            coverSummary.failed += 1;
            const message = error instanceof Error ? error.message : String(error);
            console.log(`Cover Art Archive: échec ${releaseGroupId} — ${message}`);
          }
        }
      }
    }

    console.log([
      `Terminé${options.dryRun ? ' (dry-run, aucune écriture)' : ''}.`,
      `matched=${summary.matched}`,
      `ambiguous=${summary.ambiguous}`,
      `not_found=${summary.not_found}`,
      `failed=${summary.failed}`,
    ].join(' '));
    if (!options.dryRun) {
      console.log([
        'Pochettes.',
        `downloaded=${coverSummary.downloaded}`,
        `cached=${coverSummary.cached}`,
        `not_found=${coverSummary.not_found}`,
        `failed=${coverSummary.failed}`,
      ].join(' '));
    }
  } finally {
    handle.sqlite.close();
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
