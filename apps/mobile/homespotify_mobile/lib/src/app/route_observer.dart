import 'package:flutter/widgets.dart';

/// Observateur GLOBAL des transitions de route, injecté dans les `observers` du
/// [GoRouter] (cf. router.dart). Les écrans qui doivent réagir à leur
/// VISIBILITÉ (et pas seulement à leur pop/dispose) s'y abonnent via le mixin
/// `RouteAware` : `didPushNext()` quand une route est empilée PAR-DESSUS (l'écran
/// devient invisible), `didPopNext()` au retour.
///
/// Typé `ModalRoute<void>` : les pages GoRouter (`CustomTransitionPage<void>`)
/// produisent des `PageRoute<void>` — donc des `ModalRoute<void>` — de sorte que
/// `didPushNext`/`didPopNext` se déclenchent bien entre deux pages de l'app.
final RouteObserver<ModalRoute<void>> routeObserver =
    RouteObserver<ModalRoute<void>>();
