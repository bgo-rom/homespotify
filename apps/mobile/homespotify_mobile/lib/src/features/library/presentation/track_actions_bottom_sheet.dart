import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/network/authenticated_network_image.dart';
import '../../auth/application/auth_controller.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/track_speed_sheet.dart';
import '../data/library_api.dart';
import '../domain/track.dart';
import 'library_albums.dart';
import 'library_artists.dart';
import 'library_playback_controller.dart';
import 'playlist_dialogs.dart';
import 'track_removal.dart';

const _background = Color(0xFF17171D);
const _accent = Color(0xFF1DB954);
const _danger = Color(0xFFE57373);

enum _TrackAction {
  playNext,
  addToQueue,
  addToPlaylist,
  showQueue,
  artist,
  album,
  speed,
  remove,
}

bool _trackActionsSheetVisible = false;

/// Menu contextuel commun à toutes les listes de pistes. Le verrou global
/// empêche deux feuilles concurrentes lors d'appuis longs rapprochés.
Future<void> showTrackActionsBottomSheet(
  BuildContext context,
  WidgetRef ref, {
  required Track track,
  String origin = 'Bibliothèque',
}) async {
  if (_trackActionsSheetVisible) return;
  _trackActionsSheetVisible = true;
  _TrackAction? action;
  try {
    action = await showModalBottomSheet<_TrackAction>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: _background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => _TrackActionsSheet(track: track),
    );
  } finally {
    _trackActionsSheetVisible = false;
  }
  if (action == null || !context.mounted) return;

  final artistKey = _artistKey(track);
  final albumKey = _albumKey(track);
  switch (action) {
    case _TrackAction.playNext:
    case _TrackAction.addToQueue:
      final item = playerQueueItemForTrack(
        track: track,
        api: ref.read(libraryApiProvider),
        userId: ref.read(authControllerProvider).user?.id ?? 0,
        authorizationHeaders: ref.read(mediaAuthorizationHeadersProvider),
        origin: origin,
      );
      try {
        final handler = ref.read(audioHandlerProvider);
        if (action == _TrackAction.playNext) {
          await handler.playNext(item);
        } else {
          await handler.addToQueue(item);
        }
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                action == _TrackAction.playNext
                    ? '« ${track.title} » sera lu ensuite.'
                    : '« ${track.title} » a été ajouté à la file.',
              ),
            ),
          );
        }
      } catch (error, stackTrace) {
        logError(
          'modification de file impossible',
          error: error,
          stackTrace: stackTrace,
        );
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Impossible de modifier la file.')),
          );
        }
      }
    case _TrackAction.addToPlaylist:
      await showAddTrackToPlaylistSheet(context, trackId: track.id);
    case _TrackAction.showQueue:
      openQueue(context);
    case _TrackAction.artist:
      if (artistKey != null) openArtistDetail(context, artistKey);
    case _TrackAction.album:
      if (albumKey != null) openAlbumDetail(context, albumKey);
    case _TrackAction.speed:
      final item = playerQueueItemForTrack(
        track: track,
        api: ref.read(libraryApiProvider),
        userId: ref.read(authControllerProvider).user?.id ?? 0,
        authorizationHeaders: ref.read(mediaAuthorizationHeadersProvider),
        origin: origin,
      );
      await showTrackSpeedSheet(
        context,
        ref,
        target: TrackSpeedTarget(
          id: track.id,
          title: track.title,
          artist: track.artist,
          streamUri: item.streamUri,
          headers: item.headers,
        ),
      );
    case _TrackAction.remove:
      await confirmAndRemoveTrackFromLibrary(
        context,
        ref,
        trackId: track.id,
        title: track.title,
      );
  }
}

String? _artistKey(Track track) {
  final artist = track.artist.trim();
  if (artist.isEmpty || artist == unknownArtistTitle) return null;
  return artistKeyForName(artist);
}

String? _albumKey(Track track) {
  final album = track.album.trim();
  return album.isEmpty ? null : albumKeyForTitle(album);
}

class _TrackActionsSheet extends ConsumerWidget {
  const _TrackActionsSheet({required this.track});

  final Track track;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(libraryApiProvider);
    final coverUrl = track.hasCover ? api.coverUri(track.id).toString() : null;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.55,
      maxChildSize: 0.94,
      builder: (context, scrollController) => ListView(
        controller: scrollController,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
        children: [
          Center(
            child: Container(
              width: 42,
              height: 5,
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _TrackHeader(track: track, coverUrl: coverUrl),
          const SizedBox(height: 16),
          _ActionTile(
            key: const ValueKey('track-action-play-next'),
            icon: Icons.redo_rounded,
            label: 'Lire ensuite',
            onTap: () => Navigator.pop(context, _TrackAction.playNext),
          ),
          _ActionTile(
            key: const ValueKey('track-action-add-queue'),
            icon: Icons.playlist_add_rounded,
            label: 'Ajouter à la file d’attente',
            onTap: () => Navigator.pop(context, _TrackAction.addToQueue),
          ),
          _ActionTile(
            icon: Icons.queue_music_rounded,
            label: 'Ajouter à une playlist',
            onTap: () => Navigator.pop(context, _TrackAction.addToPlaylist),
          ),
          _ActionTile(
            icon: Icons.format_list_numbered_rounded,
            label: 'Voir la file d’attente',
            onTap: () => Navigator.pop(context, _TrackAction.showQueue),
          ),
          _ActionTile(
            icon: Icons.person_outline_rounded,
            label: 'Accéder à l’artiste',
            enabled: _artistKey(track) != null,
            onTap: () => Navigator.pop(context, _TrackAction.artist),
          ),
          _ActionTile(
            icon: Icons.album_outlined,
            label: 'Accéder à l’album',
            enabled: _albumKey(track) != null,
            onTap: () => Navigator.pop(context, _TrackAction.album),
          ),
          _ActionTile(
            key: const ValueKey('track-action-speed'),
            icon: Icons.speed_rounded,
            label: 'Vitesse du titre',
            onTap: () => Navigator.pop(context, _TrackAction.speed),
          ),
          const Divider(color: Colors.white12, height: 24),
          _ActionTile(
            key: const ValueKey('track-action-remove-library'),
            icon: Icons.delete_outline_rounded,
            label: 'Supprimer de la bibliothèque',
            color: _danger,
            onTap: () => Navigator.pop(context, _TrackAction.remove),
          ),
        ],
      ),
    );
  }
}

class _TrackHeader extends StatelessWidget {
  const _TrackHeader({required this.track, required this.coverUrl});

  final Track track;
  final String? coverUrl;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 76,
          height: 76,
          child: coverUrl == null
              ? const ColoredBox(
                  color: Color(0xFF292933),
                  child: Icon(Icons.music_note_rounded, color: Colors.white30),
                )
              : AuthenticatedNetworkImage(coverUrl!, fit: BoxFit.cover),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              track.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70),
            ),
            if (track.album.trim().isNotEmpty)
              Text(
                track.album,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white38, fontSize: 12),
              ),
            if (track.formatLabel != null)
              Padding(
                padding: const EdgeInsets.only(top: 5),
                child: Text(
                  track.formatLabel!,
                  style: const TextStyle(
                    color: _accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
      ),
    ],
  );
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.enabled = true,
    this.color,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = enabled ? (color ?? Colors.white) : Colors.white30;
    return ListTile(
      enabled: enabled,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      leading: Icon(icon, color: foreground),
      title: Text(label, style: TextStyle(color: foreground)),
      onTap: enabled ? onTap : null,
    );
  }
}
