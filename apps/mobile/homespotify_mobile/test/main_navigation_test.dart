import 'package:flutter_test/flutter_test.dart';
import 'package:homespotify_mobile/src/app/main_navigation_state.dart';
import 'package:homespotify_mobile/src/app/router.dart';

/// Invariants des deux correctifs du crash « Bibliothèque → Albums » :
///  1. clés de Navigator uniques (plus de GlobalKey `root` dupliquée) ;
///  2. état de navigation DÉRIVÉ de la route (plus d'écriture pendant un build).
void main() {
  group('clés de Navigator', () {
    test('une clé racine + une clé par branche, toutes distinctes', () {
      final keys = {
        rootNavigatorKey,
        homeNavigatorKey,
        libraryNavigatorKey,
        discoverNavigatorKey,
        profileNavigatorKey,
      };
      expect(keys.length, 5, reason: 'aucune clé ne doit être réutilisée');
    });

    test('le GoRouter principal utilise bien la clé racine unique', () {
      expect(appRouter.configuration.navigatorKey, same(rootNavigatorKey));
    });
  });

  group('branchIndexForLocation (état dérivé de la route)', () {
    test('les 4 branches du shell sont reconnues', () {
      expect(branchIndexForLocation('/'), HomeDestination.home);
      expect(branchIndexForLocation('/library'), HomeDestination.library);
      expect(branchIndexForLocation('/discover'), HomeDestination.discover);
      expect(branchIndexForLocation('/profile'), HomeDestination.profile);
    });

    test('une route hors shell renvoie null (shell couvert)', () {
      // C'est exactement le cas Bibliothèque → Albums : le shell est couvert,
      // donc invisible, alors que la branche Bibliothèque reste sélectionnée.
      expect(branchIndexForLocation('/albums'), isNull);
      expect(branchIndexForLocation('/albums/abc'), isNull);
      expect(branchIndexForLocation('/artists'), isNull);
      expect(branchIndexForLocation('/player'), isNull);
      expect(branchIndexForLocation('/requests'), isNull);
    });
  });
}
