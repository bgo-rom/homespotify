import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:homespotify_mobile/src/core/platform/app_update_installer.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_storage_policy.dart';

/// Réponse programmée du serveur de mise à jour.
class FakeUpdateResponse {
  FakeUpdateResponse.json(this.statusCode, Object? body)
    : bytes = Uint8List.fromList(utf8.encode(jsonEncode(body))),
      headers = const {
        Headers.contentTypeHeader: ['application/json'],
      },
      failure = null,
      failAfterBytes = null;

  FakeUpdateResponse.rawJson(this.statusCode, String body)
    : bytes = Uint8List.fromList(utf8.encode(body)),
      headers = const {
        Headers.contentTypeHeader: ['application/json'],
      },
      failure = null,
      failAfterBytes = null;

  FakeUpdateResponse.binary(
    this.statusCode,
    this.bytes, {
    this.headers = const {},
    this.failAfterBytes,
  }) : failure = null;

  FakeUpdateResponse.networkFailure(this.failure)
    : statusCode = 0,
      bytes = Uint8List(0),
      headers = const {},
      failAfterBytes = null;

  final int statusCode;
  final Uint8List bytes;
  final Map<String, List<String>> headers;

  /// Erreur levée AVANT toute réponse (DNS, timeout de connexion…).
  final DioException? failure;

  /// Coupure réseau après N octets envoyés (interruption en cours de copie).
  final int? failAfterBytes;
}

/// Adaptateur Dio piloté par les tests : aucun socket réel n'est ouvert.
class FakeUpdateAdapter implements HttpClientAdapter {
  FakeUpdateAdapter();

  /// Réponses par chemin. Une liste est consommée dans l'ordre ; la dernière
  /// valeur est réutilisée une fois la liste épuisée.
  final Map<String, List<FakeUpdateResponse>> responses = {};

  /// Requêtes reçues, dans l'ordre — pour vérifier l'en-tête Range et le
  /// nombre d'appels (throttling).
  final List<RequestOptions> requests = [];

  void enqueue(String path, FakeUpdateResponse response) {
    responses.putIfAbsent(path, () => []).add(response);
  }

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final queue = responses[options.path];
    if (queue == null || queue.isEmpty) {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'aucune réponse programmée pour ${options.path}',
      );
    }
    final response = queue.length > 1 ? queue.removeAt(0) : queue.first;

    final failure = response.failure;
    if (failure != null) throw failure;

    final cut = response.failAfterBytes;
    if (cut == null) {
      return ResponseBody.fromBytes(
        response.bytes,
        response.statusCode,
        headers: response.headers,
      );
    }
    return ResponseBody(
      _truncatedStream(options, response.bytes, cut),
      response.statusCode,
      headers: response.headers,
    );
  }

  static Stream<Uint8List> _truncatedStream(
    RequestOptions options,
    Uint8List bytes,
    int cut,
  ) async* {
    yield Uint8List.sublistView(bytes, 0, cut.clamp(0, bytes.length));
    throw DioException.receiveTimeout(
      timeout: const Duration(seconds: 1),
      requestOptions: options,
    );
  }
}

/// Installateur Android simulé — aucun appel de plateforme.
class FakeAppUpdateInstaller implements AppUpdateInstaller {
  FakeAppUpdateInstaller({
    this.installAllowed = true,
    this.identityBuilder,
  });

  bool installAllowed;
  ApkIdentity? Function(String path)? identityBuilder;

  int installCalls = 0;
  int settingsCalls = 0;
  String? lastInstalledPath;

  @override
  Future<bool> canRequestInstall() async => installAllowed;

  @override
  Future<bool> openInstallSettings() async {
    settingsCalls += 1;
    return true;
  }

  @override
  Future<ApkIdentity?> inspectApk(String path) async =>
      identityBuilder?.call(path);

  @override
  Future<void> installApk(String path) async {
    installCalls += 1;
    lastInstalledPath = path;
  }
}

class FakeStoragePlatform implements OfflineStoragePlatform {
  FakeStoragePlatform([this.free = 8 * 1024 * 1024 * 1024]);

  int? free;

  @override
  Future<int?> freeBytes() async => free;
}

/// Fournisseur de dossier de cache pour les tests.
Future<Directory> Function() fixedCacheDir(Directory directory) =>
    () async => directory;
