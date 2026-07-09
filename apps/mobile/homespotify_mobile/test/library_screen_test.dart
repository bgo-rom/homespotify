import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/library/data/library_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_screen.dart';

void main() {
  testWidgets('état vide : message de bibliothèque vide', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryProvider.overrideWith((ref) => Future.value(<Track>[])),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Aucune piste dans la bibliothèque'), findsOneWidget);
  });

  testWidgets('état données : affiche titre et artiste', (tester) async {
    const track = Track(
      id: 1,
      title: 'Genesis',
      artist: 'Justice',
      album: 'Cross',
      hasCover: false,
      durationSeconds: 200,
      quality: TrackQuality(
        sampleRate: 44100,
        bitDepth: 16,
        status: 'lossless_verifie',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          libraryProvider.overrideWith((ref) => Future.value(<Track>[track])),
        ],
        child: const MaterialApp(home: LibraryScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Genesis'), findsOneWidget);
    expect(find.textContaining('Justice'), findsOneWidget);
    expect(find.textContaining('3:20'), findsOneWidget); // 200s
    expect(find.textContaining('44.1kHz'), findsOneWidget);
  });
}
