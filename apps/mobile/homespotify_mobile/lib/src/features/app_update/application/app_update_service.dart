import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../core/platform/app_package_info.dart';
import '../../../core/platform/app_update_installer.dart';
import '../../offline/application/offline_storage_policy.dart';
import '../data/app_update_api.dart';
import '../domain/app_update_models.dart';

/// Résultat d'une demande d'installation.
enum InstallRequestOutcome {
  /// L'installateur Android est ouvert : c'est lui qui décide désormais.
  installerOpened,

  /// HomeSpotify n'est pas encore autorisé comme source d'installation.
  permissionRequired,
}

/// Cœur de la mise à jour automatique privée : vérifier, télécharger,
/// vérifier l'APK, puis DEMANDER l'installation à Android.
///
/// Aucune protection Android n'est contournée : la dernière étape est toujours
/// l'installateur du système, avec sa propre confirmation.
class AppUpdateService {
  AppUpdateService({
    required AppUpdateApi api,
    required AppUpdateInstaller installer,
    required OfflineStoragePlatform storage,
    Future<InstalledAppVersion> Function()? currentVersionReader,
    Future<Directory> Function()? cacheDirProvider,
  }) : _api = api,
       _installer = installer,
       _storage = storage,
       // Injectables pour les tests : aucun appel de plateforme réel n'est
       // alors nécessaire.
       _currentVersionReader = currentVersionReader ?? _readInstalledVersion,
       _cacheDirProvider = cacheDirProvider ?? getTemporaryDirectory;

  final AppUpdateApi _api;
  final AppUpdateInstaller _installer;
  final OfflineStoragePlatform _storage;
  final Future<InstalledAppVersion> Function() _currentVersionReader;
  final Future<Directory> Function() _cacheDirProvider;

  /// Sous-dossier PRIVÉ du cache — jamais le stockage public.
  static const String updateDirName = 'app-updates';

  /// Marge exigée au-delà de la taille de l'APK : l'installateur Android a lui
  /// aussi besoin de place, et un disque plein en fin de copie est un échec
  /// coûteux.
  static const int _freeSpaceMarginBytes = 64 * 1024 * 1024;

  static Future<InstalledAppVersion> _readInstalledVersion() async {
    final info = await AppPackageInfo.fromPlatform();
    final versionCode = info.versionCode;
    if (versionCode == null) {
      throw AppUpdateException(
        'Version installée illisible.',
        canRetry: false,
      );
    }
    return InstalledAppVersion(
      packageName: info.packageName,
      versionName: info.version,
      versionCode: versionCode,
    );
  }

  Future<Directory> updateDirectory() async {
    final cache = await _cacheDirProvider();
    return Directory('${cache.path}/$updateDirName').create(recursive: true);
  }

  File apkFile(Directory directory, int versionCode) =>
      File('${directory.path}/homespotify-$versionCode.apk');

  /// Compare la version INSTALLÉE (métadonnées réelles du paquet) à la version
  /// publiée. Lève [AppUpdateException] si le serveur est injoignable.
  Future<AppUpdateCheck> check() async {
    final current = await _currentVersionReader();
    final latest = await _api.fetchLatest(
      currentVersionCode: current.versionCode,
    );
    return AppUpdateCheck(current: current, latest: latest);
  }

  /// Télécharge l'APK dans le cache privé, avec reprise et progression.
  ///
  /// Le fichier final n'apparaît qu'une fois COMPLET : tant que la copie est en
  /// cours, seul un `.part` existe.
  Future<File> download(
    AndroidRelease release, {
    void Function(int receivedBytes, int totalBytes)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final directory = await updateDirectory();
    await cleanUp(directory: directory, keepVersionCode: release.versionCode);

    final target = apkFile(directory, release.versionCode);
    final part = File('${target.path}.part');

    // Une copie complète et déjà vérifiée est réutilisée telle quelle.
    if (target.existsSync() && target.lengthSync() == release.sizeBytes) {
      onProgress?.call(release.sizeBytes, release.sizeBytes);
      return target;
    }

    await _requireFreeSpace(release.sizeBytes);

    var fromByte = part.existsSync() ? part.lengthSync() : 0;
    if (fromByte >= release.sizeBytes) {
      // Reste d'une tentative incohérente : on repart proprement de zéro.
      part.deleteSync();
      fromByte = 0;
    }

    final response = await _api.openDownloadStream(
      release.downloadPath,
      fromByte: fromByte,
      cancelToken: cancelToken,
    );
    final status = response.statusCode ?? 0;
    if (status == 404) {
      throw AppUpdateException(
        'Cette version n’est plus publiée sur le serveur.',
        canRetry: false,
      );
    }
    if (status == 416) {
      if (part.existsSync()) part.deleteSync();
      throw AppUpdateException('Reprise impossible. Relance le téléchargement.');
    }
    if (status != 200 && status != 206) {
      throw AppUpdateException('Le serveur a répondu $status.');
    }

    var offset = fromByte;
    if (status == 200 && fromByte > 0) {
      // Le serveur a ignoré la reprise et renvoie tout : on repart de zéro.
      if (part.existsSync()) part.deleteSync();
      offset = 0;
    }

    final body = response.data;
    if (body == null) {
      throw AppUpdateException('Réponse de téléchargement vide.');
    }

    final sink = part.openWrite(
      mode: offset > 0 ? FileMode.append : FileMode.write,
    );
    var received = offset;
    try {
      await for (final chunk in body.stream) {
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, release.sizeBytes);
      }
      await sink.flush();
    } finally {
      // Interruption réseau ou annulation : le `.part` est CONSERVÉ tel quel,
      // la reprise repartira exactement de là où elle s'est arrêtée.
      await sink.close();
    }

    if (received != release.sizeBytes) {
      // Copie tronquée : inutilisable, et une reprise partirait d'un état faux.
      if (part.existsSync()) part.deleteSync();
      throw AppUpdateException(
        'Téléchargement incomplet ($received octets sur ${release.sizeBytes}).',
      );
    }

    if (target.existsSync()) target.deleteSync();
    part.renameSync(target.path);
    return target;
  }

