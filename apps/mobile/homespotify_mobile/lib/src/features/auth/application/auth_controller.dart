import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/api_client.dart';
import '../../library/data/library_api.dart';
import '../../library/presentation/library_favorites.dart';
import '../../library/presentation/library_playlists.dart';
import '../../discovery/presentation/discover_deck_controller.dart';
import '../../discovery/presentation/discovery_preview_controller.dart';
import '../../library/presentation/library_summary.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../data/auth_api.dart';
import '../../catalog/data/catalog_api.dart';
import '../../library/application/track_library_membership.dart';
import '../../catalog_search/application/catalog_search_controller.dart';
import '../../catalog_search/presentation/catalog_preview_controller.dart';
import '../../catalog_search/presentation/request_from_catalog_sheet.dart';
import '../../offline/application/offline_index.dart';
import '../data/auth_session_manager.dart';
import '../data/biometric_service.dart';
import '../data/token_store.dart';
import '../domain/auth_user.dart';

/// États du flux d'authentification. L'application principale n'est montée
/// qu'en [authenticated] ou [offline] ; rien ne s'affiche avant résolution
/// ([loading]).
enum AuthStatus {
  loading,
  bootstrapRequired,
  unauthenticated,
  passwordChangeRequired,
  locked, // session valide mais verrouillée derrière la biométrie
  authenticated,

  /// Serveur injoignable mais session locale connue : l'application s'ouvre en
  /// « Mode hors connexion » (bibliothèque téléchargée seulement). JAMAIS un
  /// logout — la session et les tokens restent intacts, la reprise en ligne
  /// est automatique.
  offline,
  error,
}

class AuthState {
  const AuthState(this.status, {this.user, this.message, this.busy = false});

  final AuthStatus status;
  final AuthUser? user;

  /// Message d'erreur affichable (jamais de détail technique sensible).
  final String? message;

  /// Une action (login, bootstrap…) est en cours : désactive les formulaires.
  final bool busy;

  AuthState copyWith({String? message, bool? busy}) =>
      AuthState(status, user: user, message: message, busy: busy ?? this.busy);
}

// --- Providers d'infrastructure (surchargés dans main.dart / les tests) -----

final tokenStoreProvider = Provider<TokenStore>(
  (ref) => throw UnimplementedError('tokenStoreProvider doit être surchargé'),
);

final authSessionManagerProvider = Provider<AuthSessionManager>(
  (ref) => throw UnimplementedError(
    'authSessionManagerProvider doit être surchargé',
  ),
);

final authApiProvider = Provider<AuthApi>(
  (ref) => AuthApi(ref.watch(apiClientProvider)),
);

final biometricServiceProvider = Provider<BiometricService>(
  (ref) => BiometricService(),
);

final audioLogoutPurgeProvider = Provider<Future<void> Function()>((ref) {
  final handler = ref.watch(audioHandlerProvider);
  return handler.clearForLogout;
});

final audioSessionRestoreProvider = Provider<Future<bool> Function(int userId)>(
  (ref) {
    final handler = ref.watch(audioHandlerProvider);
    return handler.restorePlaybackSessionForUser;
  },
);

final authSessionRevisionProvider = StreamProvider<int>((ref) {
  return ref.watch(authSessionManagerProvider).sessionChanges;
});

final mediaAuthorizationHeadersProvider = Provider<Map<String, String>>((ref) {
  // Le manager reste la source unique du token. La révision ne contient aucun
  // secret ; elle rend seulement ce provider réactif après login/refresh/logout.
  ref.watch(authSessionRevisionProvider);
  final token = ref.watch(authSessionManagerProvider).accessToken;
  if (token == null || token.isEmpty) return const <String, String>{};
  return <String, String>{'Authorization': 'Bearer $token'};
});

final authControllerProvider = NotifierProvider<AuthController, AuthState>(
  AuthController.new,
);

class AuthController extends Notifier<AuthState> {
  AuthApi get _api => ref.read(authApiProvider);
  AuthSessionManager get _session => ref.read(authSessionManagerProvider);
  TokenStore get _store => ref.read(tokenStoreProvider);
  BiometricService get _biometrics => ref.read(biometricServiceProvider);

  /// Sondage automatique du retour serveur en mode hors connexion.
  Timer? _onlineRestoreTimer;
  static const _onlineRestoreInterval = Duration(seconds: 30);

