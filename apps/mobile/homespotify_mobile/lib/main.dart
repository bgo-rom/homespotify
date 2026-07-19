import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app/router.dart';
import 'src/core/logging/app_logger.dart';
import 'src/core/logging/provider_logger.dart';
import 'src/core/network/api_client.dart';
import 'src/core/network/authenticated_artwork_cache.dart';
import 'src/core/theme/home_design.dart';
import 'src/features/auth/application/auth_controller.dart';
import 'src/features/auth/data/auth_session_manager.dart';
import 'src/features/auth/data/token_store.dart';
import 'src/features/auth/presentation/auth_flow.dart';
import 'src/features/listening/application/listening_activity_tracker.dart';
import 'src/features/player/audio/homespotify_audio_handler.dart';
import 'src/features/player/data/playback_settings_api.dart';

void main() {
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
  };
  // Erreurs asynchrones non gérées (hors framework).
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    logError('Erreur non gérée', error: error, stackTrace: stackTrace);
    return true;
  };
  // À la place de l'écran rouge : UI d'erreur sombre avec retour bibliothèque.
  ErrorWidget.builder = (details) => _DarkErrorScreen(details: details);

  // Session auth : tokens dans le Keystore Android, refresh single-flight.
  // L'intercepteur Bearer est posé sur le Dio partagé AVANT le premier appel.
  final tokenStore = SecureTokenStore();
  final sessionManager = AuthSessionManager(
    store: tokenStore,
    refreshDio: createApiClient(),
  );
  apiClient.interceptors.add(AuthInterceptor(sessionManager));

  // Le handler local est disponible immédiatement : aucune initialisation
  // native audio ne peut retarder la première frame Flutter.
  final artworkCache = AuthenticatedArtworkCache(apiClient);
  final audioHandler = HomeSpotifyAudioHandler(
    playbackSettingsRepository: PlaybackSettingsApi(apiClient),
    authorizationRefresh: sessionManager.refreshSession,
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
        tokenStoreProvider.overrideWithValue(tokenStore),
        authSessionManagerProvider.overrideWithValue(sessionManager),
      ],
      child: const HomeSpotifyMobileApp(),
    ),
  );

  // audio_service ne sert qu'à rattacher le handler déjà actif à la
  // notification Android. Cette étape reste hors du chemin critique du rendu :
  // un échec natif ne bloque ni l'authentification, ni la bibliothèque.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(_attachAndroidAudioService(audioHandler));
  });
}

Future<void> _attachAndroidAudioService(
  HomeSpotifyAudioHandler audioHandler,
) async {
  final stopwatch = Stopwatch()..start();
  try {
    await AudioService.init<HomeSpotifyAudioHandler>(
      builder: () => audioHandler,
      config: const AudioServiceConfig(
        androidNotificationChannelId: 'com.homespotify.mobile.audio',
        androidNotificationChannelName: 'HomeSpotify playback',
        androidNotificationOngoing: true,
      ),
    );
    logAudioAction(
      'audio_service attaché après ${stopwatch.elapsedMilliseconds} ms',
    );
  } catch (error, stackTrace) {
    logError(
      'audio_service indisponible après ${stopwatch.elapsedMilliseconds} ms; '
      'lecteur local conservé',
      error: error,
      stackTrace: stackTrace,
    );
  }
}

class HomeSpotifyMobileApp extends ConsumerWidget {
  const HomeSpotifyMobileApp({super.key});

  static final ThemeData _darkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: HomeDesign.background,
    colorScheme: ColorScheme.fromSeed(
      seedColor: HomeDesign.accent,
      brightness: Brightness.dark,
      surface: HomeDesign.surface,
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: HomeDesign.background,
      foregroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      backgroundColor: HomeDesign.surface,
      elevation: 0,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: HomeDesign.accent,
        foregroundColor: Colors.black,
        minimumSize: const Size(48, 48),
      ),
    ),
    visualDensity: VisualDensity.standard,
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authStatus = ref.watch(
      authControllerProvider.select((state) => state.status),
    );

    // Rien de l'application principale n'est monté avant l'état
    // `authenticated` : chargement, bootstrap, login, changement de mot de
    // passe et verrou biométrique passent par AuthFlowScreen.
    if (authStatus != AuthStatus.authenticated) {
      return MaterialApp(
        title: 'HomeSpotify',
        debugShowCheckedModeBanner: false,
        theme: _darkTheme,
        home: const AuthFlowScreen(),
      );
    }

    final userId = ref.watch(
      authControllerProvider.select((state) => state.user?.id),
    );
    if (userId != null) {
      // Le tracker vit avec le compte authentifié et est détruit au logout.
      // Son initialisation et ses écritures restent entièrement asynchrones.
      ref.watch(listeningActivityTrackerProvider(userId));
    }

    return MaterialApp.router(
      title: 'HomeSpotify',
      debugShowCheckedModeBanner: false,
      // Thème sombre global : aucune surface blanche possible, y compris
      // pendant les transitions de routes ou avant le premier build d'écran.
      theme: _darkTheme,
      routerConfig: appRouter,
    );
  }
}

/// Écran d'erreur sombre affiché à la place de l'écran rouge Flutter.
///
/// Volontairement sans widget Material (peut être monté au-dessus de tout
/// MaterialApp) ; le bouton ramène à la bibliothèque via le routeur global.
class _DarkErrorScreen extends StatelessWidget {
  const _DarkErrorScreen({required this.details});

  final FlutterErrorDetails details;

  @override
  Widget build(BuildContext context) {
    final message = kReleaseMode
        ? 'Une erreur inattendue est survenue.'
        : details.exceptionAsString();
    return Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF0D0D10),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Color(0xFFE57373),
                  size: 48,
                ),
                const SizedBox(height: 16),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  maxLines: 6,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
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
                      color: const Color(0xFF1DB954),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'Revenir à l’accueil',
                      style: TextStyle(
                        color: Colors.black,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
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
