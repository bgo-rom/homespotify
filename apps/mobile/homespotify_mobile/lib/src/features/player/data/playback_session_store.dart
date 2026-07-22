import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const int playbackSessionSchemaVersion = 1;
const int maximumPersistedQueueLength = 1000;

class PersistedQueueItem {
  const PersistedQueueItem({
    required this.id,
    required this.streamUri,
    required this.title,
    this.userId,
    this.artist,
    this.album,
    this.artUri,
    this.durationMs,
    this.mimeType,
    this.extension,
    this.sampleRate,
    this.bitDepth,
    this.channels,
    this.bitrate,
    this.fileSize,
    this.origin = 'Bibliothèque',
    this.artistKey,
    this.albumKey,
    this.artworkIdentity,
  });

  final String id;
  final int? userId;
  final Uri streamUri;
  final String title;
  final String? artist;
  final String? album;
  final Uri? artUri;
  final int? durationMs;
  final String? mimeType;
  final String? extension;
  final int? sampleRate;
  final int? bitDepth;
  final int? channels;
  final int? bitrate;
  final int? fileSize;
  final String origin;
  final String? artistKey;
  final String? albumKey;
  final String? artworkIdentity;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'userId': userId,
    'streamUri': streamUri.toString(),
    'title': title,
    'artist': artist,
    'album': album,
    'artUri': artUri?.toString(),
    'durationMs': durationMs,
    'mimeType': mimeType,
    'extension': extension,
    'sampleRate': sampleRate,
    'bitDepth': bitDepth,
    'channels': channels,
    'bitrate': bitrate,
    'fileSize': fileSize,
    'origin': origin,
    'artistKey': artistKey,
    'albumKey': albumKey,
    'artworkIdentity': artworkIdentity,
  };

  static PersistedQueueItem? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, Object?>.from(raw);
    final id = _nonEmptyString(json['id']);
    final title = _nonEmptyString(json['title']);
    final streamUri = _networkUri(json['streamUri']);
    if (id == null || title == null || streamUri == null) return null;
    return PersistedQueueItem(
      id: id,
      userId: _positiveInt(json['userId']),
      streamUri: streamUri,
      title: title,
      artist: _optionalString(json['artist']),
      album: _optionalString(json['album']),
      artUri: _networkUri(json['artUri']),
      durationMs: _positiveInt(json['durationMs']),
      mimeType: _optionalString(json['mimeType']),
      extension: _optionalString(json['extension']),
      sampleRate: _positiveInt(json['sampleRate']),
      bitDepth: _positiveInt(json['bitDepth']),
      channels: _positiveInt(json['channels']),
      bitrate: _positiveInt(json['bitrate']),
      fileSize: _positiveInt(json['fileSize']),
      origin: _nonEmptyString(json['origin']) ?? 'Bibliothèque',
      artistKey: _optionalString(json['artistKey']),
      albumKey: _optionalString(json['albumKey']),
      artworkIdentity: _optionalString(json['artworkIdentity']),
    );
  }
}

class PersistedPlaybackSession {
  PersistedPlaybackSession({
    required this.userId,
    required List<PersistedQueueItem> queue,
    required this.currentIndex,
    required this.positionMs,
    required this.repeatMode,
    required this.shuffleEnabled,
    required this.speedRatio,
    required this.wasPlaying,
    required this.updatedAt,
  }) : queue = List<PersistedQueueItem>.unmodifiable(queue) {
    if (userId <= 0) throw ArgumentError.value(userId, 'userId');
    if (queue.isEmpty || queue.length > maximumPersistedQueueLength) {
      throw ArgumentError.value(queue.length, 'queue.length');
    }
    if (currentIndex < 0 || currentIndex >= queue.length) {
      throw RangeError.index(currentIndex, queue, 'currentIndex');
    }
    if (positionMs < 0) throw ArgumentError.value(positionMs, 'positionMs');
    if (!speedRatio.isFinite || speedRatio < 0.7 || speedRatio > 1.3) {
      throw ArgumentError.value(speedRatio, 'speedRatio');
    }
  }

