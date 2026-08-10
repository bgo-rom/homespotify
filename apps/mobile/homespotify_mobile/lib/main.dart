import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import 'src/app/router.dart';
import 'src/core/logging/app_logger.dart';
import 'src/core/logging/provider_logger.dart';
import 'src/core/network/api_client.dart';
import 'src/core/network/authenticated_artwork_cache.dart';
import 'src/core/theme/app_colors.dart';
import 'src/core/theme/app_theme.dart';
import 'src/features/auth/application/auth_controller.dart';
import 'src/features/auth/data/auth_session_manager.dart';
import 'src/features/auth/data/token_store.dart';
import 'src/features/app_update/presentation/app_update_shell.dart';
import 'src/features/auth/presentation/auth_flow.dart';
import 'src/features/listening/application/listening_activity_tracker.dart';
import 'src/features/offline/application/offline_index.dart';
import 'src/features/offline/application/offline_batch_download_manager.dart';
import 'src/features/offline/presentation/offline_mode_banner.dart';
import 'src/features/player/audio/audio_diagnostics.dart';
import 'src/features/player/audio/background_audio_config.dart';
import 'src/features/player/audio/homespotify_audio_handler.dart';
import 'src/features/player/audio/replay_gain.dart';
import 'src/features/player/data/playback_settings_api.dart';
import 'src/features/player/data/playback_session_store.dart';

StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
StreamSubscription<int>? _authSessionSubscription;
AppLifecycleListener? _appLifecycleListener;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Erreurs framework : log structuré avec stacktrace complète, en gardant
  // le rapport console standard de debug.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    logError(
      'Erreur Flutter: ${details.exceptionAsString()}',
      error: details.exception,
      stackTrace: details.stack,
    );
    AudioDiagnostics.instance.log('APP_FLUTTER_ERROR', {
      'exceptionClass': details.exception.runtimeType,
      'message': details.exceptionAsString(),
    });
  };
  // Erreurs asynchrones non gérées (hors framework).
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    logError('Erreur non gérée', error: error, stackTrace: stackTrace);
    AudioDiagnostics.instance.log('APP_UNHANDLED_ERROR', {
      'exceptionClass': error.runtimeType,
      'message': error,
    });
    return true;
  };
  // À la place de l'écran rouge : UI d'erreur Direction 33 (claire ou sombre
  // selon le téléphone) avec retour à l'accueil.
  ErrorWidget.builder = (details) => _AppErrorScreen(details: details);

  // Session auth : tokens dans le Keystore Android, refresh single-flight.
  // L'intercepteur Bearer est posé sur le Dio partagé AVANT le premier appel.
  final tokenStore = SecureTokenStore();
  final sessionManager = AuthSessionManager(
    store: tokenStore,
    refreshDio: createApiClient(),
  );
  apiClient.interceptors.add(AuthInterceptor(sessionManager));

  // Le handler doit être enregistré auprès d'audio_service avant runApp.
  // Son constructeur reste sans appel natif bloquant : l'initialisation
  // obligatoire du service ne réintroduit donc pas l'ancien ANR au démarrage.
  final artworkCache = AuthenticatedArtworkCache(apiClient);
  final loudnessEnhancer = AndroidLoudnessEnhancer();
  final audioPlayer = createHomeSpotifyAudioPlayer(
    audioPipeline: AudioPipeline(androidAudioEffects: [loudnessEnhancer]),
  );
  final audioHandler = await AudioService.init<HomeSpotifyAudioHandler>(
    builder: () => HomeSpotifyAudioHandler(
      player: audioPlayer,
      playbackSettingsRepository: PlaybackSettingsApi(apiClient),
      authorizationRefresh: sessionManager.refreshSession,
      currentAuthorizationExpiresIn: () => sessionManager.accessTokenExpiresIn,
      currentAuthorizationHeaders: () {
        final token = sessionManager.accessToken;
        return token == null || token.isEmpty
            ? const <String, String>{}
            : <String, String>{'Authorization': 'Bearer $token'};
      },
      artworkResolver: (item) async {
        final trackId = int.tryParse(item.id);
        final coverUri = item.artUri;
        final userId = item.userId;
        if (userId == null ||
            userId <= 0 ||
            trackId == null ||
            coverUri == null) {
          return null;
        }
        return artworkCache.resolve(
          userId: userId,
          trackId: trackId,
          coverUri: coverUri,
          coverIdentity: item.artworkIdentity,
        );
      },
      artworkCacheClear: artworkCache.clear,
      playbackSessionStore: SharedPreferencesPlaybackSessionStore(),
    ),
    config: homeSpotifyAudioServiceConfig,
  );
  final replayGainController = ReplayGainController(
    repository: CachedReplayGainRepository.withDefaults(apiClient),
    engine: AndroidReplayGainEngine(
      loudnessEnhancer,
      attenuationApplier: audioHandler.setReplayGainAttenuationDb,
    ),
    mediaItems: audioHandler.mediaItem,
  );
  await replayGainController.initialize();

  // Le JWT est renouvelé avant son expiration, mais les AudioSource Media3
  // ont leurs headers figés au moment de leur création. Chaque rotation doit
  // donc reconstruire la file native avec le nouveau Bearer, sinon le morceau
  // suivant continue d'utiliser l'ancien token et finit en boucle de 401.
  await _authSessionSubscription?.cancel();
  _authSessionSubscription = sessionManager.sessionChanges.listen(
    (revision) {
      unawaited(
        audioHandler.handleAuthorizationChanged(
          reason: 'session-revision-$revision',
        ),
      );
    },
    onError: (Object error) {
      AudioDiagnostics.instance.log('AUDIO_AUTH_SESSION_OBSERVER_ERROR', {
        'error': error,
      });
    },
  );

  _appLifecycleListener?.dispose();
  _appLifecycleListener = AppLifecycleListener(
    onResume: () {
      AudioDiagnostics.instance.log('APP_RESUMED');
      unawaited(sessionManager.ensureFreshSession());
    },
  );

  runApp(
    ProviderScope(
      observers: const [LoggingProviderObserver()],
      // Riverpod 3 réessaie par défaut un provider en échec (10 fois, backoff
      // 200 ms → 6,4 s) en publiant un état de chargement : l'utilisateur
      // verrait un squelette pendant ~2 minutes au lieu du message d'erreur.
      // HomeSpotify affiche ses erreurs explicitement (HomeErrorState,
      // pull-to-refresh, boutons « Réessayer ») : le retry reste une décision
      // de l'utilisateur, jamais un masquage silencieux.
      retry: (retryCount, error) => null,
      overrides: [
        audioHandlerProvider.overrideWithValue(audioHandler),
        replayGainControllerProvider.overrideWithValue(replayGainController),
        tokenStoreProvider.overrideWithValue(tokenStore),
        authSessionManagerProvider.overrideWithValue(sessionManager),
        // Bridge hors ligne → auth : le compte courant alimente l'index local,
        // réactif au login/logout (offline y compris, via state.user).
        offlineUserIdProvider.overrideWith(
          (ref) => ref.watch(
            authControllerProvider.select((state) => state.user?.id),
          ),
        ),
      ],
      child: const HomeSpotifyMobileApp(),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(
      _initializeAudioDiagnostics(
        audioHandler: audioHandler,
        sessionManager: sessionManager,
      ),
    );
  });
}

Future<void> _initializeAudioDiagnostics({
  required HomeSpotifyAudioHandler audioHandler,
  required AuthSessionManager sessionManager,
}) async {
  final diagnostics = AudioDiagnostics.instance;
  try {
    await diagnostics.initialize();
    final connectivity = Connectivity();
    final initial = await connectivity.checkConnectivity();
    final initialHasNetwork = _hasUsableNetwork(initial);
    diagnostics.log('NETWORK_CONNECTIVITY_CHANGED', {
      'transports': initial.map((result) => result.name).toSet().toList(),
      'initial': true,
      'hasNetwork': initialHasNetwork,
    });
    await audioHandler.handleConnectivityChanged(initialHasNetwork);
    await _connectivitySubscription?.cancel();
    _connectivitySubscription = connectivity.onConnectivityChanged.listen(
      (results) {
        final hasNetwork = _hasUsableNetwork(results);
        diagnostics.log('NETWORK_CONNECTIVITY_CHANGED', {
          'transports': results.map((result) => result.name).toSet().toList(),
          'initial': false,
          'hasNetwork': hasNetwork,
        });
        unawaited(audioHandler.handleConnectivityChanged(hasNetwork));
        if (hasNetwork) {
          unawaited(sessionManager.handleConnectivityRestored());
        }
      },
      onError: (Object error) {
        diagnostics.log('NETWORK_CONNECTIVITY_OBSERVER_ERROR', {
          'error': error,
        });
      },
    );
  } catch (error) {
    diagnostics.log('AUDIO_DIAGNOSTICS_INITIALIZATION_FAILED', {
      'error': error,
    });
  }
}

