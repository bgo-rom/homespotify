import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/api_client.dart';
import '../domain/remote_download_models.dart';

/// Erreur présentable du téléchargement par lien.
///
/// [message] vient du backend quand il existe : les textes français y sont déjà
/// assainis. Aucun `stderr`, chemin serveur ou secret ne peut transiter ici.
class RemoteDownloadException implements Exception {
  const RemoteDownloadException(this.message, {this.code, this.statusCode});

  final String message;

  /// Code applicatif du backend (`bad_request`, `active_duplicate`,
  /// `job_not_found`, `feature_unavailable`, `not_retryable`, …).
  final String? code;

  /// `null` quand la requête n'a pas atteint le serveur.
  final int? statusCode;

  bool get isNetworkError => statusCode == null;

  /// Le moteur n'est pas configuré sur ce serveur : masquer l'entrée plutôt
  /// que signaler une panne.
  bool get isFeatureUnavailable => statusCode == 503;

  /// Ce lien est déjà en cours de téléchargement.
  bool get isDuplicate => statusCode == 409;

  /// Job inconnu, ou appartenant à un autre compte — le backend ne fait pas la
  /// différence, volontairement.
  bool get isNotFound => statusCode == 404;

  @override
  String toString() => 'RemoteDownloadException($statusCode/$code): $message';
}

abstract interface class RemoteDownloadRepository {
  /// Installation d'une piste : le backend résout SEUL les URL candidates puis
  /// crée le job. Aucune URL n'est jamais fournie par l'application.
  ///
  /// Quand l'appelant a sélectionné un résultat catalogue précis, il transmet
  /// son identité complète ([title], [artist], [album], [isrc],
  /// [durationSeconds]) : le backend cible alors exactement ce morceau au lieu
  /// de réinterpréter du texte brut.
  Future<RemoteDownloadSearchOutcome> searchAndDownload({
    required String query,
    String? title,
    String? artist,
    String? album,
    String? isrc,
    int? durationSeconds,
  });

  Future<RemoteDownload> createDownload(String url);
  Future<RemoteDownload> fetchDownload(String jobId);
  Future<List<RemoteDownload>> listDownloads({int limit = 20});
  Future<RemoteDownloadCancelResult> cancelDownload(String jobId);
  Future<RemoteDownload> retryDownload(String jobId);
  Future<RemoteDownloadHealth> fetchHealth();

  /// Suit un téléchargement jusqu'à son état terminal.
  ///
  /// L'implémentation réseau privilégie le flux SSE et bascule d'elle-même sur
  /// un sondage si le flux est indisponible : l'appelant n'a jamais à gérer les
  /// deux cas.
  Stream<RemoteDownload> watchDownload(String jobId);
}

/// Intervalle du sondage de repli. Assez réactif pour une barre de
/// progression, assez lent pour ne pas marteler un backend qui pilote déjà un
/// processus Python.
const Duration kRemoteDownloadPollInterval = Duration(milliseconds: 1500);

/// Accès backend `/api/downloads/*`.
///
/// Le Bearer HomeSpotify est porté par l'intercepteur du Dio partagé et ne sort
/// jamais vers un domaine externe : cette classe ne parle qu'au backend
/// HomeSpotify, jamais au moteur ni à un fournisseur.
class RemoteDownloadApi implements RemoteDownloadRepository {
  RemoteDownloadApi(this._dio, {Duration? pollInterval})
    : _pollInterval = pollInterval ?? kRemoteDownloadPollInterval;

  static const int maxListLimit = 100;

  final Dio _dio;
  final Duration _pollInterval;

  @override
  Future<RemoteDownloadSearchOutcome> searchAndDownload({
    required String query,
    String? title,
    String? artist,
    String? album,
    String? isrc,
    int? durationSeconds,
  }) async {
    final normalized = query.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.length < 2) {
      throw const RemoteDownloadException(
        'Saisis au moins deux caractères.',
      );
    }