  @override
  AuthState build() {
    ref.onDispose(() {
      _onlineRestoreTimer?.cancel();
      _onlineRestoreTimer = null;
    });
    // Résolution asynchrone lancée immédiatement ; l'UI reste sur `loading`.
    Future.microtask(initialize);
    return const AuthState(AuthStatus.loading);
  }

  Future<void> initialize() async {
    state = const AuthState(AuthStatus.loading);
    await _session.initialize();
    _session.onSessionExpired = _handleSessionExpired;

    if (!_session.hasSession) {
      await _resolveWithoutSession();
      return;
    }

    // Session stockée : verrou biométrique éventuel avant restauration.
    if (await _store.readBiometricEnabled() &&
        (await _biometrics.checkAvailability()).available) {
      state = const AuthState(AuthStatus.locked);
      return;
    }
    await _restoreSession();
  }

  /// Panne de communication (serveur arrêté, timeout, coupure) — jamais un
  /// refus d'authentification. Un statut HTTP 5xx compte aussi : le serveur
  /// n'a pas pu répondre normalement.
  static bool _isServerUnreachable(AuthApiException error) =>
      error.statusCode == null || error.statusCode! >= 500;

  Future<void> _resolveWithoutSession() async {
    try {
      final bootstrapRequired = await _api.bootstrapRequired();
      state = AuthState(
        bootstrapRequired
            ? AuthStatus.bootstrapRequired
            : AuthStatus.unauthenticated,
      );
    } on AuthApiException catch (error) {
      // Aucun compte n'a jamais réussi à se connecter sur cet appareil : pas
      // de mode hors connexion possible, on l'explique clairement.
      state = AuthState(
        AuthStatus.error,
        message: _isServerUnreachable(error)
            ? 'Serveur HomeSpotify inaccessible. Une première connexion en '
                  'ligne est nécessaire avant de pouvoir utiliser le mode '
                  'hors connexion sur cet appareil.'
            : error.message,
      );
    }
  }

  Future<void> _restoreSession() async {
    try {
      final user = await _api.me();
      logNetwork('session restaurée pour ${user.username}');
      _publishAuthenticated(user);
    } on AuthApiException catch (error) {
      if (error.statusCode == 401) {
        // Refus d'authentification CONFIRMÉ par le serveur (access token mort
        // et refresh impossible) : déconnexion propre, identité locale purgée.
        await _session.clearSession();
        await _store.clearLocalIdentity();
        await _resolveWithoutSession();
      } else if (_isServerUnreachable(error)) {
        await _enterOfflineModeOrError(error);
      } else {
        state = AuthState(AuthStatus.error, message: error.message);
      }
    }
  }

  /// Serveur injoignable avec une session locale : ouvre le mode hors
  /// connexion si une identité a déjà été mémorisée sur cet appareil.
  Future<void> _enterOfflineModeOrError(AuthApiException error) async {
    final user = await _readLocalIdentity();
    if (user == null || user.mustChangePassword) {
      state = AuthState(AuthStatus.error, message: error.message);
      return;
    }
    logNetwork('serveur injoignable : mode hors connexion pour ${user.username}');
    state = AuthState(AuthStatus.offline, user: user);
    _scheduleOnlineRestore();
    unawaited(_restorePlaybackSession(user.id));
  }

  Future<AuthUser?> _readLocalIdentity() async {
    try {
      final json = await _store.readLocalIdentityJson();
      if (json == null || json.isEmpty) return null;
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;
      return AuthUser.fromJson(decoded);
    } catch (error) {
      // Identité illisible : on la considère absente, jamais de crash au boot.
      logError('identité locale illisible', error: error);
      return null;
    }
  }

  void _scheduleOnlineRestore() {
    _onlineRestoreTimer?.cancel();
    _onlineRestoreTimer = Timer.periodic(
      _onlineRestoreInterval,
      (_) => unawaited(attemptOnlineRestore()),
    );
  }

