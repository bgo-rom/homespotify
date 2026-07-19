import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation.dart';
import '../../../core/network/authenticated_network_image.dart';
import '../../library/presentation/playlist_dialogs.dart';
import '../audio/homespotify_audio_handler.dart';
import 'player_providers.dart';

const _background = Color(0xFF0D0D10);
const _surface = Color(0xFF1A1A22);
const _accent = Color(0xFF1DB954);

class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final queue = ref.watch(queueProvider).asData?.value ?? const <MediaItem>[];
    final playback = ref.watch(playbackStateProvider).asData?.value;
    final position =
        ref.watch(positionDataProvider).asData?.value ??
        PlayerPositionData.zero;
    final currentIndex = playback?.queueIndex ?? -1;
    final validCurrent = currentIndex >= 0 && currentIndex < queue.length;
    final current = validCurrent ? queue[currentIndex] : null;
    final upcoming = validCurrent
        ? queue.sublist(currentIndex + 1)
        : const <MediaItem>[];

    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'File d’attente',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
            Text(
              _headerMeta(
                queue,
                currentIndex,
                position.position,
                playback?.speed ?? 1,
              ),
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Fermer',
            onPressed: () => context.canPop() ? context.pop() : context.go('/'),
            icon: const Icon(Icons.close_rounded),
          ),
        ],
      ),
      body: current == null
          ? const _EmptyQueue()
          : CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: _CurrentTrackCard(
                    item: current,
                    position: position.position,
                    duration: position.duration == Duration.zero
                        ? current.duration
                        : position.duration,
                    playing: playback?.playing ?? false,
                  ),
                ),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(18, 22, 8, 8),
                    child: Row(
                      children: [
                        const Text(
                          'À suivre',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Spacer(),
                        if (upcoming.isNotEmpty)
                          TextButton.icon(
                            key: const ValueKey('queue-clear-upcoming'),
                            onPressed: () => _confirmClear(context, ref),
                            icon: const Icon(Icons.clear_all_rounded),
                            label: const Text('Vider'),
                          ),
                      ],
                    ),
                  ),
                ),
                if (upcoming.isEmpty)
                  const SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        'Aucune piste à suivre.',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                  )
                else
                  SliverFillRemaining(
                    child: ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.only(bottom: 24),
                      itemCount: upcoming.length,
                      onReorderItem: (oldIndex, newIndex) {
                        ref
                            .read(audioHandlerProvider)
                            .reorderQueueItem(
                              currentIndex + 1 + oldIndex,
                              currentIndex + 1 + newIndex,
                            );
                      },
                      itemBuilder: (context, index) {
                        final absoluteIndex = currentIndex + 1 + index;
                        return _UpcomingTile(
                          key: ValueKey(
                            'queue-item-${upcoming[index].id}-$index',
                          ),
                          item: upcoming[index],
                          index: absoluteIndex,
                          reorderIndex: index,
                        );
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  static String _headerMeta(
    List<MediaItem> queue,
    int currentIndex,
    Duration position,
    double currentSpeed,
  ) {
    var remaining = Duration.zero;
    for (var index = 0; index < queue.length; index++) {
      final duration = queue[index].duration;
      if (duration == null || index < currentIndex) continue;
      final rawRemaining = index == currentIndex && duration > position
          ? duration - position
          : duration;
      final speed = index == currentIndex
          ? currentSpeed
          : ((queue[index].extras?['speedRatio'] as num?)?.toDouble() ?? 1);
      remaining += _durationAtSpeed(rawRemaining, speed);
    }
    final count = '${queue.length} ${queue.length > 1 ? 'pistes' : 'piste'}';
    return remaining == Duration.zero
        ? count
        : '$count · ${_formatDuration(remaining)} restantes';
  }

  static Duration _durationAtSpeed(Duration duration, double speed) {
    final safeSpeed = speed.isFinite && speed > 0 ? speed : 1.0;
    return Duration(
      microseconds: (duration.inMicroseconds / safeSpeed).round(),
    );
  }

  static Future<void> _confirmClear(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _surface,
        title: const Text('Vider la file à suivre ?'),
        content: const Text(
          'La piste en cours continuera sans interruption.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Annuler'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Vider'),
          ),
        ],
      ),
    );
    if (confirmed == true) await ref.read(audioHandlerProvider).clearUpcoming();
  }
}

class _CurrentTrackCard extends StatelessWidget {
  const _CurrentTrackCard({
    required this.item,
    required this.position,
    required this.duration,
    required this.playing,
  });