    final data = await _request<Map<String, dynamic>>(
      () => _dio.post<Map<String, dynamic>>(
        '/api/downloads/search',
        // Les champs vides sont OMIS : un `title: ""` ferait croire au backend
        // à une sélection épinglée sans en avoir la précision.
        data: {
          'query': normalized,
          'title': ?_clean(title),
          'artist': ?_clean(artist),
          'album': ?_clean(album),
          'isrc': ?_clean(isrc),
          if (durationSeconds != null && durationSeconds > 0)
            'durationSeconds': durationSeconds,
        },
      ),
      // 202 = job créé ; 200 = choix à faire ou aucune correspondance.
      allowedStatuses: const {200, 202},
      fallbackMessage: 'La recherche a échoué.',
    );

    final options = (data['candidates'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RemoteDownloadTrackOption.fromJson)
        .toList(growable: false);

    return switch (data['resolution']) {
      'queued' => RemoteDownloadQueued(
        job: _downloadFrom(data['item']),
        track: RemoteDownloadTrackOption.fromJson(
          data['track'] as Map<String, dynamic>? ?? const {},
        ),
      ),
      'ambiguous' => RemoteDownloadAmbiguous(
        options: options,
        message: _asNonEmptyString(data['message']),
      ),
      _ => RemoteDownloadNoMatch(message: _asNonEmptyString(data['message'])),
    };
  }

  @override
  Future<RemoteDownload> createDownload(String url) async {
    final data = await _request<Map<String, dynamic>>(
      () => _dio.post<Map<String, dynamic>>(
        '/api/downloads',
        data: {'url': url},
      ),
      // La création répond 202 : le job est accepté, pas terminé.
      allowedStatuses: const {200, 202},
      fallbackMessage: 'Le téléchargement a été refusé.',
    );
    return _downloadFrom(data['item']);
  }

  @override
  Future<RemoteDownload> fetchDownload(String jobId) async {
    final data = await _request<Map<String, dynamic>>(
      () => _dio.get<Map<String, dynamic>>('/api/downloads/$jobId'),
      fallbackMessage: 'Téléchargement introuvable.',
    );
    return _downloadFrom(data['item']);
  }

