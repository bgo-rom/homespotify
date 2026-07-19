import 'package:audio_service/audio_service.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/track_actions_bottom_sheet.dart';
import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/presentation/player_providers.dart';
import 'package:homespotify_mobile/src/features/player/presentation/queue_screen.dart';

void main() {
  testWidgets('le menu de piste affiche les libellés français UTF-8 exacts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(420, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryApiProvider.overrideWithValue(
            LibraryApi(Dio(), 'https://homespotify.test'),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: _TrackActionsLauncher())),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-track-actions')));
    await tester.pumpAndSettle();

    for (final label in const [
      'Ajouter à la file d’attente',
      'Voir la file d’attente',
      'Accéder à l’artiste',
      'Accéder à l’album',
      'Supprimer de la bibliothèque',
      'Vitesse du titre',
    ]) {
      expect(
        find.text(label),
        findsOneWidget,
        reason: 'Libellé absent: $label',
      );
    }
    _expectNoMojibake(tester);
  });

  testWidgets('la file affiche les accents et le séparateur exacts', (
    tester,
  ) async {
    const items = <MediaItem>[
      MediaItem(
        id: '1',
        title: 'Titre courant',
        artist: 'Artiste',
        duration: Duration(minutes: 3),
        extras: {'origin': 'Bibliothèque'},
      ),
      MediaItem(
        id: '2',
        title: 'Titre suivant',
        artist: 'Artiste',
        duration: Duration(minutes: 4),
        extras: {'origin': 'Bibliothèque'},
      ),
    ];
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          audioHandlerProvider.overrideWithValue(_NoopAudioHandler()),
          queueProvider.overrideWith((ref) => Stream.value(items)),
          mediaItemProvider.overrideWith((ref) => Stream.value(items.first)),
          playbackStateProvider.overrideWith(
            (ref) => Stream.value(
              PlaybackState(
                playing: true,
                processingState: AudioProcessingState.ready,
                queueIndex: 0,
              ),
            ),
          ),
          positionDataProvider.overrideWith(
            (ref) => Stream.value(
              const PlayerPositionData(
                position: Duration(seconds: 30),
                bufferedPosition: Duration(seconds: 45),
                duration: Duration(minutes: 3),
              ),
            ),
          ),
        ],
        child: const MaterialApp(home: QueueScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('File d’attente'), findsOneWidget);
    expect(find.text('À suivre'), findsOneWidget);
    final strings = _visibleStrings(tester).toList(growable: false);
    expect(strings.any((value) => value.contains('Bibliothèque')), isTrue);
    expect(strings.any((value) => value.contains(' · ')), isTrue);
    _expectNoMojibake(tester);
  });
}

class _TrackActionsLauncher extends ConsumerWidget {
  const _TrackActionsLauncher();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: FilledButton(
        key: const ValueKey('open-track-actions'),
        onPressed: () => showTrackActionsBottomSheet(
          context,
          ref,
          track: const Track(
            id: 1,
            title: 'Été à Paris',
            artist: 'L’Artiste',
            album: 'Lumière',
            hasCover: false,
            durationSeconds: 180,
            extension: '.flac',
            mimeType: 'audio/flac',
          ),
        ),
        child: const Text('Ouvrir'),
      ),
    );
  }
}

class _NoopAudioHandler implements HomeSpotifyAudioHandler {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'appel inattendu au handler: ${invocation.memberName}',
  );
}

Iterable<String> _visibleStrings(WidgetTester tester) sync* {
  for (final element in find.byType(Text).evaluate()) {
    final widget = element.widget as Text;
    yield widget.data ?? widget.textSpan?.toPlainText() ?? '';
  }
}

void _expectNoMojibake(WidgetTester tester) {
  final malformedUtf8Pattern = RegExp(
    [
      String.fromCharCode(0x00c3),
      String.fromCharCode(0x00c2),
      '${String.fromCharCode(0x00e2)}${String.fromCharCode(0x20ac)}',
      String.fromCharCode(0x00f0),
      String.fromCharCode(0xfffd),
    ].join('|'),
  );
  final corruptStrings = _visibleStrings(
    tester,
  ).where(malformedUtf8Pattern.hasMatch).toList(growable: false);
  expect(corruptStrings, isEmpty, reason: 'Mojibake visible: $corruptStrings');
}
