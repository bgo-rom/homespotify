import 'package:go_router/go_router.dart';

import '../features/library/presentation/library_screen.dart';
import '../features/player/presentation/player_screen.dart';

final GoRouter appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      name: 'library',
      builder: (context, state) => const LibraryScreen(),
    ),
    GoRoute(
      path: '/player',
      name: 'player',
      builder: (context, state) => const PlayerScreen(),
    ),
  ],
);
