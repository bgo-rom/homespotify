import 'package:flutter/foundation.dart';

/// Version installée, lue depuis les métadonnées réelles du paquet Android.
@immutable
class InstalledAppVersion {
  const InstalledAppVersion({
    required this.packageName,
    required this.versionName,
    required this.versionCode,
  });

  final String packageName;
  final String versionName;
  final int versionCode;

  String get display => '$versionName ($versionCode)';
}

/// Manifeste d'une release publiée, tel que servi par le backend.
///
/// Le parsing est TOLÉRANT À L'ÉCHEC mais jamais approximatif : un champ
/// manquant ou d'un type inattendu renvoie `null`, et l'appelant traite ce cas
/// comme « aucune mise à jour connue ». Une réponse malformée ne doit jamais
/// devenir une exception qui remonte jusqu'au démarrage de l'application.
@immutable
class AndroidRelease {
  const AndroidRelease({
    required this.packageName,
    required this.versionCode,
    required this.versionName,
    required this.required,
    required this.minSupportedVersionCode,
    required this.sizeBytes,
    required this.sha256,
    required this.signingCertSha256,
    required this.releaseNotes,
    required this.publishedAt,
    required this.downloadPath,
  });

  final String packageName;
  final int versionCode;
  final String versionName;
  final bool required;
  final int minSupportedVersionCode;
  final int sizeBytes;
  final String sha256;
  final String signingCertSha256;
  final List<String> releaseNotes;
  final DateTime? publishedAt;
  final String downloadPath;

  String get display => '$versionName ($versionCode)';

  static AndroidRelease? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.map((key, value) => MapEntry(key.toString(), value));

    final packageName = map['packageName'];
    final versionCode = map['versionCode'];
    final versionName = map['versionName'];
    final sizeBytes = map['sizeBytes'];
    final sha256 = map['sha256'];
    final signingCertSha256 = map['signingCertSha256'];
    final downloadPath = map['downloadPath'];
    if (packageName is! String ||
        packageName.isEmpty ||
        versionCode is! int ||
        versionCode < 1 ||
        versionName is! String ||
        versionName.isEmpty ||
        sizeBytes is! int ||
        sizeBytes <= 0 ||
        sha256 is! String ||
        !_isSha256(sha256) ||
        signingCertSha256 is! String ||
        !_isSha256(signingCertSha256) ||
        downloadPath is! String ||
        !downloadPath.startsWith('/api/app-update/android/download/')) {
      return null;
    }

    final minSupported = map['minSupportedVersionCode'];
    final notes = map['releaseNotes'];
    final publishedAt = map['publishedAt'];

    return AndroidRelease(
      packageName: packageName,
      versionCode: versionCode,
      versionName: versionName,
      required: map['required'] == true,
      minSupportedVersionCode: minSupported is int && minSupported >= 1
          ? minSupported
          : 1,
      sizeBytes: sizeBytes,
      sha256: sha256.toLowerCase(),
      signingCertSha256: signingCertSha256.toLowerCase(),
      releaseNotes: notes is List
          ? notes.whereType<String>().where((note) => note.isNotEmpty).toList()
          : const <String>[],
      publishedAt: publishedAt is String ? DateTime.tryParse(publishedAt) : null,
      downloadPath: downloadPath,
    );
  }

  static bool _isSha256(String value) =>
      RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value);
}

/// Résultat d'une vérification, déjà tranché côté client.
@immutable
class AppUpdateCheck {
  const AppUpdateCheck({
    required this.current,
    required this.latest,
  });

  final InstalledAppVersion current;
  final AndroidRelease? latest;

  bool get updateAvailable =>
      latest != null && latest!.versionCode > current.versionCode;

  /// Mise à jour imposée : demandée explicitement par la release, ou version
  /// installée tombée sous le plancher supporté.
  bool get mandatory {
    final release = latest;
    if (release == null || release.versionCode <= current.versionCode) {
      return false;
    }
    return release.required ||
        current.versionCode < release.minSupportedVersionCode;
  }
}

/// États de l'assistant de mise à jour. Un seul état à la fois — jamais une
/// combinaison de booléens.
enum AppUpdatePhase {
  idle,
  checking,
  upToDate,
  available,
  downloading,
  verifying,
  readyToInstall,
  permissionRequired,
  installing,
  error,
}

@immutable
class AppUpdateState {
  const AppUpdateState({
    this.phase = AppUpdatePhase.idle,
    this.current,
    this.latest,
    this.mandatory = false,
    this.receivedBytes = 0,
    this.totalBytes = 0,
    this.message,
    this.postponed = false,
    this.lastCheckedAt,
  });

  final AppUpdatePhase phase;
  final InstalledAppVersion? current;
  final AndroidRelease? latest;
  final bool mandatory;
  final int receivedBytes;
  final int totalBytes;

  /// Message présentable ; jamais une trace technique brute.
  final String? message;

  /// « Plus tard » : l'utilisateur a écarté cette version pour cette session.
  final bool postponed;
  final DateTime? lastCheckedAt;

  double? get progress =>
      totalBytes > 0 ? (receivedBytes / totalBytes).clamp(0.0, 1.0) : null;

  bool get busy =>
      phase == AppUpdatePhase.checking ||
      phase == AppUpdatePhase.downloading ||
      phase == AppUpdatePhase.verifying ||
      phase == AppUpdatePhase.installing;

  /// Une mise à jour est connue et attend une action — y compris quand elle a
  /// été remise à plus tard. Tant que c'est vrai, revérifier n'apprendrait
  /// rien : le serveur a déjà répondu.
  bool get updatePending =>
      latest != null &&
      phase != AppUpdatePhase.idle &&
      phase != AppUpdatePhase.checking &&
      phase != AppUpdatePhase.upToDate;

  /// L'assistant doit-il s'imposer à l'écran ?
  bool get shouldPrompt => updatePending && (mandatory || !postponed);

  AppUpdateState copyWith({
    AppUpdatePhase? phase,
    InstalledAppVersion? current,
    AndroidRelease? latest,
    bool clearLatest = false,
    bool? mandatory,
    int? receivedBytes,
    int? totalBytes,
    String? message,
    bool clearMessage = false,
    bool? postponed,
    DateTime? lastCheckedAt,
  }) {
    return AppUpdateState(
      phase: phase ?? this.phase,
      current: current ?? this.current,
      latest: clearLatest ? null : (latest ?? this.latest),
      mandatory: mandatory ?? this.mandatory,
      receivedBytes: receivedBytes ?? this.receivedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      message: clearMessage ? null : (message ?? this.message),
      postponed: postponed ?? this.postponed,
      lastCheckedAt: lastCheckedAt ?? this.lastCheckedAt,
    );
  }
}

/// Erreur de mise à jour présentable. `canRetry` guide l'UI.
class AppUpdateException implements Exception {
  AppUpdateException(this.message, {this.canRetry = true});

  final String message;
  final bool canRetry;

  @override
  String toString() => message;
}
