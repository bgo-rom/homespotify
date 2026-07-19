import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/app/navigation.dart';
import 'package:homespotify_mobile/src/features/library/data/playlists_api.dart';
import 'package:homespotify_mobile/src/features/library/domain/local_playlist.dart';
import 'package:homespotify_mobile/src/features/library/presentation/library_playlists.dart';

void main() {
  test(
    'CRUD, ajout/retrait et réordonnancement passent par le backend',
    () async {
      final repository = _MemoryPlaylistsRepository();
      final container = ProviderContainer(
        overrides: [playlistsApiProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);

      await container.read(playlistsProvider.future);
      final controller = container.read(playlistsProvider.notifier);
      await expectLater(
        () => controller.create('   '),
        throwsA(isA<PlaylistValidationException>()),
      );

      final playlist = await controller.create('Route du soir');
      expect(await controller.rename(playlist.id, 'Route de nuit'), isTrue);
      expect(await controller.addTrack(playlist.id, 42), isTrue);
      expect(await controller.addTrack(playlist.id, 7), isTrue);
      expect(await controller.reorder(playlist.id, <int>[7, 42]), isTrue);
      expect(
        container.read(playlistsProvider).requireValue.single.trackIds,
        <int>[7, 42],
      );
      expect(await controller.removeTrack(playlist.id, 42), isTrue);
      expect(await controller.delete(playlist.id), isTrue);
      expect(container.read(playlistsProvider).requireValue, isEmpty);
    },
  );

  test('deux comptes chargent des playlists distinctes', () async {
    final firstRepo = _MemoryPlaylistsRepository()
      ..items.add(const LocalPlaylist(id: '1', name: 'Compte A', trackIds: []));
    final secondRepo = _MemoryPlaylistsRepository()
      ..items.add(const LocalPlaylist(id: '2', name: 'Compte B', trackIds: []));
    final first = ProviderContainer(
      overrides: [playlistsApiProvider.overrideWithValue(firstRepo)],
    );
    final second = ProviderContainer(
      overrides: [playlistsApiProvider.overrideWithValue(secondRepo)],
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);

    expect(
      (await first.read(playlistsProvider.future)).single.name,
      'Compte A',
    );
    expect(
      (await second.read(playlistsProvider.future)).single.name,
      'Compte B',
    );
  });

  test('ajout optimiste : double tap ignoré et rollback sur erreur', () async {
    final repository = _FailingAddPlaylistsRepository()
      ..items.add(
        const LocalPlaylist(id: '1', name: 'Test', trackIds: <int>[]),
      );
    final container = ProviderContainer(
      overrides: [playlistsApiProvider.overrideWithValue(repository)],
    );
    addTearDown(container.dispose);

    await container.read(playlistsProvider.future);
    final controller = container.read(playlistsProvider.notifier);
    final first = controller.addTrack('1', 42);

    expect(
      container.read(playlistsProvider).requireValue.single.trackIds,
      <int>[42],
    );
    expect(await controller.addTrack('1', 42), isFalse);
    expect(repository.addCalls, 1);

    repository.addGate.complete();
    await expectLater(first, throwsA(isA<PlaylistValidationException>()));
    expect(
      container.read(playlistsProvider).requireValue.single.trackIds,
      isEmpty,
    );
  });

  test('route playlist utilise uniquement un ID opaque sûr', () {
    expect(isSafePlaylistId('123'), isTrue);
    expect(isSafePlaylistId('Road/Trip 100%'), isFalse);
    expect(playlistDetailPath('123'), '/playlists/123');
    expect(playlistDetailPath('Road/Trip 100%').contains('Road'), isFalse);
  });
}

class _MemoryPlaylistsRepository implements PlaylistsRepository {
  final List<LocalPlaylist> items = <LocalPlaylist>[];
  int _nextId = 1;

  @override
  Future<List<LocalPlaylist>> fetchAll() async => List.of(items);

  @override
  Future<LocalPlaylist> create(String name) async {
    final value = LocalPlaylist(
      id: '${_nextId++}',
      name: name,
      trackIds: const [],
    );
    items.add(value);
    return value;
  }

  @override
  Future<LocalPlaylist> rename(String playlistId, String name) async =>
      _replace(playlistId, name: name);

  @override
  Future<void> delete(String playlistId) async {
    items.removeWhere((item) => item.id == playlistId);
  }

  @override
  Future<LocalPlaylist> addTrack(String playlistId, int trackId) async {
    final current = _find(playlistId);
    if (current.trackIds.contains(trackId)) return current;
    return _replace(playlistId, trackIds: <int>[...current.trackIds, trackId]);
  }

  @override
  Future<LocalPlaylist> removeTrack(String playlistId, int trackId) async {
    final current = _find(playlistId);
    return _replace(
      playlistId,
      trackIds: current.trackIds.where((id) => id != trackId).toList(),
    );
  }

  @override
  Future<LocalPlaylist> reorder(String playlistId, List<int> trackIds) async =>
      _replace(playlistId, trackIds: trackIds);

  LocalPlaylist _find(String id) => items.firstWhere((item) => item.id == id);

  LocalPlaylist _replace(String id, {String? name, List<int>? trackIds}) {
    final index = items.indexWhere((item) => item.id == id);
    final current = items[index];
    final next = LocalPlaylist(
      id: id,
      name: name ?? current.name,
      trackIds: trackIds ?? current.trackIds,
    );
    items[index] = next;
    return next;
  }
}

class _FailingAddPlaylistsRepository extends _MemoryPlaylistsRepository {
  final Completer<void> addGate = Completer<void>();
  int addCalls = 0;

  @override
  Future<LocalPlaylist> addTrack(String playlistId, int trackId) async {
    addCalls += 1;
    await addGate.future;
    throw DioException(
      requestOptions: RequestOptions(path: '/api/playlists/$playlistId/tracks'),
      type: DioExceptionType.connectionError,
    );
  }
}
