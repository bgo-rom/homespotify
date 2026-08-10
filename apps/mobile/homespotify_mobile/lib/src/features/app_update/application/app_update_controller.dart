import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/logging/app_logger.dart';
import '../domain/app_update_models.dart';
import 'app_update_service.dart';

/// Intervalle minimal entre deux vérifications AUTOMATIQUES (démarrage et
/// retour au premier plan). Une vérification manuelle l'ignore.
const Duration kAutoUpdateCheckInterval = Duration(minutes: 30);

const String _lastAutoCheckKey = 'app_update.last_auto_check_ms';

/// Machine à états de la mise à jour de l'application.
///
/// RÈGLE ABSOLUE : aucune panne du service de mise à jour ne peut empêcher
/// HomeSpotify de fonctionner. Un serveur injoignable, un DNS mort, un JSON
/// invalide ou un délai dépassé se terminent en `upToDate`/`idle` silencieux
/// lors d'une vérification automatique — l'erreur n'est montrée que si
/// l'utilisateur a demandé lui-même la vérification.
class AppUpdateController extends Notifier<AppUpdateState> {
  CancelToken? _downloadCancel;
  Future<void>? _inFlight;

  AppUpdateService get _service => ref.read(appUpdateServiceProvider);

  @override
  AppUpdateState build() {
    // L'état survit au démontage de son observateur : la bascule
    // connexion → application principale remonte l'enveloppe, et un « Plus
    // tard » ou un téléchargement en cours ne doit pas être oublié à cette
    // occasion.
    ref.keepAlive();
    ref.onDispose(() => _downloadCancel?.cancel('dispose'));
    return const AppUpdateState();
  }

  /// Vérification automatique (démarrage, retour au premier plan). Respecte
  /// l'intervalle minimal et n'affiche jamais d'erreur.
  Future<void> checkAutomatically() async {
    // Une mise à jour déjà connue rend la revérification inutile : le serveur
    // a répondu, l'assistant attend l'utilisateur.
    if (state.busy || state.updatePending) return;
    if (!await _autoCheckAllowed()) return;
    await _check(manual: false);
  }

  /// Vérification demandée par l'utilisateur : ignore l'intervalle et affiche
  /// les erreurs.
  Future<void> checkManually() async {
    if (state.busy) return;
    await _check(manual: true);
  }