  final MediaItem item;
  final Duration position;
  final Duration? duration;
  final bool playing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Material(
      color: _surface,
      borderRadius: BorderRadius.circular(22),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: const ValueKey('queue-current-track'),
        onTap: () => openPlayer(context),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              _Artwork(artUri: item.artUri, size: 86, radius: 14),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          playing
                              ? Icons.graphic_eq_rounded
                              : Icons.pause_rounded,
                          color: _accent,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'EN COURS DE LECTURE',
                          style: TextStyle(
                            color: _accent,
                            fontSize: 10,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.8,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      item.artist ?? 'Artiste inconnu',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white54),
                    ),
                    const SizedBox(height: 9),
                    LinearProgressIndicator(
                      value: duration == null || duration == Duration.zero
                          ? 0
                          : (position.inMilliseconds / duration!.inMilliseconds)
                                .clamp(0.0, 1.0),
                      color: _accent,
                      backgroundColor: Colors.white12,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${_formatDuration(position)} / '
                      '${duration == null ? '—' : _formatDuration(duration!)}',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

enum _QueueAction { playNow, playNext, bottom, artist, album, playlist, remove }

class _UpcomingTile extends ConsumerWidget {
  const _UpcomingTile({
    super.key,
    required this.item,
    required this.index,
    required this.reorderIndex,
  });

  final MediaItem item;
  final int index;
  final int reorderIndex;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Dismissible(
    key: ValueKey('dismiss-${item.id}-$index'),
    direction: DismissDirection.endToStart,
    background: const ColoredBox(
      color: Color(0xFF7A2630),
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: EdgeInsets.only(right: 24),
          child: Icon(Icons.delete_outline_rounded, color: Colors.white),
        ),
      ),
    ),
    onDismissed: (_) => ref.read(audioHandlerProvider).removeQueueItemAt(index),
    child: ListTile(
      contentPadding: const EdgeInsets.only(left: 16, right: 6),
      leading: _Artwork(artUri: item.artUri, size: 48, radius: 8),
      title: Text(
        item.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        '${item.artist ?? 'Artiste inconnu'} · '
        '${item.duration == null ? '—' : _formatDuration(item.duration!)} · '
        '${item.extras?['origin'] ?? 'Bibliothèque'}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white38, fontSize: 11),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          ReorderableDragStartListener(
            index: reorderIndex,
            child: const Padding(
              padding: EdgeInsets.all(10),
              child: Icon(Icons.drag_handle_rounded, color: Colors.white30),
            ),
          ),
          PopupMenuButton<_QueueAction>(
            tooltip: 'Actions de la piste',
            color: _surface,
            icon: const Icon(Icons.more_vert_rounded, color: Colors.white54),
            onSelected: (action) => _handleAction(context, ref, action),
            itemBuilder: (_) => const [
              PopupMenuItem(
                value: _QueueAction.playNow,
                child: Text('Lire maintenant'),
              ),
              PopupMenuItem(
                value: _QueueAction.playNext,
                child: Text('Lire ensuite'),
              ),
              PopupMenuItem(
                value: _QueueAction.bottom,
                child: Text('Déplacer à la fin'),
              ),
              PopupMenuItem(
                value: _QueueAction.artist,
                child: Text('Accéder à l’artiste'),
              ),
              PopupMenuItem(
                value: _QueueAction.album,
                child: Text('Accéder à l’album'),
              ),
              PopupMenuItem(
                value: _QueueAction.playlist,
                child: Text('Ajouter à une playlist'),
              ),
              PopupMenuItem(
                value: _QueueAction.remove,
                child: Text('Retirer de la file'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  Future<void> _handleAction(
    BuildContext context,
    WidgetRef ref,
    _QueueAction action,
  ) async {
    final handler = ref.read(audioHandlerProvider);
    switch (action) {
      case _QueueAction.playNow:
        await handler.skipToQueueItem(index);
      case _QueueAction.playNext:
        await handler.moveQueueItemNext(index);
      case _QueueAction.bottom:
        await handler.moveQueueItemToBottom(index);
      case _QueueAction.artist:
        final key = item.extras?['artistKey'] as String?;
        if (key != null && context.mounted) openArtistDetail(context, key);
      case _QueueAction.album:
        final key = item.extras?['albumKey'] as String?;
        if (key != null && context.mounted) openAlbumDetail(context, key);
      case _QueueAction.playlist:
        final trackId = int.tryParse(item.id);
        if (trackId != null && context.mounted) {
          await showAddTrackToPlaylistSheet(context, trackId: trackId);
        }
      case _QueueAction.remove:
        await handler.removeQueueItemAt(index);
    }
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({
    required this.artUri,
    required this.size,
    required this.radius,
  });

  final Uri? artUri;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: SizedBox.square(
      dimension: size,
      child: artUri == null
          ? const ColoredBox(
              color: Color(0xFF292933),
              child: Icon(Icons.music_note_rounded, color: Colors.white24),
            )
          : AuthenticatedNetworkImage(artUri.toString(), fit: BoxFit.cover),
    ),
  );
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: const BoxDecoration(
              color: _surface,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.queue_music_rounded,
              size: 62,
              color: Colors.white24,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'La file est vide',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Choisis une piste dans ta bibliothèque pour commencer.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white54),
          ),
          const SizedBox(height: 22),
          FilledButton.icon(
            key: const ValueKey('queue-browse-library'),
            onPressed: () => context.go('/library'),
            icon: const Icon(Icons.library_music_rounded),
            label: const Text('Parcourir la bibliothèque'),
          ),
        ],
      ),
    ),
  );
}

String _formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60);
  final seconds = value.inSeconds.remainder(60);
  if (hours > 0) {
    return '$hours:${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')}';
  }
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