  /// Tente de repasser en ligne depuis le mode hors connexion. Sans effet si
  /// l'état a changé entre-temps. Une panne persistante laisse l'état intact.
  Future<void> attemptOnlineRestore() async {
    if (state.status != AuthStatus.offline) {
      _onlineRestoreTimer?.cancel();
      _onlineRestoreTimer = null;
      return;
    }
    try {
      final user = await _api.me();
      _onlineRestoreTimer?.cancel();
      _onlineRestoreTimer = null;
      logNetwork('serveur de retour : reprise en ligne pour ${user.username}');
      _publishAuthenticated(user);
      // Les providers réseau peuvent porter des erreurs accumulées hors
      // connexion : repartir d'un état frais, sans fermer l'application.
      _invalidatePersonalProviders();
    } on AuthApiException catch (error) {
      if (error.statusCode == 401) {
        // Session réellement morte, confirmée par un serveur joignable.
        _onlineRestoreTimer?.cancel();
        _onlineRestoreTimer = null;
        await _completeExpiredSessionLogout();
      }
      // Toujours injoignable : on reste en mode hors connexion.
    }
  }

  void _publishAuthenticated(AuthUser user) {
    state = user.mustChangePassword
        ? AuthState(AuthStatus.passwordChangeRequired, user: user)
        : AuthState(AuthStatus.authenticated, user: user);
    if (!user.mustChangePassword) {
      // Identité minimale mémorisée pour les prochains démarrages hors
      // connexion — jamais de token dans cette écriture.
      unawaited(
        _store
            .saveLocalIdentityJson(jsonEncode(user.toJson()))
            .catchError((Object error) {
              logError('mémorisation identité locale échouée', error: error);
            }),
      );
      unawaited(_restorePlaybackSession(user.id));
    }
  }

