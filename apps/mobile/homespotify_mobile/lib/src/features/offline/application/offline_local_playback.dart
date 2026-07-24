import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../player/audio/homespotify_audio_handler.dart';
import '../domain/offline_models.dart';
import '../data/offline_manifest_store.dart';
import 'offline_index.dart';

/// Construit un élément de file DEPUIS LE MANIFESTE LOCAL, sans aucun appel
/// API. Retourne null si la copie n'est pas réellement disponible (fichier
/// absent ou taille incohérente) : une copie douteuse n'est jamais jouée.
///
/// Invariants : URI `file://` uniquement, JAMAIS de Bearer vers un fichier
/// local, métadonnées issues du manifeste (titre, artiste, album, durée).
PlayerQueueItem? localQueueItemForEntry(
  OfflineIndex index,
  OfflineIndexEntry entry,
) {
  if (!entry.available) return null;
  final absolutePath = index.absolutePathFor(entry.record);
  if (absolutePath == null) return null;
  final record = entry.record;
  return PlayerQueueItem(
    id: '${record.trackId}',
    userId: record.userId,
    streamUri: Uri.file(absolutePath),
    localFallbackUri: Uri.file(absolutePath),
    localFallbackMimeType: record.profile == OfflineProfile.original
        ? record.codec
        : 'audio/ogg',
    headers: null, // jamais d'Authorization vers file://
    title: record.title ?? 'Piste ${record.trackId}',
    artist: record.artist,
    album: record.album,
    artUri: index.coverUriForTrack(record.trackId),
    duration: record.durationSeconds == null
        ? null
        : Duration(milliseconds: (record.durationSeconds! * 1000).round()),
    mimeType: record.profile == OfflineProfile.original
        ? record
              .codec // le MIME réel de la source y est conservé
        : 'audio/ogg',
    bitrate: record.measuredBitrateKbps,
    fileSize: record.sizeBytes,
    origin: 'Téléchargements',
  );
}

/// File locale complète (toutes les copies disponibles du compte, ordre du
/// manifeste). Fonction pure sur l'index : testable sans widget ni API.
List<PlayerQueueItem> buildLocalQueue(OfflineIndex index) {
  final byTrack = index.availableByTrackId;
  return byTrack.values
      .map((entry) => localQueueItemForEntry(index, entry))
      .whereType<PlayerQueueItem>()
      .toList(growable: false);
}

/// Lance la lecture locale à partir d'une piste de l'écran Téléchargements.
/// Une file créée sans catalogue réseau reste volontairement locale ; les
/// files de bibliothèque conservent leurs deux sources via leur contrôleur.
Future<void> playLocalQueueFromTrack(
  WidgetRef ref,
  OfflineIndex index,
  int trackId,
) async {
  final items = buildLocalQueue(index);
  final initialIndex = items.indexWhere((item) => item.id == '$trackId');
  if (items.isEmpty || initialIndex < 0) {
    throw StateError('Aucune copie locale lisible pour cette piste.');
  }
  final selected = index.availableByTrackId[trackId]?.record;
  if (selected != null) {
    await ref
        .read(offlineManifestStoreProvider)
        .touch(selected.userId, selected.trackId, selected.profile);
  }
  await ref
      .read(audioHandlerProvider)
      .setQueueAndPlay(items: items, initialIndex: initialIndex);
}
