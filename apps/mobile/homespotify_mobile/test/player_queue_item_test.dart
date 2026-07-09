import 'package:flutter_test/flutter_test.dart';
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
    );

    final mediaItem = item.toMediaItem();

    expect(mediaItem.id, '42');
    expect(mediaItem.duration, const Duration(minutes: 3, seconds: 20));
    expect(mediaItem.extras, <String, dynamic>{
      'streamUri': 'http://example.test/api/tracks/42/stream',
      'mimeType': 'audio/flac',
      'extension': '.flac',
      'format': 'FLAC',
    });
  });
}