  final int userId;
  final List<PersistedQueueItem> queue;
  final int currentIndex;
  final int positionMs;
  final String repeatMode;
  final bool shuffleEnabled;
  final double speedRatio;
  final bool wasPlaying;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': playbackSessionSchemaVersion,
    'userId': userId,
    'queue': queue.map((item) => item.toJson()).toList(growable: false),
    'currentIndex': currentIndex,
    'positionMs': positionMs,
    'repeatMode': repeatMode,
    'shuffleEnabled': shuffleEnabled,
    'speedRatio': speedRatio,
    'wasPlaying': wasPlaying,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };

  static PersistedPlaybackSession? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = Map<String, Object?>.from(raw);
    if (json['schemaVersion'] != playbackSessionSchemaVersion) return null;
    final userId = _positiveInt(json['userId']);
    final queueRaw = json['queue'];
    final currentIndex = _nonNegativeInt(json['currentIndex']);
    final positionMs = _nonNegativeInt(json['positionMs']);
    final speedRatio = (json['speedRatio'] as num?)?.toDouble();
    final updatedAt = DateTime.tryParse(json['updatedAt']?.toString() ?? '');
    if (userId == null ||
        queueRaw is! List ||
        queueRaw.isEmpty ||
        queueRaw.length > maximumPersistedQueueLength ||
        currentIndex == null ||
        positionMs == null ||
        speedRatio == null ||
        !speedRatio.isFinite ||
        speedRatio < 0.7 ||
        speedRatio > 1.3 ||
        updatedAt == null ||
        json['shuffleEnabled'] is! bool ||
        json['wasPlaying'] is! bool) {
      return null;
    }
    final queue = <PersistedQueueItem>[];
    for (final itemRaw in queueRaw) {
      final item = PersistedQueueItem.fromJson(itemRaw);
      if (item == null || (item.userId != null && item.userId != userId)) {
        return null;
      }
      queue.add(item);
    }
    if (currentIndex >= queue.length) return null;
    final repeatMode = switch (json['repeatMode']) {
      'one' => 'one',
      'all' => 'all',
      _ => 'none',
    };
    return PersistedPlaybackSession(
      userId: userId,
      queue: queue,
      currentIndex: currentIndex,
      positionMs: positionMs,
      repeatMode: repeatMode,
      shuffleEnabled: json['shuffleEnabled'] as bool,
      speedRatio: speedRatio,
      wasPlaying: json['wasPlaying'] as bool,
      updatedAt: updatedAt.toUtc(),
    );
  }
}

abstract interface class PlaybackSessionStore {
  Future<PersistedPlaybackSession?> read(int userId);

  Future<void> write(PersistedPlaybackSession session);

  Future<void> delete(int userId);
}

class SharedPreferencesPlaybackSessionStore implements PlaybackSessionStore {
  SharedPreferencesPlaybackSessionStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  static const _keyPrefix = 'homespotify.playback-session.v1.';

  final SharedPreferencesAsync _preferences;

  String _key(int userId) => '$_keyPrefix$userId';

  @override
  Future<PersistedPlaybackSession?> read(int userId) async {
    if (userId <= 0) return null;
    final encoded = await _preferences.getString(_key(userId));
    if (encoded == null || encoded.isEmpty) return null;
    try {
      final session = PersistedPlaybackSession.fromJson(jsonDecode(encoded));
      if (session == null || session.userId != userId) {
        await delete(userId);
        return null;
      }
      return session;
    } catch (_) {
      await delete(userId);
      return null;
    }
  }

  @override
  Future<void> write(PersistedPlaybackSession session) {
    return _preferences.setString(
      _key(session.userId),
      jsonEncode(session.toJson()),
    );
  }

  @override
  Future<void> delete(int userId) async {
    if (userId <= 0) return;
    await _preferences.remove(_key(userId));
  }
}

String? _nonEmptyString(Object? raw) {
  final value = raw?.toString().trim();
  return value == null || value.isEmpty ? null : value;
}

String? _optionalString(Object? raw) => _nonEmptyString(raw);

int? _positiveInt(Object? raw) {
  final value = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  return value != null && value > 0 ? value : null;
}

int? _nonNegativeInt(Object? raw) {
  final value = raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '');
  return value != null && value >= 0 ? value : null;
}

Uri? _networkUri(Object? raw) {
  final value = _nonEmptyString(raw);
  if (value == null) return null;
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority) return null;
  return uri.scheme == 'https' || uri.scheme == 'http' ? uri : null;
}
