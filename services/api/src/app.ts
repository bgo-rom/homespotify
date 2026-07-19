import { mkdirSync, readFileSync } from 'node:fs';
import Fastify, { type FastifyError, type FastifyInstance } from 'fastify';
import multipart from '@fastify/multipart';
import fastifyJwt from '@fastify/jwt';
import { sql } from 'drizzle-orm';
import {
  defaultDiscoveryConfig,
  defaultNodeFetchConfig,
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
import { registerMusicRequestRoutes } from './routes/music-requests.js';
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
import { reconcileAllMusicRequests } from './discovery/music-request-service.js';
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
import { AppleMusicDiscoveryProvider } from './discovery/catalog/apple-music-discovery-provider.js';
import { MusicBrainzClient } from './metadata/musicbrainz-client.js';
import {
  MetadataThenFfmpegBpmAnalyzer,
  TrackAudioAnalysisService,
  type TrackBpmAnalyzer,
} from './audio/bpm-analysis.js';
import { registerPlaybackSettingsRoutes } from './routes/playback-settings.js';
import { UserImportService } from './import/user-import-service.js';
import { registerImportRoutes } from './routes/imports.js';
import { NodeFetchService } from './import/node-fetch-service.js';
import { registerNodeFetchRoutes } from './routes/node-fetch.js';
import { registerRemoteLibraryRoutes } from './routes/remote-library.js';

const pkg = JSON.parse(
  readFileSync(new URL('../package.json', import.meta.url), 'utf-8'),
) as { name: string; version: string };

export const CURRENT_PHASE = 'Phase 3 — bibliothèque, métadonnées & sync offline';

declare module 'fastify' {
  interface FastifyInstance {
    dbHandle: DbHandle;
    config: AppConfig;
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
  /** Tests : false empêche fs.watch, tout en créant les dossiers manquants. */
  importWatcher?: boolean;
  /** Providers de recherche catalogue injectables (tests : aucun réseau réel). */
  discoveryProviders?: RegisteredProvider[];
  /** Transport HTTP injectable : les tests de fetch-node restent hors réseau. */
  nodeFetchHttpClient?: typeof globalThis.fetch;
}

/**
 * Registre des providers de découverte depuis la config. Deezer et TIDAL sont
 * conservés DÉSACTIVÉS (interface prête, conformité/credentials non confirmés
 * — cf. DISCOVERY_CATALOG.md) : leurs recherches retournent PROVIDER_DISABLED
 * et les disponibilités correspondantes restent UNKNOWN.
 */
function buildDiscoveryProviders(
  config: AppConfig,
  discovery: DiscoveryConfig,
  previewProvider: CatalogProvider,
): RegisteredProvider[] {
  const providers: RegisteredProvider[] = [];

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

  providers.push({ id: 'deezer', enabled: false, disabledReason: 'tos_unverified', provider: null });
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
  // Réconciliation au boot : COMPLETED n'est vrai que si la piste associée
  // est réellement visible dans la bibliothèque du demandeur.
  reconcileAllMusicRequests(dbHandle);
  // Nettoyage legacy : files des anciens modèles supprimées, candidats de
  // mauvaise qualité désactivés — l'historique utilisateur est préservé.
  invalidateLegacyArtifacts(dbHandle);

  for (const dir of [config.musicDir, config.incomingDir, config.importRoot, config.coversDir]) {
    mkdirSync(dir, { recursive: true });
  }

  const importService = new UserImportService(dbHandle, {
    importRoot: config.importRoot,
    musicDir: config.musicDir,
    coversDir: config.coversDir,
  });
  const nodeFetchService = new NodeFetchService({
    config: config.nodeFetch ?? defaultNodeFetchConfig(),
    importService,
    logger: {
      info: (context, message) => app.log.info(context, message),
      warn: (context, message) => app.log.warn(context, message),
    },
    ...(options.nodeFetchHttpClient
      ? { fetchImpl: options.nodeFetchHttpClient }
      : {}),
  });
  const importWatcherEnabled = options.importWatcher ?? config.nodeEnv !== 'test';

  app.decorate('config', config);
  app.decorate('dbHandle', dbHandle);

  // Uploads WAV volumineux (~50 Mo/piste) : limite configurable, 200 Mo par défaut
  app.register(multipart, { limits: { fileSize: config.maxUploadBytes, files: 1 } });

  // Access tokens JWT signés HMAC ; secret via AUTH_TOKEN_SECRET (cf. config.ts)
  app.register(fastifyJwt, { secret: config.authTokenSecret });

  app.addHook('onClose', async () => {
    await nodeFetchService.stop();
    importService.stop();
    dbHandle.sqlite.close();
  });

  app.addHook('onReady', async () => {
    if (importWatcherEnabled) await importService.start();
    else await importService.ensureAllUserDirectories();
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

  app.register(async (instance) => {
    const guards = createAuthGuards(instance);
    registerTrackRoutes(instance, guards);
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
    registerMusicRequestRoutes(instance, guards);
    registerPlayEventRoutes(instance, guards);
    registerPlaybackSettingsRoutes(instance, guards, audioAnalysis);
    registerImportRoutes(instance, guards, importService);
    registerNodeFetchRoutes(instance, guards, nodeFetchService);
    registerRemoteLibraryRoutes(instance, guards, nodeFetchService);
  });

  return app;
}
