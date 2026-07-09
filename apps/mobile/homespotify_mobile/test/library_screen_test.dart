import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/app/runtime_library_screen.dart';
import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playback_controller.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_screen.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';

void main() {
  const track = Track(
    id: 1,
    title: 'Genesis',
    artist: 'Justice',
    album: 'Cross',
    hasCover: false,
    durationSeconds: 200,
    extension: '.flac',
    mimeType: 'audio/flac',
    quality: TrackQuality(
      sampleRate: 44100,
      bitDepth: 16,
      status: 'lossless_verifie',
    ),
  );

  baseOverrides({required FutureOr<List<Track>> Function() library}) {
    return [
      libraryProvider.overrideWith((ref) => Future.value(library())),
      mediaItemProvider.overrideWith((ref) => const Stream<MediaItem?>.empty()),
      playbackStateProvider.overrideWith(
        (ref) => const Stream<PlaybackState>.empty(),
      ),
    ];
  }

  testWidgets('etat vide : message et commande de scan', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(library: () => <Track>[]),
        child: const MaterialApp(home: RuntimeLibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aucune piste dans la bibliotheque'), findsOneWidget);
    expect(
      find.textContaining('pnpm --filter @homespotify/api scan'),
      findsOneWidget,
    );
  });

  testWidgets('etat donnees : titre, artiste, format FLAC et specs', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(library: () => <Track>[track]),
        child: const MaterialApp(home: RuntimeLibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Genesis'), findsOneWidget);
    expect(find.textContaining('Justice'), findsOneWidget);
    expect(find.textContaining('3:20'), findsOneWidget);
    expect(find.textContaining('44.1kHz'), findsOneWidget);
    expect(find.text('FLAC'), findsOneWidget);
  });

  testWidgets('etat erreur : affiche serveur, URL API et retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryProvider.overrideWith(
            (ref) => throw LibraryApiException('Serveur injoignable.'),
          ),
          mediaItemProvider.overrideWith(
            (ref) => const Stream<MediaItem?>.empty(),
          ),
          playbackStateProvider.overrideWith(
            (ref) => const Stream<PlaybackState>.empty(),
          ),
        ],
        child: const MaterialApp(home: RuntimeLibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Serveur non joignable'), findsOneWidget);
    expect(find.textContaining('http://10.0.2.2:3000'), findsOneWidget);
    expect(find.text('Reessayer'), findsOneWidget);
  });

  testWidgets('mini-player : affiche la piste en cours', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryProvider.overrideWith((ref) => Future.value(<Track>[track])),
          mediaItemProvider.overrideWith(
            (ref) => Stream.value(
              const MediaItem(id: '1', title: 'Genesis', artist: 'Justice'),
            ),
          ),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(
                playing: false,
                processingState: AudioProcessingState.ready,
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: RuntimeLibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Genesis'), findsWidgets);
    expect(find.text('Justice'), findsWidgets);
    expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);
  });

  testWidgets('tap piste : montre la preparation et evite le double tap', (
    tester,
  ) async {
    final completer = Completer<void>();
    final controller = _FakePlaybackController(completer);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides(library: () => <Track>[track]),
          libraryPlaybackControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: RuntimeLibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Genesis'));
    await tester.pump();
    await tester.tap(find.text('Genesis'));
    await tester.pump();

    expect(controller.calls, 1);
    expect(controller.tracks, <Track>[track]);
    expect(controller.initialIndex, 0);
    expect(find.text('Preparation de la lecture...'), findsOneWidget);

    completer.complete();
    await tester.pumpAndSettle();

    expect(find.text('Preparation de la lecture...'), findsNothing);
  });

  testWidgets('LibraryScreen : le tap prépare la file à l’index choisi', (
    tester,
  ) async {
    final completer = Completer<void>();
    final controller = _FakePlaybackController(completer);
    addTearDown(() {
      if (!completer.isCompleted) completer.complete();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          ...baseOverrides(library: () => <Track>[track]),
          libraryPlaybackControllerProvider.overrideWith((ref) => controller),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Genesis'));
    await tester.pump();

    expect(controller.calls, 1);
    expect(controller.tracks, <Track>[track]);
    expect(controller.initialIndex, 0);
    expect(find.text('Préparation de la lecture...'), findsOneWidget);
  });
}

class _FakePlaybackController implements LibraryPlaybackController {
  _FakePlaybackController(this._completer);

  final Completer<void> _completer;
  int calls = 0;
  List<Track>? tracks;
  int? initialIndex;

  @override
  Future<void> playQueue({
    required List<Track> tracks,
    required int initialIndex,
  }) {
    calls += 1;
    this.tracks = tracks;
    this.initialIndex = initialIndex;
    return _completer.future;
  }
}