bool _hasUsableNetwork(List<ConnectivityResult> results) {
  return results.any((result) => result != ConnectivityResult.none);
}

class HomeSpotifyMobileApp extends ConsumerWidget {
  const HomeSpotifyMobileApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authStatus = ref.watch(
      authControllerProvider.select((state) => state.status),
    );

    // Rien de l'application principale n'est monté avant `authenticated` ou
    // `offline` (serveur injoignable + session locale connue) : chargement,
    // bootstrap, login, changement de mot de passe et verrou biométrique
    // passent par AuthFlowScreen. Une panne réseau n'est JAMAIS un logout.
    final mountsMainApp =
        authStatus == AuthStatus.authenticated ||
        authStatus == AuthStatus.offline;
    if (!mountsMainApp) {
      return MaterialApp(
        title: 'HomeSpotify',
        debugShowCheckedModeBanner: false,
        // « Direction 33 » clair et sombre, comme l'application principale :
        // le parcours d'authentification suit désormais le même thème.
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: ThemeMode.system,
        // L'assistant de mise à jour couvre AUSSI l'écran de connexion : une
        // version trop ancienne pour ouvrir une session doit pouvoir se mettre
        // à jour (cf. features/app_update).
        home: const AppUpdateShell(child: AuthFlowScreen()),
      );
    }

    final userId = ref.watch(
      authControllerProvider.select((state) => state.user?.id),
    );
    if (userId != null && authStatus == AuthStatus.authenticated) {
      // Le tracker vit avec le compte authentifié et est détruit au logout.
      // Son initialisation et ses écritures restent entièrement asynchrones.
      ref.watch(listeningActivityTrackerProvider(userId));
    }
    if (userId != null) {
      // Reprend les groupes interrompus au prochain lancement et à chaque
      // retour d'un transport réseau autorisé. Un échec reste visible dans le
      // manifeste ; il ne bloque jamais le montage de l'application.
      ref.watch(offlineBatchBootstrapProvider(userId));
    }

    return MaterialApp.router(
      title: 'HomeSpotify',
      debugShowCheckedModeBanner: false,
      // « Direction 33 » clair et sombre : DEUX FACES DU MÊME design system.
      // Le choix suit le réglage du téléphone, sans sélecteur manuel.
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      routerConfig: appRouter,
      // Bandeau discret « Mode hors connexion », puis l'assistant de mise à
      // jour par-dessus toute l'application.
      builder: (context, child) =>
          AppUpdateShell(child: OfflineAwareShell(child: child)),
    );
  }
}

/// Écran d'erreur affiché à la place de l'écran rouge Flutter.
///
/// Volontairement sans widget Material (peut être monté au-dessus de tout
/// MaterialApp, donc sans `Theme` accessible) ; la palette est choisie
/// directement sur la luminosité du système, et le bouton ramène à l'accueil
/// via le routeur global.
class _AppErrorScreen extends StatelessWidget {
  const _AppErrorScreen({required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final message = kReleaseMode
        ? 'Une erreur inattendue est survenue.'
        : details.exceptionAsString();
    final colors =
        PlatformDispatcher.instance.platformBrightness == Brightness.dark
        ? AppColors.dark
        : AppColors.light;

    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: colors.background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.error_outline_rounded,
                  color: colors.danger,
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.textSecondary,
                    fontSize: 13,
                    fontFamily: 'Sora',
                  ),
                ),
                const SizedBox(height: 20),
                GestureDetector(
                  onTap: () => appRouter.go('/'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: colors.accent,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Revenir à l’accueil',
                      style: TextStyle(
                        color: colors.onAccent,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'Sora',
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
