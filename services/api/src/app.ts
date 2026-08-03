import { mkdirSync, readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import Fastify, { type FastifyError, type FastifyInstance } from 'fastify';
import multipart from '@fastify/multipart';
import fastifyJwt from '@fastify/jwt';
import { sql } from 'drizzle-orm';
import {
  defaultDiscoveryConfig,
  defaultOfflineConfig,
  type AppConfig,
  type DiscoveryConfig,
} from './config.js';
import { createDb, type DbHandle } from './db/client.js';
import { runMigrations, isDbInitialized, appliedMigrationCount } from './db/migrate.js';
import { tracks } from './db/schema.js';
import { registerTrackRoutes } from './routes/tracks.js';
import { registerPlayerRoute } from './routes/player.js';
import { registerSyncRoutes } from './routes/sync.js';
import { registerAuthRoutes } from './routes/auth.js';
import { registerDiscoveryRoutes } from './routes/discovery.js';
import { registerAdminRoutes } from './routes/admin.js';
import { registerLibraryAdminRoutes } from './routes/library-admin.js';
import { registerFavoritesRoutes } from './routes/favorites.js';
import { registerPlaylistsRoutes } from './routes/playlists.js';
import { registerCatalogRoutes } from './routes/catalog.js';
import { createAuthGuards } from './auth/guards.js';
import {
  backfillOwnerLibrary,
  repairOwnerBackfillLeak,
} from './library/user-library-service.js';
import {
  LastfmMusicSimilarityProvider,
  type MusicSimilarityProvider,
} from './discovery/music-similarity-provider.js';
import { LastfmClient } from './metadata/lastfm-client.js';
import { ItunesCatalogProvider, type CatalogProvider } from './discovery/preview-provider.js';
import {
  AppleMusicCatalogProvider,
  loadAppleKeyPem,
} from './discovery/apple-music-catalog-provider.js';
import {
  invalidateLegacyArtifacts,
  refreshRecommendationQueueForUser,
} from './discovery/recommendation-engine.js';
import { registerPlayEventRoutes } from './routes/play-events.js';
import { registerDiscoveryCatalogRoutes } from './routes/discovery-catalog.js';
import { DiscoveryCache } from './discovery/catalog/discovery-cache.js';
import {
  DiscoveryCatalogService,
  type RegisteredProvider,
} from './discovery/catalog/discovery-catalog-service.js';
import { SpotifyCatalogProvider } from './discovery/catalog/spotify-catalog-provider.js';
import { MusicBrainzCatalogProvider } from './discovery/catalog/musicbrainz-catalog-provider.js';
import { ItunesDiscoveryProvider } from './discovery/catalog/itunes-discovery-provider.js';
import { DeezerDiscoveryProvider } from './discovery/catalog/deezer-discovery-provider.js';
import { AppleMusicDiscoveryProvider } from './discovery/catalog/apple-music-discovery-provider.js';
import { MusicBrainzClient } from './metadata/musicbrainz-client.js';
import {
  MetadataThenFfmpegBpmAnalyzer,
  TrackAudioAnalysisService,
  type TrackBpmAnalyzer,
} from './audio/bpm-analysis.js';
import { registerPlaybackSettingsRoutes } from './routes/playback-settings.js';
import { UserImportService } from './import/user-import-service.js';
import { AcquisitionJobRepository } from './import/acquisition-job-repository.js';
import { ProviderHealthRepository } from './import/provider-health-repository.js';
import {
  AcquisitionImportService,
  type AcquisitionRunner,
} from './import/acquisition-import-service.js';
import { LucidaProcessRunner } from './import/lucida-process-runner.js';
import { registerImportRoutes } from './routes/imports.js';
import {
  registerAcquisitionImportRoutes,
  type LucidaSearchRunner,
} from './routes/acquisition-imports.js';
import { ServerBackupScheduler } from './operations/backup-scheduler.js';
import {
  FfmpegOpusEncoderRunner,
  OfflineVariantService,
  type OpusEncoderRunner,
} from './audio/offline-variant-service.js';
import { registerOfflineRoutes } from './routes/offline.js';
import {
  FfmpegR128Analyzer,
  TrackLoudnessAnalysisService,
  type TrackLoudnessAnalyzer,
} from './audio/loudness-analysis.js';
import { registerLoudnessAnalysisRoutes } from './routes/loudness-analysis.js';
import type { AudioStorageProvider } from './storage/audio-storage.js';
import { LocalFileStorageProvider } from './storage/local-file-storage.js';
import {
  createAudioStorageProvider,
  DEFAULT_AUDIO_STORAGE_MODE,
} from './storage/provider-factory.js';
import { AntraDownloadProvider } from './download/antra-download-provider.js';
import { DownloadJobRepository } from './download/download-job-repository.js';
import {
  DownloadService,
  type DownloadRemoteImportService,
} from './download/download-service.js';
import { RemoteDownloadedFileImporter } from './download/remote-downloaded-file-importer.js';
import { StorageAgentClient } from './storage/remote/storage-agent-client.js';
import type { DownloadProvider } from './download/download-provider.js';
import {
  DiscoveryTrackSearchProvider,
  type TrackSearchProvider,
} from './download/track-search.js';
import { registerDownloadRoutes } from './routes/downloads.js';

const pkg = JSON.parse(
  readFileSync(new URL('../package.json', import.meta.url), 'utf-8'),
) as { name: string; version: string };

export const CURRENT_PHASE = 'Phase 3 — bibliothèque, métadonnées & sync offline';

declare module 'fastify' {
  interface FastifyInstance {
    dbHandle: DbHandle;
    config: AppConfig;
    /** Service des variantes hors ligne (tests : attendre `drain()`). */
    offlineVariants: OfflineVariantService;
    /** Stockage de la bibliothèque (Phase 1 migration VPS : toujours local). */
    audioStorage: AudioStorageProvider;
    /** Stockage des dérivées hors ligne : reste local même après migration. */
    offlineVariantStorage: AudioStorageProvider;
  }
}

export interface BuildAppOptions {
  /** Graphe de similarité (tests). null explicite = non configuré. */
  similarityProvider?: MusicSimilarityProvider | null;
  previewProvider?: CatalogProvider;
  /** Pré-validation d'extrait injectable (tests : évite tout appel réseau HEAD). */
  previewValidator?: (url: string) => Promise<import('./discovery/media-validation.js').PreviewValidationResult>;
  /** Analyse BPM injectable : les tests ne lancent jamais ffmpeg. */
  bpmAnalyzer?: TrackBpmAnalyzer;
  /** Mesure R128 injectable : les tests ne lancent jamais ffmpeg. */
  loudnessAnalyzer?: TrackLoudnessAnalyzer;
  /** Tests : false empêche fs.watch, tout en créant les dossiers manquants. */
  importWatcher?: boolean;
  /** Runner de téléchargement injectable : les tests ne lancent jamais Python. */
  lucidaRunner?: AcquisitionRunner;
  /** Runner de recherche injectable : les tests ne lancent jamais le réseau. */
  lucidaSearchRunner?: LucidaSearchRunner;
  /** Timeout court de la route de recherche, injectable pour les tests. */
  lucidaSearchTimeoutMs?: number;
  /** Providers de recherche catalogue injectables (tests : aucun réseau réel). */
  discoveryProviders?: RegisteredProvider[];
  /** Encodeur Opus injectable : les tests ne lancent jamais ffmpeg/ffprobe. */
  opusEncoderRunner?: OpusEncoderRunner;
  /** Moteur de téléchargement injectable : les tests ne lancent jamais Antra. */
  downloadProvider?: DownloadProvider;
  /** Import distant injectable : les tests n'ouvrent jamais de socket Windows. */
  downloadRemoteImportService?: DownloadRemoteImportService;
  /** Recherche de pistes injectable : les tests n'appellent aucun catalogue. */
  trackSearchProvider?: TrackSearchProvider;
}

/**
 * Registre des providers de découverte depuis la config. Deezer et iTunes
 * enrichissent gratuitement les résultats (images + extraits officiels), puis
 * MusicBrainz apporte les identifiants canoniques. TIDAL reste désactivé.
 */
function buildDiscoveryProviders(
  config: AppConfig,
  discovery: DiscoveryConfig,
  previewProvider: CatalogProvider,
): RegisteredProvider[] {
  const providers: RegisteredProvider[] = [];

  // Deezer passe en premier afin que les fiches ouvertes depuis un résultat
  // fusionné conservent sa photo artiste et sa pochette haute définition.
  providers.push(
    discovery.deezerEnabled
      ? {
          id: 'deezer',
          enabled: true,
          disabledReason: null,
          provider: new DeezerDiscoveryProvider({
            baseUrl: discovery.deezerApiBase,
            timeoutMs: discovery.providerTimeoutMs,
          }),
        }
      : { id: 'deezer', enabled: false, disabledReason: 'flag_disabled', provider: null },
  );

  // Source grand public principale : API iTunes publique, sans compte ni clé.
  // Elle fournit des résultats illustrés et des extraits officiels, mais ne
  // déclenche jamais d'acquisition de fichier dans HomeSpotify.
  providers.push({
    id: 'itunes',
    enabled: true,
    disabledReason: null,
    provider: new ItunesDiscoveryProvider({ market: discovery.defaultMarket }),
  });

  providers.push(
    discovery.spotify !== undefined
      ? {
          id: 'spotify',
          enabled: true,
          disabledReason: null,
          provider: new SpotifyCatalogProvider({
            clientId: discovery.spotify.clientId,
            clientSecret: discovery.spotify.clientSecret,
            apiBase: discovery.spotify.apiBase,
            authBase: discovery.spotify.authBase,
            market: discovery.defaultMarket,
          }),
        }
      : { id: 'spotify', enabled: false, disabledReason: 'credentials_missing', provider: null },
  );

  providers.push(
    discovery.musicbrainzUserAgent !== null
      ? {
          id: 'musicbrainz',
          enabled: true,
          disabledReason: null,
          provider: new MusicBrainzCatalogProvider(
            new MusicBrainzClient({
              userAgent: discovery.musicbrainzUserAgent,
              baseUrl: discovery.musicbrainzApiBase,
            }),
          ),
        }
      : { id: 'musicbrainz', enabled: false, disabledReason: 'user_agent_missing', provider: null },
  );

  // Apple Music discovery : réutilise le provider MusicKit existant (source
  // unique du JWT) quand les secrets sont présents.
  const appleTokenSource =
    previewProvider instanceof AppleMusicCatalogProvider ? previewProvider : null;
  providers.push(
    config.appleMusic !== undefined && discovery.appleMusicEnabled && appleTokenSource !== null
      ? {
          id: 'apple_music',
          enabled: true,
          disabledReason: null,
          provider: new AppleMusicDiscoveryProvider({
            tokenSource: appleTokenSource,
            storefront: config.appleMusic.storefront,
          }),
        }
      : {
          id: 'apple_music',
          enabled: false,
          disabledReason: config.appleMusic === undefined ? 'credentials_missing' : 'flag_disabled',
          provider: null,
        },
  );

  providers.push({ id: 'tidal', enabled: false, disabledReason: 'credentials_missing', provider: null });
  return providers;
}

export function buildApp(config: AppConfig, options: BuildAppOptions = {}): FastifyInstance {
  const app = Fastify({
    logger: {
      level: config.logLevel,
      // pino est le logger natif de Fastify ; en test on ne veut aucun bruit
      enabled: config.nodeEnv !== 'test',
    },
  });

  const dbHandle = createDb(config.dbPath);
  // Migrations AVANT toute route : si le schéma ne peut pas être amené à jour,
  // l'exception remonte et le serveur n'écoute jamais (cf. server.ts). Toute
  // réparation de colonnes V3 manquantes est idempotente (cf. migrate.ts).
  app.log.info({ dbPath: config.dbPath }, 'démarrage : application des migrations');
  try {
    runMigrations(dbHandle, {
      info: (message, ctx) => app.log.info(ctx ?? {}, message),
      error: (message, ctx) => app.log.error(ctx ?? {}, message),
    });
  } catch (error) {
    app.log.error({ err: error, dbPath: config.dbPath }, 'ÉCHEC des migrations : arrêt');
    dbHandle.sqlite.close();
    throw error;
  }
  app.log.info(
    { dbPath: config.dbPath, appliedMigrations: appliedMigrationCount(dbHandle) },
    'migrations appliquées : schéma à jour',
  );
  // Migration HISTORIQUE jouée UNE SEULE FOIS : attribue au OWNER les pistes
  // sans aucun propriétaire (no-op si OWNER absent ou déjà fait). Relancée
  // après le bootstrap — cf. routes/auth.ts.
  backfillOwnerLibrary(dbHandle);
  // Répare la fuite du backfill historique : retire de la bibliothèque
  // PERSONNELLE du OWNER les pistes importées par d'autres comptes. Idempotent,
  // ne touche ni aux fichiers ni aux accès des autres comptes.
  const repaired = repairOwnerBackfillLeak(dbHandle);
  if (repaired.revokedTracks > 0) {
    app.log.warn(
      { revokedTracks: repaired.revokedTracks },
      'isolation réparée : accès OWNER issus du backfill retirés',
    );
  }
  // Nettoyage legacy : files des anciens modèles supprimées, candidats de
  // mauvaise qualité désactivés — l'historique utilisateur est préservé.
  invalidateLegacyArtifacts(dbHandle);

  const offlineConfig = config.offline ?? defaultOfflineConfig();
  for (const dir of [
    config.musicDir,
    config.incomingDir,
    config.importRoot,
    config.coversDir,
    offlineConfig.derivedCacheDir,
  ]) {
    mkdirSync(dir, { recursive: true });
  }

  // Variantes Opus hors ligne : jobs persistants, concurrence bornée (1 par
  // défaut sur le serveur H24), runner injectable pour les tests.
  const offlineVariantService = new OfflineVariantService(dbHandle, {
    musicDir: config.musicDir,
    derivedCacheDir: offlineConfig.derivedCacheDir,
    encodeConcurrency: offlineConfig.encodeConcurrency,
    runner: options.opusEncoderRunner ?? new FfmpegOpusEncoderRunner(),
    logger: {
      info: (context, message) => app.log.info(context, message),
      warn: (context, message) => app.log.warn(context, message),
      error: (context, message) => app.log.error(context, message),
    },
  });

  const importService = new UserImportService(dbHandle, {
    importRoot: config.importRoot,
    musicDir: config.musicDir,
    coversDir: config.coversDir,
  });
  const importWatcherEnabled = options.importWatcher ?? config.nodeEnv !== 'test';

  // --- Acquisition HISTORIQUE (Lucida / Monochrome) ------------------------
  // Neutralisée par défaut depuis l'intégration d'Antra : aucun ancien
  // fournisseur n'est plus lancé automatiquement. Les fichiers restent en
  // place et `ACQUISITION_LEGACY_ENABLED=true` rétablit exactement l'ancien
  // comportement.
  // `acquisitionProviders` peut être absent des configs de test historiques :
  // l'accès optionnel évite de casser un appelant existant.
  const legacyAcquisitionEnabled =
    config.acquisitionProviders?.legacyEnabled === true && config.lucida !== undefined;
  if (config.lucida !== undefined && !legacyAcquisitionEnabled) {
    app.log.info(
      'acquisition historique Lucida/Monochrome désactivée (ACQUISITION_LEGACY_ENABLED=false)',
    );
  }

  const defaultLucidaRunner = legacyAcquisitionEnabled && config.lucida
    ? new LucidaProcessRunner({
        scriptPath: config.lucida.scriptPath,
        pythonPath: config.lucida.pythonPath,
        importRoot: config.importRoot,
        processTimeoutMs: config.lucida.processTimeoutMs,
      })
    : null;
  const acquisitionRunner = config.lucida
    ? options.lucidaRunner ?? defaultLucidaRunner
    : null;
  const lucidaSearchRunner = config.lucida
    ? options.lucidaSearchRunner ?? defaultLucidaRunner
    : null;

  const acquisitionService =
    config.lucida && acquisitionRunner
      ? new AcquisitionImportService(
          dbHandle,
          new AcquisitionJobRepository(dbHandle),
          acquisitionRunner,
          importService,
          {
            maxConcurrent: config.lucida.maxConcurrentDownloads,
            interactiveVerificationEnabled:
              config.lucida.interactiveVerificationEnabled,
            interactiveVerificationTimeoutSeconds:
              config.lucida.interactiveVerificationTimeoutSeconds,
            interactiveStagingRoot: resolve(
              config.importRoot,
              '.interactive',
            ),
            monochromeStagingRoot: resolve(
              config.importRoot,
              '.monochrome',
            ),
            monochromeFallbackEnabled:
              config.acquisitionProviders
                ?.monochromeManualFallbackEnabled === true &&
              config.acquisitionProviders.order.includes(
                'MONOCHROME_MANUAL',
              ),
            monochromeManualTimeoutSeconds:
              config.acquisitionProviders
                ?.monochromeManualTimeoutSeconds ?? 600,
            providerHealth: new ProviderHealthRepository(
              dbHandle,
              config.lucida,
            ),
          },
        )
      : null;

  app.log.info(
    `Interactive Lucida verification enabled: ${
      config.lucida?.interactiveVerificationEnabled === true
    }`,
  );

  if (acquisitionService) {
    const interruptedJobs = acquisitionService.recoverInterruptedJobs();
    if (interruptedJobs > 0) {
      app.log.warn(
        { interruptedJobs },
        'acquisition Lucida : jobs actifs marqués interrompus au démarrage',
      );
    }
    if (acquisitionService.repairedOrphanedManualVerificationOnStartup()) {
      app.log.warn(
        'acquisition Lucida : état de vérification manuelle orphelin réparé',
      );
    }
  }

  // --- Recherche musicale pour le téléchargement ---------------------------
  // Antra ne sait pas rechercher par texte : la résolution « Guala Lifestyles »
  // → URL réutilise le catalogue de découverte déjà branché (Deezer, iTunes,
  // Spotify, MusicBrainz). Aucun provider externe supplémentaire.
  //
  // Résolution PARESSEUSE : `discoveryService` est assemblé plus bas, après les
  // providers média. La recherche n'a lieu qu'au moment d'une requête, donc la
  // référence est toujours initialisée à l'appel.
  let lazyTrackSearch: DiscoveryTrackSearchProvider | null = null;
  const trackSearchProvider: TrackSearchProvider = {
    name: 'discovery_catalog',
    searchTracks: (input) => {
      lazyTrackSearch ??= new DiscoveryTrackSearchProvider(discoveryService, {
        enabled: (config.discovery ?? defaultDiscoveryConfig()).enabled,
      });
      return lazyTrackSearch.searchTracks(input);
    },
  };

  // --- Moteur de téléchargement Antra (fournisseur PRINCIPAL) --------------
  // Absent de la configuration = fonctionnalité indisponible, jamais une
  // panne : le backend démarre et /api/downloads répond 503.
  const downloadProvider: DownloadProvider | null =
    options.downloadProvider ??
    (config.antra
      ? new AntraDownloadProvider(config.antra, {
          logger: {
            debug: (context, message) => app.log.debug(context, message),
            warn: (context, message) => app.log.warn(context, message),
          },
        })
      : null);

  const remoteWriteLogger = {
    info: (fields: Record<string, unknown>, message: string) =>
      app.log.info(fields, message),
    warn: (fields: Record<string, unknown>, message: string) =>
      app.log.warn(fields, message),
    error: (fields: Record<string, unknown>, message: string) =>
      app.log.error(fields, message),
  };
  const ownedRemoteDownloadImporter =
    options.downloadRemoteImportService === undefined &&
    config.audioRemote !== undefined &&
    config.audioStorageMode !== 'local'
      ? RemoteDownloadedFileImporter.fromStorageAgentClient(dbHandle, {
          coversDir: config.coversDir,
          client: new StorageAgentClient(
            config.audioRemote,
            remoteWriteLogger,
          ),
          logger: remoteWriteLogger,
        })
      : null;
  const remoteDownloadImportService =
    options.downloadRemoteImportService ?? ownedRemoteDownloadImporter ?? undefined;

  const downloadService =
    config.antra && downloadProvider
      ? new DownloadService(
          dbHandle,
          new DownloadJobRepository(dbHandle),
          downloadProvider,
          importService,
          {
            importRoot: config.importRoot,
            maxConcurrent: config.antra.maxConcurrent,
            jobTimeoutMs: config.antra.jobTimeoutMs,
            allowedExtensions: config.antra.allowedExtensions,
            ...(remoteDownloadImportService === undefined
              ? {}
              : { remoteImportService: remoteDownloadImportService }),
            searchProvider: options.trackSearchProvider ?? trackSearchProvider,
            logger: {
              info: (context, message) => app.log.info(context, message),
              warn: (context, message) => app.log.warn(context, message),
              error: (context, message) => app.log.error(context, message),
              debug: (context, message) => app.log.debug(context, message),
            },
          },
        )
      : null;

  if (downloadService) {
    const interrupted = downloadService.recoverInterruptedJobs();
    if (interrupted > 0) {
      app.log.warn(
        { interruptedJobs: interrupted },
        'téléchargements Antra : jobs actifs marqués interrompus au démarrage',
      );
    }
  } else {
    app.log.info('moteur de téléchargement Antra non configuré (ANTRA_DIR absent)');
  }

  const backupScheduler = config.backup?.enabled
    ? new ServerBackupScheduler(
        config.backup,
        {
          dbPath: config.dbPath,
          coversDir: config.coversDir,
          musicDir: config.musicDir,
        },
        {
          info: (context, message) => app.log.info(context, message),
          error: (context, message) => app.log.error(context, message),
        },
      )
    : null;

  app.decorate('config', config);
  app.decorate('dbHandle', dbHandle);
  app.decorate('offlineVariants', offlineVariantService);
  // Mode validé au chargement de la configuration : une valeur inconnue a déjà
  // fait échouer le démarrage, il n'y a pas de repli silencieux ici.
  app.decorate(
    'audioStorage',
    createAudioStorageProvider(config.audioStorageMode ?? DEFAULT_AUDIO_STORAGE_MODE, {
      musicDir: config.musicDir,
      ...(config.audioRemote === undefined ? {} : { remote: config.audioRemote }),
      ...(config.audioCache === undefined ? {} : { cache: config.audioCache }),
      logger: {
        info: (fields, message) => app.log.info(fields, message),
        warn: (fields, message) => app.log.warn(fields, message),
        error: (fields, message) => app.log.error(fields, message),
      },
    }),
  );
  // Les dérivées hors ligne sont régénérables et vivent sur la machine qui
  // exécute l'API : elles ne transiteront jamais par le Storage Agent.
  app.decorate(
    'offlineVariantStorage',
    new LocalFileStorageProvider(offlineConfig.derivedCacheDir),
  );

  // Uploads WAV volumineux (~50 Mo/piste) : limite configurable, 200 Mo par défaut
  app.register(multipart, { limits: { fileSize: config.maxUploadBytes, files: 1 } });

  // Access tokens JWT signés HMAC ; secret via AUTH_TOKEN_SECRET (cf. config.ts)
  app.register(fastifyJwt, { secret: config.authTokenSecret });

  app.addHook('onClose', async () => {
    backupScheduler?.stop();
    await downloadService?.stop();
    ownedRemoteDownloadImporter?.close();
    await acquisitionService?.stop();
    // Si le runner par défaut n’est utilisé que par la recherche, il n’est
    // pas détenu par AcquisitionImportService et doit aussi être arrêté ici.
    if (defaultLucidaRunner !== acquisitionRunner) {
      defaultLucidaRunner?.stopAll();
    }
    importService.stop();
    offlineVariantService.stop();
    await offlineVariantService.drain();
    await app.audioStorage.close?.();
    dbHandle.sqlite.close();
  });

  app.addHook('onReady', async () => {
    if (importWatcherEnabled) await importService.start();
    else await importService.ensureAllUserDirectories();
    backupScheduler?.start();
    // Reprise des encodages interrompus (ENCODING → PENDING → file).
    offlineVariantService.resumePendingJobs();
  });

  app.setErrorHandler((error: FastifyError, request, reply) => {
    request.log.error({ err: error }, 'unhandled error');
    const statusCode = error.statusCode && error.statusCode >= 400 ? error.statusCode : 500;
    const message =
      statusCode >= 500 && config.nodeEnv === 'production'
        ? 'Internal Server Error'
        : error.message;
    reply.status(statusCode).send({ statusCode, error: 'error', message });
  });

  app.setNotFoundHandler((request, reply) => {
    reply.status(404).send({
      statusCode: 404,
      error: 'not_found',
      message: `Route ${request.method} ${request.url} inconnue`,
    });
  });

  app.get('/health', async () => ({
    status: 'ok',
    timestamp: new Date().toISOString(),
    uptimeSeconds: Math.round(process.uptime()),
  }));

  app.get('/version', async () => ({
    name: pkg.name,
    version: pkg.version,
    environment: config.nodeEnv,
  }));

  app.get('/api/status', async () => ({
    phase: CURRENT_PHASE,
    backendReady: true,
    database: isDbInitialized(dbHandle) ? 'initialized' : 'not_initialized',
    trackCount: dbHandle.db.select({ n: sql<number>`count(*)` }).from(tracks).get()?.n ?? 0,
  }));

  // Providers externes du moteur de recommandation — utilisés UNIQUEMENT par
  // le job asynchrone de rafraîchissement, jamais pendant un GET de feed.
  // Sans clé LASTFM_API_KEY (.env), le graphe est « non configuré » : le feed
  // sert la file locale existante et le diagnostic OWNER l'affiche.
  const similarityProvider: MusicSimilarityProvider | null =
    options.similarityProvider !== undefined
      ? options.similarityProvider
      : config.lastfm !== undefined
        ? new LastfmMusicSimilarityProvider(
            new LastfmClient({
              apiKey: config.lastfm.apiKey,
              baseUrl: config.lastfm.baseUrl,
              timeoutMs: config.lastfm.timeoutMs,
            }),
          )
        : null;
  // Provider catalogue média : Apple Music si secrets présents (SECONDAIRE, non
  // validé — cf. config.appleMusic), sinon iTunes durci storefront FR (PRIMAIRE
  // validé). Jamais de secret journalisé ; toute erreur de clé fait échouer le
  // démarrage tôt (cf. loadAppleMusicConfig).
  let previewProvider: CatalogProvider;
  if (options.previewProvider !== undefined) {
    previewProvider = options.previewProvider;
  } else if (config.appleMusic !== undefined) {
    previewProvider = new AppleMusicCatalogProvider({
      teamId: config.appleMusic.teamId,
      keyId: config.appleMusic.keyId,
      privateKeyPem: loadAppleKeyPem(config.appleMusic.privateKeyPath),
      storefront: config.appleMusic.storefront,
      ...(config.appleMusic.mediaId ? { mediaId: config.appleMusic.mediaId } : {}),
    });
    app.log.info('provider média : Apple Music (secondaire, secrets présents)');
  } else {
    previewProvider = new ItunesCatalogProvider();
  }
  const refreshDeps = {
    similarityProvider,
    previewProvider,
    ...(options.previewValidator ? { previewValidator: options.previewValidator } : {}),
  };
  // --- Recherche catalogue multi-fournisseurs (Phase Discovery) -------------
  // Un provider n'est ACTIF que si sa conformité et ses credentials sont
  // vérifiés ; sinon il reste inscrit comme DISABLED avec une raison stable.
  const discoveryConfig = config.discovery ?? defaultDiscoveryConfig();
  const discoveryProviders: RegisteredProvider[] =
    options.discoveryProviders ?? buildDiscoveryProviders(config, discoveryConfig, previewProvider);
  const discoveryService = new DiscoveryCatalogService({
    providers: discoveryProviders,
    cache: new DiscoveryCache(dbHandle, { maxEntries: discoveryConfig.cacheMaxEntries }),
    defaultMarket: discoveryConfig.defaultMarket,
    providerTimeoutMs: discoveryConfig.providerTimeoutMs,
    logger: {
      info: (context, message) => app.log.info(context, message),
      warn: (context, message) => app.log.warn(context, message),
    },
  });

  const audioAnalysis = new TrackAudioAnalysisService(
    dbHandle,
    config.musicDir,
    options.bpmAnalyzer ?? new MetadataThenFfmpegBpmAnalyzer(),
  );
  const loudnessAnalysis = new TrackLoudnessAnalysisService(
    dbHandle,
    config.musicDir,
    options.loudnessAnalyzer ?? new FfmpegR128Analyzer(),
  );

  app.register(async (instance) => {
    const guards = createAuthGuards(instance);
    registerTrackRoutes(instance, guards);
    registerOfflineRoutes(instance, guards, offlineVariantService);
    registerSyncRoutes(instance, guards);
    registerPlayerRoute(instance);
    registerAuthRoutes(instance, guards, {
      // Après login réussi : régénération asynchrone de la file de reco.
      onLoginSuccess: (userId) => {
        refreshRecommendationQueueForUser(dbHandle, userId, refreshDeps).catch((error) => {
          instance.log.error({ err: error, userId }, 'refresh reco post-login échoué');
        });
      },
      onUserCreated: async (userId, username) => {
        if (importWatcherEnabled) await importService.ensureAndWatchUser(userId, username);
        else await importService.ensureUserDirectory(userId, username);
      },
    });
    registerAdminRoutes(instance, guards, {
      onUserCreated: async (userId, username) => {
        if (importWatcherEnabled) await importService.ensureAndWatchUser(userId, username);
        else await importService.ensureUserDirectory(userId, username);
      },
      backupStatus: () =>
        backupScheduler?.status() ?? {
          enabled: false,
          running: false,
          nextRunAt: null,
          lastSuccessAt: null,
          lastDestination: null,
          lastErrorAt: null,
          lastError: null,
          retentionCount: 0,
        },
      ...(backupScheduler ? { runBackup: () => backupScheduler.runNow() } : {}),
      importScanStatus: () => importService.status(),
    });
    registerLibraryAdminRoutes(instance, guards);
    registerFavoritesRoutes(instance, guards);
    registerPlaylistsRoutes(instance, guards);
    // Catalogue global anonymisé (« Ajouts récents ») + ajout à SA bibliothèque.
    registerCatalogRoutes(instance, guards);
    registerDiscoveryRoutes(instance, guards, { refreshDeps });
    registerDiscoveryCatalogRoutes(instance, guards, {
      service: discoveryService,
      discoveryEnabled: discoveryConfig.enabled,
    });
    registerPlayEventRoutes(instance, guards);
    registerPlaybackSettingsRoutes(instance, guards, audioAnalysis);
    registerLoudnessAnalysisRoutes(instance, guards, loudnessAnalysis);
    registerImportRoutes(instance, guards, importService);
    // Téléchargement par URL — fournisseur PRINCIPAL et par défaut.
    registerDownloadRoutes(instance, guards, { service: downloadService });
    registerAcquisitionImportRoutes(instance, guards, {
      service: acquisitionService,
      searchRunner: lucidaSearchRunner,
      ...(options.lucidaSearchTimeoutMs !== undefined
        ? { searchTimeoutMs: options.lucidaSearchTimeoutMs }
        : {}),
    });
  });

  return app;
}
