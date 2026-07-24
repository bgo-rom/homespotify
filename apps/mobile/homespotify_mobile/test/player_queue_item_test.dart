import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playback_controller.dart';
import 'package:homespotify_mobile/src/features/offline/application/offline_source_resolver.dart';
import 'package:homespotify_mobile/src/features/offline/domain/offline_models.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';

void main() {
  test('PlayerQueueItem conserve les métadonnées du flux natif', () {
    final item = PlayerQueueItem(
      id: '42',
      streamUri: Uri.parse('http://example.test/api/tracks/42/stream'),
      title: 'Genesis',
      artist: 'Justice',
      album: 'Cross',
      duration: Duration(minutes: 3, seconds: 20),
      mimeType: 'audio/flac',
      extension: '.flac',
      sampleRate: 96000,
      bitDepth: 24,
      channels: 2,
      fileSize: 52428800,
    );

    final mediaItem = item.toMediaItem();

    expect(mediaItem.id, '42');
    expect(mediaItem.duration, const Duration(minutes: 3, seconds: 20));
    expect(mediaItem.extras, <String, dynamic>{
      'streamUri': 'http://example.test/api/tracks/42/stream',
      'source': 'network',
      'mimeType': 'audio/flac',
      'extension': '.flac',
      'format': 'FLAC',
      'sampleRate': 96000,
      'bitDepth': 24,
      'channels': 2,
      'fileSize': 52428800,
      'origin': 'Bibliothèque',
      'speedRatio': 1.0,
    });
  });

  test(
    'la source bibliothèque reçoit le Bearer courant sans token dans URL',
    () {
      final item = playerQueueItemForTrack(
        track: const Track(
          id: 67,
          title: 'Hurt me anymore',
          artist: 'purity.',
          album: 'Hurt me anymore',
          hasCover: true,
          durationSeconds: 132,
        ),
        api: LibraryApi(Dio(), 'https://homespotify.test'),
        userId: 3,
        authorizationHeaders: const {
          'Authorization': 'Bearer access-token-test',
        },
      );

      expect(item.headers, const {'Authorization': 'Bearer access-token-test'});
      expect(item.streamUri.query, isEmpty);
      expect(item.streamUri.toString(), endsWith('/api/tracks/67/stream'));
    },
  );

  test('la file conserve réseau et repli local sans Bearer vers file', () {
    final item = playerQueueItemForTrack(
      track: const Track(
        id: 67,
        title: 'Hurt me anymore',
        artist: 'purity.',
        album: 'Hurt me anymore',
        etag: 'source-hash',
        hasCover: false,
      ),
      api: LibraryApi(Dio(), 'https://homespotify.test'),
      userId: 3,
      authorizationHeaders: const {'Authorization': 'Bearer access-token-test'},
      localSource: ResolvedLocalSource(
        uri: Uri.file(r'C:\offline\67.ogg'),
        profile: OfflineProfile.opus256,
        mimeType: 'audio/ogg',
      ),
    );

    expect(item.usesLocalSource, isFalse);
    expect(item.canUseLocalFallback, isTrue);
    final local = item.useLocalFallback();
    expect(local.usesLocalSource, isTrue);
    expect(local.toAudioSource(), isA<AudioSource>());
    expect((local.toAudioSource() as UriAudioSource).headers, isNull);
    expect(local.toMediaItem().extras?['source'], 'local');
    expect(local.toMediaItem().extras?['format'], 'OGG');
    expect(local.useNetworkSource().streamUri.scheme, 'https');
  });
}
