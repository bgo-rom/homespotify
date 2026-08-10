import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../app/navigation.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/artwork_thumb.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/soft_surface.dart';
import '../../library/presentation/playlist_dialogs.dart';
import '../audio/homespotify_audio_handler.dart';
import 'player_providers.dart';

/// Écran « File d'attente » — Direction 33, même famille visuelle que le
/// lecteur complet (SoftCard, ArtworkThumb, tokens `context.colors`).
class QueueScreen extends ConsumerWidget {
  const QueueScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
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
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: 'File d’attente',
              subtitle: _headerMeta(
                queue,
                currentIndex,
                position.position,
                playback?.speed ?? 1,
              ),
              onBack: () =>
                  context.canPop() ? context.pop() : context.go('/'),
            ),
            Expanded(
              child: current == null
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
                            padding: const EdgeInsets.fromLTRB(
                              AppLayout.gutter,
                              22,
                              AppLayout.gutter - 10,
                              8,
                            ),
                            child: Row(
                              children: [
                                Text(
                                  'À suivre',
                                  style: Theme.of(context).textTheme.titleLarge
                                      ?.copyWith(color: colors.textPrimary),
                                ),
                                const Spacer(),
                                if (upcoming.isNotEmpty)
                                  TextButton.icon(
                                    key: const ValueKey(
                                      'queue-clear-upcoming',
                                    ),
                                    style: TextButton.styleFrom(
                                      foregroundColor: colors.link,
                                    ),
                                    onPressed: () => _confirmClear(
                                      context,
                                      ref,
                                      colors,
                                    ),
                                    icon: const Icon(Icons.clear_all_rounded),
                                    label: const Text('Vider'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                        if (upcoming.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(
                              child: Text(
                                'Aucune piste à suivre.',
                                style: TextStyle(color: colors.textTertiary),
                              ),
                            ),
                          )
                        else
                          SliverFillRemaining(
                            child: ReorderableListView.builder(
                              buildDefaultDragHandles: false,
                              padding: const EdgeInsets.fromLTRB(
                                AppLayout.gutter - 6,
                                0,
                                AppLayout.gutter - 6,
                                24,
                              ),
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
            ),
          ],
        ),
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

  static Future<void> _confirmClear(
    BuildContext context,
    WidgetRef ref,
    AppColors colors,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: colors.surface,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.cardRadius),
        title: Text(
          'Vider la file à suivre ?',
          style: TextStyle(color: colors.textPrimary),
        ),
        content: Text(
          'La piste en cours continuera sans interruption.',
          style: TextStyle(color: colors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(
              'Annuler',
              style: TextStyle(color: colors.textSecondary),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
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
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter - 6,
        12,
        AppLayout.gutter - 6,
        0,
      ),
      child: SoftCard(
        key: const ValueKey('queue-current-track'),
        padding: const EdgeInsets.all(14),
        onTap: () => openPlayer(context),
        semanticLabel: 'Ouvrir le lecteur complet',
        child: Row(
          children: [
            ArtworkThumb(
              size: 86,
              radius: AppRadius.artwork,
              identity: 'queue-current-${item.id}',
              artUri: item.artUri,
              traceLabel: 'queue current trackId=${item.id}',
            ),
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
                        color: colors.accent,
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'EN COURS DE LECTURE',
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colors.accent,
                          fontWeight: FontWeight.w800,
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
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.textPrimary,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    item.artist ?? 'Artiste inconnu',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 9),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: duration == null || duration == Duration.zero
                          ? 0
                          : (position.inMilliseconds /
                                    duration!.inMilliseconds)
                                .clamp(0.0, 1.0),
                      color: colors.accent,
                      backgroundColor: colors.surfaceSunken,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_formatDuration(position)} / '
                    '${duration == null ? '—' : _formatDuration(duration!)}',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Dismissible(
      key: ValueKey('dismiss-${item.id}-$index'),
      direction: DismissDirection.endToStart,
      background: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.danger,
          borderRadius: AppRadius.cardRadius,
        ),
        child: Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 24),
            child: Icon(Icons.delete_outline_rounded, color: colors.onAccent),
          ),
        ),
      ),
      onDismissed: (_) => ref.read(audioHandlerProvider).removeQueueItemAt(index),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: SoftCard(
          padding: EdgeInsets.zero,
          shadows: colors.clayShadowSmall,
          child: ListTile(
            contentPadding: const EdgeInsets.only(left: 12, right: 4),
            leading: ArtworkThumb(
              size: 48,
              radius: AppRadius.chip,
              identity: 'queue-upcoming-${item.id}-$index',
              artUri: item.artUri,
              traceLabel: 'queue upcoming trackId=${item.id}',
            ),
            title: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
            subtitle: Text(
              '${item.artist ?? 'Artiste inconnu'} · '
              '${item.duration == null ? '—' : _formatDuration(item.duration!)} · '
              '${item.extras?['origin'] ?? 'Bibliothèque'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.labelMedium?.copyWith(
                color: colors.textSecondary,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ReorderableDragStartListener(
                  index: reorderIndex,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      Icons.drag_handle_rounded,
                      color: colors.textTertiary,
                    ),
                  ),
                ),
                PopupMenuButton<_QueueAction>(
                  tooltip: 'Actions de la piste',
                  color: colors.surfaceRaised,
                  shape: RoundedRectangleBorder(
                    borderRadius: AppRadius.cardRadius,
                  ),
                  icon: Icon(
                    Icons.more_vert_rounded,
                    color: colors.textSecondary,
                  ),
                  onSelected: (action) => _handleAction(context, ref, action),
                  itemBuilder: (menuContext) => [
                    _item(menuContext, 'Lire maintenant'),
                    _item(menuContext, 'Lire ensuite'),
                    _item(menuContext, 'Déplacer à la fin'),
                    _item(menuContext, 'Accéder à l’artiste'),
                    _item(menuContext, 'Accéder à l’album'),
                    _item(menuContext, 'Ajouter à une playlist'),
                    _item(menuContext, 'Retirer de la file'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  PopupMenuItem<_QueueAction> _item(BuildContext context, String label) {
    final colors = context.colors;
    final action = switch (label) {
      'Lire maintenant' => _QueueAction.playNow,
      'Lire ensuite' => _QueueAction.playNext,
      'Déplacer à la fin' => _QueueAction.bottom,
      'Accéder à l’artiste' => _QueueAction.artist,
      'Accéder à l’album' => _QueueAction.album,
      'Ajouter à une playlist' => _QueueAction.playlist,
      _ => _QueueAction.remove,
    };
    return PopupMenuItem<_QueueAction>(
      value: action,
      child: Text(label, style: TextStyle(color: colors.textPrimary)),
    );
  }

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

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue();

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SoftCircle(
              size: 110,
              child: Icon(
                Icons.queue_music_rounded,
                size: 52,
                color: colors.textTertiary,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'La file est vide',
              style: theme.textTheme.headlineSmall?.copyWith(
                color: colors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choisis une piste dans ta bibliothèque pour commencer.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.textSecondary,
              ),
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
