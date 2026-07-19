import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

void _traceArtwork(String message) {
  if (kDebugMode) debugPrint('[ARTWORK_TRACE] $message');
}

/// Cache privé destiné aux pochettes de notification Android.
///
/// Les widgets continuent d'utiliser le cache image Flutter avec un Bearer.
/// audio_service reçoit uniquement une URI file://, car il ne sait pas joindre
/// les en-têtes d'authentification à une URL distante.
class AuthenticatedArtworkCache {
  AuthenticatedArtworkCache(
    this._dio, {
    Future<Directory> Function()? cacheDirectory,
    this.ttl = const Duration(days: 7),
  }) : _cacheDirectory = cacheDirectory ?? getTemporaryDirectory;

  final Dio _dio;
  final Future<Directory> Function() _cacheDirectory;
  final Duration ttl;
  final Map<String, Future<Uri?>> _inFlight = <String, Future<Uri?>>{};

  Future<Uri?> resolve({
    required int userId,
    required int trackId,
    required Uri coverUri,
    String? coverIdentity,
  }) {
    final version = _safeIdentity(coverIdentity ?? coverUri.path);
    final key = '$userId:$trackId:$version';
    final existing = _inFlight[key];
    if (existing != null) {
      _traceArtwork(
        'B resolve trackId=$trackId triggered=yes dedupeKey=$key '
        'singleFlight=existing',
      );
      return existing;
    }
    _traceArtwork(
      'B resolve trackId=$trackId triggered=yes dedupeKey=$key '
      'singleFlight=new',
    );
    final resolution = _resolve(userId, trackId, coverUri, version)
        .whenComplete(() {
          _inFlight.remove(key);
        });
    _inFlight[key] = resolution;
    return resolution;
  }

  Future<Uri?> _resolve(
    int userId,
    int trackId,
    Uri coverUri,
    String version,
  ) async {
    if (coverUri.scheme != 'http' && coverUri.scheme != 'https') {
      _traceArtwork(
        'B resolve trackId=$trackId triggered=no reason=unsupported_scheme '
        'scheme=${coverUri.scheme}',
      );
      return null;
    }
    final directory = Directory(
      '${(await _cacheDirectory()).path}${Platform.pathSeparator}'
      'homespotify_artwork',
    );
    await directory.create(recursive: true);
    final stem = 'user_${userId}_track_${trackId}_$version';
    final cached = await _freshCachedFile(directory, stem);
    if (cached != null) {
      await _traceCachedFile(trackId, cached, existed: true);
      return cached.uri;
    }

    try {
      _traceArtwork('C request trackId=$trackId url=$coverUri');
      final response = await _dio.getUri<List<int>>(
        coverUri,
        options: Options(
          responseType: ResponseType.bytes,
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final mimeType = response.headers
          .value(Headers.contentTypeHeader)
          ?.split(';')
          .first
          .trim()
          .toLowerCase();
      final contentLength = response.headers.value(Headers.contentLengthHeader);
      final etag = response.headers.value('etag');
      _traceArtwork(
        'C response trackId=$trackId status=${response.statusCode} '
        'contentType=${mimeType ?? 'absent'} '
        'contentLength=${contentLength ?? 'absent'} etag=${etag ?? 'absent'}',
      );
      if (response.statusCode != 200 || response.data == null) return null;
      final extension = switch (mimeType) {
        'image/png' => 'png',
        'image/jpeg' || 'image/jpg' => 'jpg',
        _ => null,
      };
      if (extension == null || response.data!.isEmpty) {
        _traceArtwork(
          'C response trackId=$trackId error=invalid_image_payload '
          'bytes=${response.data?.length ?? 0}',
        );
        return null;
      }

      await _removeTrackFiles(directory, userId, trackId);
      final target = File(
        '${directory.path}${Platform.pathSeparator}$stem.$extension',
      );
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsBytes(response.data!, flush: true);
      await temporary.rename(target.path);
      await _traceCachedFile(trackId, target, existed: false);
      return target.uri;
    } on DioException catch (error) {
      _traceArtwork(
        'C request trackId=$trackId error=${error.type.name} '
        'status=${error.response?.statusCode ?? 'none'} message=${error.message}',
      );
      return null;
    } on FileSystemException catch (error) {
      _traceArtwork(
        'D cache trackId=$trackId error=${error.runtimeType} '
        'message=${error.message}',
      );
      return null;
    }
  }

  Future<void> _traceCachedFile(
    int trackId,
    File file, {
    required bool existed,
  }) async {
    final length = await file.length();
    final handle = await file.open();
    late final List<int> prefix;
    try {
      prefix = await handle.read(8);
    } finally {
      await handle.close();
    }
    final signature =
        prefix.length >= 4 &&
            prefix[0] == 0xff &&
            prefix[1] == 0xd8 &&
            prefix[2] == 0xff
        ? 'JPEG'
        : prefix.length >= 8 &&
              prefix[0] == 0x89 &&
              prefix[1] == 0x50 &&
              prefix[2] == 0x4e &&
              prefix[3] == 0x47
        ? 'PNG'
        : 'unknown';
    _traceArtwork(
      'D cache trackId=$trackId path=${file.absolute.path} created=${!existed} '
      'existing=$existed bytes=$length extension=${file.path.split('.').last} '
      'signature=$signature uri=${file.uri}',
    );
  }

  Future<File?> _freshCachedFile(Directory directory, String stem) async {
    for (final extension in const ['jpg', 'png']) {
      final file = File(
        '${directory.path}${Platform.pathSeparator}$stem.$extension',
      );
      if (!await file.exists()) continue;
      final modified = await file.lastModified();
      if (DateTime.now().difference(modified) <= ttl &&
          await file.length() > 0) {
        return file;
      }
      await file.delete().catchError((_) => file);
    }
    return null;
  }

  Future<void> _removeTrackFiles(
    Directory directory,
    int userId,
    int trackId,
  ) async {
    final prefix = 'user_${userId}_track_${trackId}_';
    await for (final entity in directory.list()) {
      if (entity is File && entity.uri.pathSegments.last.startsWith(prefix)) {
        await entity.delete().catchError((_) => entity);
      }
    }
  }

  String _safeIdentity(String value) {
    final normalized = value.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_');
    if (normalized.isEmpty) return 'cover';
    return normalized.substring(0, normalized.length.clamp(0, 48));
  }

  Future<void> clear() async {
    _inFlight.clear();
    final directory = Directory(
      '${(await _cacheDirectory()).path}${Platform.pathSeparator}'
      'homespotify_artwork',
    );
    if (await directory.exists()) {
      await directory.delete(recursive: true).catchError((_) => directory);
    }
  }
}
