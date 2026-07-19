import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';
import 'package:homespotify_mobile/src/features/library/presentation/widgets/library_track_tile.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';

import 'support/fake_library_repositories.dart';

void main() {
  testWidgets('ligne de morceau hiérarchise les données et garde ses actions', (
    tester,
  ) async {
    var taps = 0;
    var longPresses = 0;
    const track = Track(
      id: 67,
      title: 'Hurt me anymore',
      artist: 'The Wrecks',
      album: 'Sonder',
      hasCover: false,
      durationSeconds: 201,
      extension: '.flac',
      quality: TrackQuality(
        sampleRate: 44100,
        bitDepth: 16,
        status: 'lossless_verifie',
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          favoritesApiProvider.overrideWithValue(FakeFavoritesRepository()),
          mediaItemProvider.overrideWith(
            (ref) => Stream.value(
              const MediaItem(id: '67', title: 'Hurt me anymore'),
            ),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(
                playing: true,
                processingState: AudioProcessingState.ready,
              ),
            ),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: LibraryTrackTile(
              track: track,
              coverUrl: null,
              isLoading: false,
              onTap: () => taps += 1,
              onLongPress: () => longPresses += 1,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Hurt me anymore'), findsOneWidget);
    expect(find.text('The Wrecks · Sonder'), findsOneWidget);
    expect(find.textContaining('FLAC · 3:21 · 44.1kHz'), findsOneWidget);
    expect(find.byIcon(Icons.graphic_eq_rounded), findsOneWidget);
    expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);

    await tester.tap(find.text('Hurt me anymore'));
    expect(taps, 1);
    await tester.longPress(find.text('Hurt me anymore'));
    expect(longPresses, 1);
  });
}
