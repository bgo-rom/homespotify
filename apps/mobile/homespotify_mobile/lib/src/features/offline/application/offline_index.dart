import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../data/offline_manifest_store.dart';
import '../domain/offline_models.dart';
import '../../library/domain/track.dart';

String offlineCoverPath(String root, int userId, int trackId) =>
    '$root/offline/u$userId/covers/$trackId.cover';

/// Une copie locale et sa disponibilité RÉELLE : un fichier absent ou dont la
/// taille ne correspond pas au manifeste n'est jamais présenté comme lisible.
class OfflineIndexEntry {
  const OfflineIndexEntry({required this.record, required this.available});

  final OfflineTrackRecord record;

  /// `ready` en manifeste ET fichier présent avec la taille attendue.
  final bool available;
}

/// Index en mémoire du manifeste hors ligne du COMPTE COURANT.
///
/// Chargé une seule fois par session (jamais une requête SQLite par piste),
/// rafraîchi explicitement après un téléchargement ou une suppression via
/// `ref.invalidate(offlineIndexProvider)`. Il suit `authControllerProvider` :
/// logout ou changement de compte → index reconstruit pour le nouveau
/// `userId`, aucun fallback vers un autre compte.
class OfflineIndex {
  const OfflineIndex({
    required this.userId,
    required this.entries,
    required this.rootDir,
  });

  static const empty = OfflineIndex(userId: null, entries: [], rootDir: null);

  final int? userId;
  final List<OfflineIndexEntry> entries;
  final String? rootDir;

  /// Meilleure copie DISPONIBLE par piste (original > opus_256 > opus_128).
  Map<int, OfflineIndexEntry> get availableByTrackId {
    const order = [
      OfflineProfile.original,
      OfflineProfile.opus256,
      OfflineProfile.opus128,
    ];
    final map = <int, OfflineIndexEntry>{};
    for (final profile in order) {
      for (final entry in entries) {
        if (!entry.available || entry.record.profile != profile) continue;
        map.putIfAbsent(entry.record.trackId, () => entry);
      }
    }
    return map;
  }

  Set<int> get availableTrackIds => availableByTrackId.keys.toSet();

  int get availableCount => availableByTrackId.length;

  /// Espace réellement occupé par les copies disponibles (octets exacts).
  int get totalAvailableBytes => entries
      .where((e) => e.available)
      .fold(0, (sum, e) => sum + (e.record.sizeBytes ?? 0));

  String? absolutePathFor(OfflineTrackRecord record) {
    final root = rootDir;
    final relative = record.relativePath;
    if (root == null || relative == null) return null;
    return '$root/offline/u${record.userId}/$relative';
  }

  Uri? coverUriForTrack(int trackId) {
    final root = rootDir;
    final currentUserId = userId;
    if (root == null || currentUserId == null) return null;
    final file = File(offlineCoverPath(root, currentUserId, trackId));
    return file.existsSync() && file.lengthSync() > 0
        ? Uri.file(file.path)
        : null;
  }

  /// Pistes minimales reconstruites depuis le manifeste. Elles permettent à
  /// la bibliothèque de rester utile sans `GET /api/tracks`.
  List<Track> get availableTracks => availableByTrackId.values
      .map((entry) {
        final record = entry.record;
        final original = record.profile == OfflineProfile.original;
        return Track(
          id: record.trackId,
          title: record.title ?? 'Piste ${record.trackId}',
          artist: record.artist ?? 'Artiste inconnu',
          album: record.album ?? '',
          hasCover: coverUriForTrack(record.trackId) != null,
          durationSeconds: record.durationSeconds,
          mimeType: original ? record.codec : 'audio/ogg',
          extension: original ? record.container : '.ogg',
          sizeBytes: record.sizeBytes,
          etag: record.sourceSha256,
        );
      })
      .toList(growable: false);
}

/// Racine du stockage applicatif — surchargée dans les tests (répertoire temp).
final offlineRootDirProvider = Provider<Future<String> Function()>(
  (ref) =>
      () async => (await getApplicationSupportDirectory()).path,
);

/// Compte courant vu par la couche hors ligne. DÉCOUPLÉ du contrôleur d'auth :
/// vaut `null` par défaut (aucune copie visible) et n'est branché sur
/// `authControllerProvider` que dans `main.dart`. Ce découplage évite que
/// chaque tuile de bibliothèque instancie le contrôleur d'auth complet dans
/// les tests, tout en gardant la réactivité login/logout en production.
final offlineUserIdProvider = Provider<int?>((ref) => null);

final offlineIndexProvider = FutureProvider<OfflineIndex>((ref) async {
  final userId = ref.watch(offlineUserIdProvider);
  if (userId == null) return OfflineIndex.empty;
  // Jamais d'exception : un manifeste illisible équivaut à « aucune copie »
  // (pas de retry Riverpod en boucle, pas d'écran cassé — badge absent).
  try {
    final store = ref.watch(offlineManifestStoreProvider);
    final root = await ref.watch(offlineRootDirProvider)();
    final records = await store.listForUser(userId);
    final entries = records
        .map((record) {
          var available = false;
          if (record.status == OfflineDownloadStatus.ready &&
              record.relativePath != null) {
            final file = File(
              '$root/offline/u${record.userId}/${record.relativePath}',
            );
            available =
                file.existsSync() &&
                (record.sizeBytes == null ||
                    file.lengthSync() == record.sizeBytes);
          }
          return OfflineIndexEntry(record: record, available: available);
        })
        .toList(growable: false);
    return OfflineIndex(userId: userId, entries: entries, rootDir: root);
  } catch (_) {
    return OfflineIndex.empty;
  }
});

/// Pistes disponibles hors ligne (pour badges et filtre bibliothèque).
final offlineAvailableTrackIdsProvider = Provider<Set<int>>((ref) {
  return ref.watch(offlineIndexProvider).asData?.value.availableTrackIds ??
      const <int>{};
});

final offlineLibraryTracksProvider = Provider<List<Track>>((ref) {
  return ref.watch(offlineIndexProvider).asData?.value.availableTracks ??
      const <Track>[];
});

final offlineCoverUrlProvider = Provider.family<String?, int>((ref, trackId) {
  return ref
      .watch(offlineIndexProvider)
      .asData
      ?.value
      .coverUriForTrack(trackId)
      ?.toString();
});

/// Libellé court du profil local d'une piste (badge bibliothèque), ou null.
final offlineProfileLabelProvider = Provider.family<String?, int>((
  ref,
  trackId,
) {
  final index = ref.watch(offlineIndexProvider).asData?.value;
  final entry = index?.availableByTrackId[trackId];
  return entry == null ? null : offlineProfileShortLabel(entry.record.profile);
});

String offlineProfileShortLabel(OfflineProfile profile) => switch (profile) {
  OfflineProfile.original => 'Original',
  OfflineProfile.opus256 => 'Opus 256',
  OfflineProfile.opus128 => 'Opus 128',
};
