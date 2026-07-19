import 'package:flutter_riverpod/misc.dart' show Override;

import 'package:homespotify_mobile/src/features/library/domain/local_playlist.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_favorites.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playlists.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_summary.dart';

import 'fake_library_repositories.dart';

List<Override> libraryNetworkOverrides({
  Set<int> favoriteIds = const <int>{},
  List<LocalPlaylist> playlists = const <LocalPlaylist>[],
  UserLibrarySummary summary = const UserLibrarySummary(
    trackCount: 0,
    favoriteCount: 0,
    playlistCount: 0,
    logicalSizeBytes: 0,
  ),
  Future<UserLibrarySummary> Function()? summaryLoader,
}) => [
  favoritesApiProvider.overrideWithValue(FakeFavoritesRepository(favoriteIds)),
  playlistsApiProvider.overrideWithValue(FakePlaylistsRepository(playlists)),
  userLibrarySummaryProvider.overrideWith(
    (ref) => summaryLoader?.call() ?? Future.value(summary),
  ),
];