  /// Refuse toute APK qui n'est pas EXACTEMENT la mise à jour attendue.
  ///
  /// Taille, SHA-256, puis identité lue dans l'archive elle-même : nom de
  /// paquet, versionCode et certificat de signature. Un seul écart supprime le
  /// fichier — l'installateur n'est jamais ouvert.
  Future<void> verify(
    File file,
    AndroidRelease release, {
    InstalledAppVersion? current,
  }) async {
    Future<Never> reject(String message) async {
      if (file.existsSync()) file.deleteSync();
      throw AppUpdateException(message, canRetry: true);
    }

    if (!file.existsSync()) {
      throw AppUpdateException('Fichier de mise à jour introuvable.');
    }
    if (file.lengthSync() != release.sizeBytes) {
      await reject('Taille inattendue : mise à jour rejetée.');
    }

    final digest = await sha256.bind(file.openRead()).first;
    if (digest.toString().toLowerCase() != release.sha256) {
      await reject('Empreinte SHA-256 invalide : mise à jour rejetée.');
    }

    final identity = await _installer.inspectApk(file.path);
    if (identity == null) {
      await reject('Archive illisible : mise à jour rejetée.');
    }
    if (identity.packageName != release.packageName) {
      await reject('Application inattendue : mise à jour rejetée.');
    }
    if (identity.versionCode != release.versionCode) {
      await reject('Version inattendue : mise à jour rejetée.');
    }
    if (!identity.signingCertSha256.contains(release.signingCertSha256)) {
      // Signature différente : Android refuserait l'installation par-dessus.
      // Autant le dire ici, clairement, plutôt qu'à l'écran système.
      await reject('Signature inattendue : mise à jour rejetée.');
    }
    final installed = current;
    if (installed != null && identity.versionCode <= installed.versionCode) {
      await reject('Version non supérieure à celle installée : rejetée.');
    }
  }

  /// Demande l'installation à Android, après vérification de l'autorisation.
  Future<InstallRequestOutcome> requestInstall(File file) async {
    if (!await _installer.canRequestInstall()) {
      return InstallRequestOutcome.permissionRequired;
    }
    await _installer.installApk(file.path);
    return InstallRequestOutcome.installerOpened;
  }

  /// Ouvre l'écran système « Installer des applications inconnues ».
  Future<bool> openInstallSettings() => _installer.openInstallSettings();

  Future<bool> canRequestInstall() => _installer.canRequestInstall();

  /// Supprime tout fichier de mise à jour qui n'est pas celui attendu :
  /// anciennes APK et `.part` abandonnés.
  Future<void> cleanUp({Directory? directory, int? keepVersionCode}) async {
    final dir = directory ?? await updateDirectory();
    if (!dir.existsSync()) return;
    // Comparaison sur le NOM, jamais sur le chemin complet : le séparateur
    // rendu par `listSync()` n'est pas toujours celui utilisé pour construire
    // le chemin, et un chemin qui ne correspond pas ferait supprimer le
    // fichier qu'on voulait garder.
    final keepApk = keepVersionCode == null
        ? null
        : _fileName(apkFile(dir, keepVersionCode).path);
    final keepPart = keepApk == null ? null : '$keepApk.part';
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = _fileName(entity.path);
      if (name == keepApk || name == keepPart) continue;
      try {
        entity.deleteSync();
      } on FileSystemException {
        // Un reste non supprimable ne doit pas faire échouer la mise à jour.
      }
    }
  }

  static String _fileName(String path) =>
      path.split(RegExp(r'[/\\]')).last;

  Future<void> _requireFreeSpace(int sizeBytes) async {
    final free = await _storage.freeBytes();
    if (free == null) return;
    if (free < sizeBytes + _freeSpaceMarginBytes) {
      throw AppUpdateException(
        'Espace de stockage insuffisant pour installer la mise à jour.',
        canRetry: false,
      );
    }
  }
}

final appUpdateInstallerProvider = Provider<AppUpdateInstaller>(
  (ref) => const AndroidAppUpdateInstaller(),
);

final appUpdateServiceProvider = Provider<AppUpdateService>((ref) {
  return AppUpdateService(
    api: ref.watch(appUpdateApiProvider),
    installer: ref.watch(appUpdateInstallerProvider),
    storage: ref.watch(offlineStoragePlatformProvider),
  );
});