  Future<void> _restorePlaybackSession(int userId) async {
    try {
      await ref.read(audioSessionRestoreProvider)(userId);
    } catch (error, stackTrace) {
      // Une file locale corrompue ou un serveur momentanément inaccessible ne
      // doit jamais empêcher la connexion à l'application.
      logError(
        'restauration de la file audio impossible',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  void _handleSessionExpired() {
    logNetwork('session expirée : déconnexion');
    state = const AuthState(AuthStatus.loading);
    unawaited(_completeExpiredSessionLogout());
  }

  Future<void> _completeExpiredSessionLogout() async {
    await _stopAndClearPlayback();
    await _session.clearSession();
    await _store.clearLocalIdentity();
    _invalidatePersonalProviders();
    state = const AuthState(AuthStatus.unauthenticated);
  }

  Future<void> retry() => initialize();

  Future<void> bootstrap({
    required String username,
    required String displayName,
    required String password,
    required String passwordConfirmation,
  }) async {
    await _runAuthAction(
      () => _api.bootstrap(
        username: username,
        displayName: displayName,
        password: password,
        passwordConfirmation: passwordConfirmation,
        deviceName: 'Android',
      ),
    );
  }

  Future<void> login({
    required String username,
    required String password,
  }) async {
    await _runAuthAction(
      () => _api.login(
        username: username,
        password: password,
        deviceName: 'Android',
      ),
    );
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
    required String newPasswordConfirmation,
  }) async {
    await _runAuthAction(
      () => _api.changePassword(
        currentPassword: currentPassword,
        newPassword: newPassword,
        newPasswordConfirmation: newPasswordConfirmation,
        deviceName: 'Android',
      ),
    );
  }

  Future<void> _runAuthAction(Future<AuthPayload> Function() action) async {
    if (state.busy) return;
    state = state.copyWith(busy: true, message: null);
    try {
      final payload = await action();
      await _session.storeSession(payload.tokens);
      // Le changement de token est publié avant le montage de LibraryScreen.
      // La transition d'arbre n'invalide ainsi aucun provider pendant son build.
      await Future<void>.delayed(Duration.zero);
      _publishAuthenticated(payload.user);
    } on AuthApiException catch (error) {
      state = state.copyWith(busy: false, message: error.message);
    } catch (error) {
      logError('action auth inattendue', error: error);
      state = state.copyWith(
        busy: false,
        message: AppConfig.serverUnreachableMessage,
      );
    }
  }

  Future<void> logout() async {
    // Démonte immédiatement l'application personnelle : aucun provider de
    // l'ancien compte ne peut repeindre pendant les opérations asynchrones.
    _onlineRestoreTimer?.cancel();
    _onlineRestoreTimer = null;
    state = const AuthState(AuthStatus.loading);
    final refreshToken = _session.refreshToken;
    try {
      if (refreshToken != null) {
        await _api.logout(refreshToken: refreshToken);
      }
    } catch (error, stackTrace) {
      // Une indisponibilité serveur ne doit jamais empêcher la purge locale.
      logError(
        'logout serveur échoué, purge locale maintenue',
        error: error,
        stackTrace: stackTrace,
      );
    }
    // Purge des données personnelles AVANT de couper la session : arrêt de la
    // lecture, file et MediaItem vidés, caches Riverpod invalidés. Aucune
    // donnée de l'ancien compte ne peut apparaître sous le compte suivant.
    await _stopAndClearPlayback();
    await _session.clearSession();
    // Logout explicite : l'identité locale disparaît aussi — le mode hors
    // connexion n'est plus possible tant qu'une connexion n'a pas réussi.
    await _store.clearLocalIdentity();
    _invalidatePersonalProviders();
    state = const AuthState(AuthStatus.unauthenticated);
  }

  Future<void> _stopAndClearPlayback() async {
    try {
      await ref.read(audioLogoutPurgeProvider)();
    } catch (error) {
      logError('purge lecteur au logout échouée', error: error);
    }
  }

  /// Appelé après suppression des tokens. Les providers ne peuvent donc pas
  /// recharger les données de l'ancien compte s'ils ont encore un listener.
  void _invalidatePersonalProviders() {
    ref.invalidate(libraryProvider);
    ref.invalidate(favoriteTrackIdsProvider);
    ref.invalidate(playlistsProvider);
    ref.invalidate(userLibrarySummaryProvider);
    // Découverte : coupe l'extrait en cours (dispose du lecteur) et purge le
    // paquet de cartes de l'ancien compte.
    ref.invalidate(discoveryPreviewProvider);
    ref.invalidate(discoverDeckProvider);
    // Catalogue global : les pistes sont communes, mais `inMyLibrary` est propre
    // au compte — jamais réutilisé pour le compte suivant.
    ref.invalidate(catalogRecentProvider);
    // Appartenance par piste : recalculée pour le nouveau compte (skibidi voit
    // « Supprimer », le OWNER « Ajouter » pour la même piste).
    ref.invalidate(trackMembershipProvider);
    // Recherche et demandes catalogue : aucune recherche ni marqueur de
    // demande du compte précédent ne survit à la rotation de session.
    ref.invalidate(catalogSearchProvider);
    ref.invalidate(catalogPreviewProvider);
    ref.invalidate(catalogRequestedKeysProvider);
    // Index hors ligne : reconstruit pour le compte courant (vide si aucun).
    // Les fichiers de l'ancien compte restent sur disque mais deviennent
    // immédiatement inaccessibles — aucun fallback vers un autre userId.
    ref.invalidate(offlineIndexProvider);
  }

  /// Déverrouillage biométrique depuis l'écran de verrouillage.
  Future<void> unlockWithBiometrics() async {
    if (state.status != AuthStatus.locked || state.busy) return;
    state = state.copyWith(busy: true, message: null);
    final result = await _biometrics.authenticateDetailed(
      localizedReason: 'Déverrouiller HomeSpotify',
    );
    if (!result.succeeded) {
      // Échec ou annulation : on reste verrouillé, sans crash ni logout.
      state = AuthState(AuthStatus.locked, message: result.userMessage);
      return;
    }
    state = const AuthState(AuthStatus.loading);
    await _restoreSession();
  }

  /// Retour volontaire à la connexion par mot de passe depuis le verrou :
  /// la session locale est abandonnée proprement.
  Future<void> usePasswordInstead() async {
    await logout();
  }

  /// Active/désactive le déverrouillage biométrique (Paramètres). L'activation
  /// exige une authentification biométrique immédiate réussie.
  Future<BiometricAuthenticationResult> setBiometricEnabled(
    bool enabled,
  ) async {
    if (!enabled) {
      await _store.saveBiometricEnabled(false);
      return const BiometricAuthenticationResult.success();
    }
    final availability = await _biometrics.checkAvailability();
    if (!availability.available) {
      return BiometricAuthenticationResult.failure(
        availability.failureReason ?? BiometricFailureReason.unavailable,
      );
    }
    final result = await _biometrics.authenticateDetailed(
      localizedReason:
          'Confirmez votre biométrie pour activer le déverrouillage HomeSpotify',
    );
    if (!result.succeeded) return result;
    await _store.saveBiometricEnabled(true);
    return const BiometricAuthenticationResult.success();
  }
}
