import 'dart:async';

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
import '../data/auth_session_manager.dart';
import '../data/biometric_service.dart';
import '../data/token_store.dart';
import '../domain/auth_user.dart';
import '../../node_fetch/application/node_fetch_controller.dart';
import '../../remote_search/application/remote_search_controller.dart';

/// États du flux d'authentification. L'application principale n'est montée
/// qu'en [authenticated] ; rien ne s'affiche avant résolution ([loading]).
enum AuthStatus {
  loading,
  bootstrapRequired,
  unauthenticated,
  passwordChangeRequired,
  locked, // session valide mais verrouillée derrière la biométrie
  authenticated,
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

  @override
  AuthState build() {
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

  Future<void> _resolveWithoutSession() async {
    try {
      final bootstrapRequired = await _api.bootstrapRequired();
      state = AuthState(
        bootstrapRequired
            ? AuthStatus.bootstrapRequired
            : AuthStatus.unauthenticated,
      );
    } on AuthApiException catch (error) {
      state = AuthState(AuthStatus.error, message: error.message);
    }
  }

  Future<void> _restoreSession() async {
    try {
      final user = await _api.me();
      logNetwork('session restaurée pour ${user.username}');
      _publishAuthenticated(user);
    } on AuthApiException catch (error) {
      if (error.statusCode == 401) {
        // Access token mort et refresh impossible : déconnexion propre.
        await _session.clearSession();
        await _resolveWithoutSession();
      } else {
        state = AuthState(AuthStatus.error, message: error.message);
      }
    }
  }

  void _publishAuthenticated(AuthUser user) {
    state = user.mustChangePassword
        ? AuthState(AuthStatus.passwordChangeRequired, user: user)
        : AuthState(AuthStatus.authenticated, user: user);
  }

  void _handleSessionExpired() {
    logNetwork('session expirée : déconnexion');
    state = const AuthState(AuthStatus.loading);
    unawaited(_completeExpiredSessionLogout());
  }

  Future<void> _completeExpiredSessionLogout() async {
    await _stopAndClearPlayback();
    await _session.clearSession();
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
    // Import distant : aucun identifiant de tâche ni nom de fichier de l'ancien
    // compte ne doit rester visible après une rotation de session.
    ref.invalidate(nodeFetchControllerProvider);
    ref.invalidate(remoteSearchControllerProvider);
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