  Future<bool> _autoCheckAllowed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastAutoCheckKey);
      if (last == null) return true;
      final elapsed = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(last),
      );
      return elapsed >= kAutoUpdateCheckInterval;
    } catch (_) {
      // Préférences illisibles : on vérifie, plutôt que de ne jamais vérifier.
      return true;
    }
  }

  /// Mémorise l'instant de la DERNIÈRE vérification, manuelle comprise : une
  /// vérification automatique juste après une manuelle n'apprendrait rien.
  Future<void> _rememberCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _lastAutoCheckKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    } catch (_) {
      // Sans mémoire de la dernière vérification, on vérifiera plus souvent :
      // désagréable, jamais bloquant.
    }
  }

  Future<void> _check({required bool manual}) {
    final pending = _inFlight;
    if (pending != null) return pending;
    final future = _runCheck(manual: manual).whenComplete(() {
      _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  Future<void> _runCheck({required bool manual}) async {
    state = state.copyWith(
      phase: AppUpdatePhase.checking,
      clearMessage: true,
    );
    await _rememberCheck();

    final AppUpdateCheck result;
    try {
      result = await _service.check();
    } on AppUpdateException catch (error) {
      logError('vérification de mise à jour impossible: ${error.message}');
      state = state.copyWith(
        // Une mise à jour obligatoire déjà connue reste affichée : c'est le
        // seul cas où l'écran de mise à jour survit à une panne réseau.
        phase: state.mandatory ? AppUpdatePhase.available : AppUpdatePhase.idle,
        message: manual ? error.message : null,
        clearMessage: !manual,
      );
      return;
    } catch (error, stackTrace) {
      logError(
        'vérification de mise à jour : erreur inattendue',
        error: error,
        stackTrace: stackTrace,
      );
      state = state.copyWith(
        phase: state.mandatory ? AppUpdatePhase.available : AppUpdatePhase.idle,
        clearMessage: true,
      );
      return;
    }

    logNetwork(
      'update_check current=${result.current.versionCode} '
      'latest=${result.latest?.versionCode ?? '-'} '
      'available=${result.updateAvailable}',
    );

    if (!result.updateAvailable) {
      // Rien à installer : on nettoie tout résidu de téléchargement. Un échec
      // de nettoyage ne doit jamais transformer « à jour » en erreur.
      try {
        await _service.cleanUp();
      } catch (_) {
        // Reste non supprimable : sans conséquence sur la suite.
      }
      state = AppUpdateState(
        phase: AppUpdatePhase.upToDate,
        current: result.current,
        latest: result.latest,
        lastCheckedAt: DateTime.now(),
      );
      return;
    }

    state = state.copyWith(
      phase: AppUpdatePhase.available,
      current: result.current,
      latest: result.latest,
      mandatory: result.mandatory,
      receivedBytes: 0,
      totalBytes: result.latest!.sizeBytes,
      // Une nouvelle version annule un « Plus tard » portant sur l'ancienne.
      postponed:
          state.postponed && state.latest?.versionCode == result.latest!.versionCode,
      clearMessage: true,
      lastCheckedAt: DateTime.now(),
    );
  }

  /// « Plus tard » — indisponible sur une mise à jour obligatoire.
  void postpone() {
    if (state.mandatory) return;
    logUi('update_postponed version=${state.latest?.versionCode}');
    state = state.copyWith(postponed: true, phase: AppUpdatePhase.available);
  }

  /// Annule un téléchargement en cours (jamais sur une mise à jour obligatoire).
  void cancelDownload() {
    if (state.mandatory) return;
    _downloadCancel?.cancel('cancelled_by_user');
  }

  /// Télécharge, vérifie, puis demande l'installation à Android.
  Future<void> downloadAndInstall() async {
    final release = state.latest;
    if (release == null || state.busy) return;

    final cancelToken = CancelToken();
    _downloadCancel = cancelToken;
    state = state.copyWith(
      phase: AppUpdatePhase.downloading,
      receivedBytes: 0,
      totalBytes: release.sizeBytes,
      clearMessage: true,
    );
    logNetwork('update_download_started version=${release.versionCode}');

    final File file;
    try {
      file = await _service.download(
        release,
        cancelToken: cancelToken,
        onProgress: (received, total) {
          if (!ref.mounted) return;
          state = state.copyWith(receivedBytes: received, totalBytes: total);
        },
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) {
        state = state.copyWith(
          phase: AppUpdatePhase.available,
          receivedBytes: 0,
          clearMessage: true,
        );
        return;
      }
      _fail('Téléchargement interrompu. Réessaie.');
      return;
    } on AppUpdateException catch (error) {
      _fail(error.message);
      return;
    } on FileSystemException {
      _fail('Impossible d’écrire la mise à jour sur cet appareil.');
      return;
    } finally {
      _downloadCancel = null;
    }

    state = state.copyWith(phase: AppUpdatePhase.verifying);
    try {
      await _service.verify(file, release, current: state.current);
    } on AppUpdateException catch (error) {
      logError('update_verification_failed: ${error.message}');
      _fail(error.message);
      return;
    }
    logNetwork('update_download_verified version=${release.versionCode}');

    state = state.copyWith(phase: AppUpdatePhase.readyToInstall);
    await requestInstall();
  }

  /// Ouvre l'installateur Android pour l'APK déjà vérifiée.
  Future<void> requestInstall() async {
    final release = state.latest;
    if (release == null) return;
    final directory = await _service.updateDirectory();
    final file = _service.apkFile(directory, release.versionCode);
    if (!file.existsSync()) {
      _fail('La mise à jour téléchargée a disparu. Relance le téléchargement.');
      return;
    }

    final InstallRequestOutcome outcome;
    try {
      outcome = await _service.requestInstall(file);
    } catch (error) {
      logError('update_install_failed', error: error);
      _fail('L’installateur Android n’a pas pu être ouvert.');
      return;
    }

    if (outcome == InstallRequestOutcome.permissionRequired) {
      state = state.copyWith(
        phase: AppUpdatePhase.permissionRequired,
        clearMessage: true,
      );
      return;
    }
    logNetwork('update_install_requested version=${release.versionCode}');
    state = state.copyWith(
      phase: AppUpdatePhase.installing,
      clearMessage: true,
    );
  }

  /// Ouvre l'écran système d'autorisation, puis laisse l'utilisateur revenir.
  Future<void> openInstallSettings() async {
    logUi('update_permission_settings_opened');
    await _service.openInstallSettings();
  }

  /// Rappelé au retour au premier plan : si l'autorisation vient d'être
  /// accordée, on reprend l'installation là où elle s'était arrêtée.
  Future<void> handleAppResumed() async {
    if (state.phase == AppUpdatePhase.permissionRequired) {
      if (await _service.canRequestInstall()) {
        await requestInstall();
      }
      return;
    }
    if (state.phase == AppUpdatePhase.installing) {
      // L'utilisateur est revenu sans installer : l'APK reste prête.
      state = state.copyWith(phase: AppUpdatePhase.readyToInstall);
      return;
    }
    await checkAutomatically();
  }

  void _fail(String message) {
    state = state.copyWith(phase: AppUpdatePhase.error, message: message);
  }
}

final appUpdateControllerProvider =
    NotifierProvider<AppUpdateController, AppUpdateState>(
      AppUpdateController.new,
      name: 'appUpdate',
    );