  @override
  Future<List<RemoteDownload>> listDownloads({int limit = 20}) async {
    final data = await _request<Map<String, dynamic>>(
      () => _dio.get<Map<String, dynamic>>(
        '/api/downloads',
        queryParameters: {'limit': limit.clamp(1, maxListLimit)},
      ),
      fallbackMessage: 'Impossible de charger les téléchargements.',
    );
    return (data['items'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RemoteDownload.fromJson)
        .toList(growable: false);
  }

  @override
  Future<RemoteDownloadCancelResult> cancelDownload(String jobId) async {
    final data = await _request<Map<String, dynamic>>(
      () => _dio.delete<Map<String, dynamic>>('/api/downloads/$jobId'),
      // 200 = rien à annuler (déjà terminal), 202 = annulation enregistrée.
      allowedStatuses: const {200, 202},
      fallbackMessage: 'L’annulation a échoué.',
    );
    return RemoteDownloadCancelResult.fromJson(data);
  }

  @override
  Future<RemoteDownload> retryDownload(String jobId) async {
    final data = await _request<Map<String, dynamic>>(
      () => _dio.post<Map<String, dynamic>>('/api/downloads/$jobId/retry'),
      allowedStatuses: const {200, 202},
      fallbackMessage: 'La relance a échoué.',
    );
    return _downloadFrom(data['item']);
  }

  @override
  Future<RemoteDownloadHealth> fetchHealth() async {
    final data = await _request<Map<String, dynamic>>(
      () => _dio.get<Map<String, dynamic>>('/api/downloads/health'),
      fallbackMessage: 'Impossible de vérifier le moteur de téléchargement.',
    );
    return RemoteDownloadHealth.fromJson(data);
  }

  /// SSE d'abord, sondage en repli.
  ///
  /// Le flux se ferme de lui-même sur état terminal. Toute erreur du flux
  /// bascule silencieusement sur le sondage : l'utilisateur ne doit jamais
  /// perdre le suivi parce qu'un proxy coupe les connexions longues.
  @override
  Stream<RemoteDownload> watchDownload(String jobId) {
    late StreamController<RemoteDownload> controller;
    StreamSubscription<Uint8List>? subscription;
    Timer? pollTimer;
    var closed = false;
    var polling = false;

    Future<void> stop() async {
      closed = true;
      pollTimer?.cancel();
      pollTimer = null;
      await subscription?.cancel();
      subscription = null;
    }

    void emit(RemoteDownload job) {
      if (closed || controller.isClosed) return;
      controller.add(job);
      if (job.status.isTerminal) {
        unawaited(stop().then((_) => controller.close()));
      }
    }

    Future<void> pollOnce() async {
      if (closed || polling) return;
      polling = true;
      try {
        emit(await fetchDownload(jobId));
      } on RemoteDownloadException catch (error) {
        // Un job introuvable ne reviendra pas : inutile d'insister.
        if (error.isNotFound && !closed && !controller.isClosed) {
          await stop();
          controller.addError(error);
          await controller.close();
        }
        // Les autres erreurs sont transitoires : le prochain tick réessaiera.
      } finally {
        polling = false;
      }
    }

    void startPolling() {
      if (closed || pollTimer != null) return;
      unawaited(pollOnce());
      pollTimer = Timer.periodic(_pollInterval, (_) => unawaited(pollOnce()));
    }

    Future<void> startSse() async {
      Response<ResponseBody> response;
      try {
        response = await _dio.get<ResponseBody>(
          '/api/downloads/$jobId/events',
          options: Options(
            responseType: ResponseType.stream,
            headers: const {'Accept': 'text/event-stream'},
            // Un flux SSE reste ouvert : le délai de réception par défaut le
            // couperait au bout de 30 s.
            receiveTimeout: Duration.zero,
          ),
        );
      } catch (_) {
        startPolling();
        return;
      }

      final status = response.statusCode ?? 0;
      final body = response.data;
      if (status != 200 || body == null) {
        startPolling();
        return;
      }

      final parser = _SseParser();
      subscription = body.stream.listen(
        (chunk) {
          for (final event in parser.push(utf8.decode(chunk, allowMalformed: true))) {
            final item = event.data['item'];
            if (item is Map<String, dynamic>) {
              emit(RemoteDownload.fromJson(item));
            }
          }
        },
        onError: (_) {
          // Flux coupé : on ne perd pas le suivi, on repasse en sondage.
          subscription = null;
          startPolling();
        },
        onDone: () {
          subscription = null;
          // Fin de flux sans état terminal (proxy, veille) : sondage de repli.
          if (!closed && !controller.isClosed) startPolling();
        },
        cancelOnError: true,
      );
    }

    controller = StreamController<RemoteDownload>(
      onListen: () {
        // Premier état immédiat : l'écran ne reste jamais vide en attendant le
        // premier événement du flux.
        unawaited(pollOnce().then((_) {
          if (!closed) unawaited(startSse());
        }));
      },
      onCancel: stop,
    );
    return controller.stream;
  }

  RemoteDownload _downloadFrom(Object? value) {
    if (value is! Map<String, dynamic>) {
      throw const RemoteDownloadException(
        'Réponse inattendue du serveur (champ item manquant).',
      );
    }
    return RemoteDownload.fromJson(value);
  }

  /// Le Dio partagé utilise `validateStatus: status < 500` : les réponses 4xx
  /// arrivent SANS `DioException` et doivent être converties explicitement,
  /// tandis que les 5xx arrivent EN `DioException`. Les deux chemins doivent
  /// produire la même exception.
  Future<T> _request<T>(
    Future<Response<dynamic>> Function() send, {
    Set<int> allowedStatuses = const {200},
    required String fallbackMessage,
  }) async {
    Response<dynamic> response;
    try {
      response = await send();
    } on DioException catch (error) {
      final errorResponse = error.response;
      if (errorResponse == null) {
        throw RemoteDownloadException(_messageForDio(error, fallbackMessage));
      }
      throw _errorFor(errorResponse, fallbackMessage);
    }

    final status = response.statusCode ?? 0;
    final data = response.data;
    if (!allowedStatuses.contains(status)) {
      throw _errorFor(response, fallbackMessage);
    }
    if (data is! T) {
      throw RemoteDownloadException(fallbackMessage, statusCode: status);
    }
    return data;
  }

  RemoteDownloadException _errorFor(
    Response<dynamic> response,
    String fallbackMessage,
  ) {
    final data = response.data;
    return RemoteDownloadException(
      data is Map<String, dynamic>
          ? _asNonEmptyString(data['message']) ?? fallbackMessage
          : fallbackMessage,
      code: data is Map<String, dynamic>
          ? _asNonEmptyString(data['error'])
          : null,
      statusCode: response.statusCode ?? 0,
    );
  }

  String _messageForDio(DioException error, String fallbackMessage) {
    return switch (error.type) {
      DioExceptionType.connectionError ||
      DioExceptionType.connectionTimeout => AppConfig.serverUnreachableMessage,
      DioExceptionType.receiveTimeout || DioExceptionType.sendTimeout =>
        'Le serveur met trop de temps à répondre.',
      DioExceptionType.cancel => 'Requête annulée.',
      _ => fallbackMessage,
    };
  }

  /// Normalise un champ d'identité facultatif : `null` s'il est vide.
  static String? _clean(String? value) {
    if (value == null) return null;
    final trimmed = value.trim().replaceAll(RegExp(r'\s+'), ' ');
    return trimmed.isEmpty ? null : trimmed;
  }

  static String? _asNonEmptyString(Object? value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }
}

/// Événement SSE décodé.
class _SseEvent {
  const _SseEvent(this.name, this.data);
  final String name;
  final Map<String, dynamic> data;
}

/// Analyseur SSE minimal : `event:` / `data:`, bloc terminé par une ligne vide.
///
/// Les lignes de commentaire (`: ping`) et les champs inconnus sont ignorés.
/// Un `data:` illisible est ignoré sans casser le flux.
class _SseParser {
  final StringBuffer _buffer = StringBuffer();
  String _pending = '';

  /// Champ d'instance : un bloc SSE peut être coupé entre deux chunks réseau,
  /// le nom d'événement doit survivre à cette frontière.
  String _name = 'message';

  List<_SseEvent> push(String chunk) {
    _pending += chunk;
    final events = <_SseEvent>[];
    final lines = _pending.split('\n');
    _pending = lines.removeLast();

    for (final rawLine in lines) {
      final line = rawLine.endsWith('\r')
          ? rawLine.substring(0, rawLine.length - 1)
          : rawLine;

      if (line.isEmpty) {
        final payload = _buffer.toString();
        _buffer.clear();
        if (payload.isNotEmpty) {
          try {
            final decoded = jsonDecode(payload);
            if (decoded is Map<String, dynamic>) {
              events.add(_SseEvent(_name, decoded));
            }
          } catch (_) {
            // Charge utile illisible : ignorée proprement.
          }
        }
        _name = 'message';
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        _name = line.substring(6).trim();
        continue;
      }
      if (line.startsWith('data:')) {
        _buffer.write(line.substring(5).trimLeft());
      }
    }
    return events;
  }
}

final remoteDownloadApiProvider = Provider<RemoteDownloadRepository>((ref) {
  return RemoteDownloadApi(ref.watch(apiClientProvider));
});
