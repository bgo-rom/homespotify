import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/features/catalog/data/catalog_api.dart';
import 'package:homespotify_mobile/src/features/home/presentation/home_dashboard_screen.dart';
import 'package:homespotify_mobile/src/features/library/domain/track.dart';

/// « Ajouts récents » : catalogue global ANONYMISÉ + ajout à sa bibliothèque.

CatalogEntry entry(int id, {bool inMyLibrary = false}) => CatalogEntry(
  track: Track(
    id: id,
    title: 'Titre $id',
    artist: 'Artiste $id',
    album: 'Album $id',
    hasCover: false,
  ),
  inMyLibrary: inMyLibrary,
);

Widget wrap(Widget child, {Size size = const Size(360, 800)}) => ProviderScope(
  child: MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(size: size),
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  ),
);

void main() {
  group('RecentTracksSection — catalogue global', () {
    testWidgets('n’expose AUCUNE identité (importateur / demandeur)', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrap(
          RecentTracksSection(
            entries: [entry(1), entry(2)],
            loadingTrackId: null,
            onTrackTap: (_) {},
            onAdd: (_) {},
            onSeeAll: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Ajouts récents'), findsOneWidget);
      expect(find.text('Titre 1'), findsOneWidget);
      // Aucun nom de compte / mention d'attribution ne doit apparaître.
      expect(find.textContaining('skibidi'), findsNothing);
      expect(find.textContaining('ajouté par'), findsNothing);
      expect(find.textContaining('@'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('bouton Ajouter : appelle onAdd avec la bonne entrée', (
      tester,
    ) async {
      CatalogEntry? added;
      await tester.pumpWidget(
        wrap(
          RecentTracksSection(
            entries: [entry(1)],
            loadingTrackId: null,
            onTrackTap: (_) {},
            onAdd: (value) => added = value,
            onSeeAll: () {},
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Ajouter'), findsOneWidget);
      await tester.tap(find.text('Ajouter'));
      await tester.pump();
      expect(added?.track.id, 1);
    });

    testWidgets(
      'déjà dans la bibliothèque : « Dans votre bibliothèque », pas de bouton Ajouter',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            RecentTracksSection(
              entries: [entry(1, inMyLibrary: true)],
              loadingTrackId: null,
              onTrackTap: (_) {},
              onAdd: (_) {},
              onSeeAll: () {},
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Dans votre bibliothèque'), findsOneWidget);
        expect(find.text('Ajouter'), findsNothing);
      },
    );

    testWidgets('écran étroit : aucun overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        wrap(
          RecentTracksSection(
            entries: [entry(1), entry(2, inMyLibrary: true)],
            loadingTrackId: null,
            onTrackTap: (_) {},
            onAdd: (_) {},
            onSeeAll: () {},
          ),
          size: const Size(320, 640),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
