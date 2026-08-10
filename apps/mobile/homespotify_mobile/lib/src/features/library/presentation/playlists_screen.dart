import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/navigation.dart';
import '../../../core/logging/app_logger.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/home_ui_states.dart';
import '../../../core/widgets/soft_surface.dart';
import '../../player/presentation/widgets/mini_player.dart';
import 'library_playlists.dart';
import 'playlist_dialogs.dart';

class PlaylistsScreen extends ConsumerStatefulWidget {
  const PlaylistsScreen({super.key});

  @override
  ConsumerState<PlaylistsScreen> createState() => _PlaylistsScreenState();
}

class _PlaylistsScreenState extends ConsumerState<PlaylistsScreen> {
  @override
  void initState() {
    super.initState();
    logLibrary('ouverture écran Playlists');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final playlists = ref.watch(playlistsProvider);
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: 'Playlists',
              onBack: () => Navigator.of(context).maybePop(),
              actions: [
                SoftCircle(
                  size: 46,
                  onTap: () => showCreatePlaylistDialog(context),
                  tooltip: 'Créer une playlist',
                  semanticLabel: 'Créer une playlist',
                  child: Icon(
                    Icons.add_rounded,
                    size: 22,
                    color: colors.textPrimary,
                  ),
                ),
              ],
            ),
            Expanded(
              child: playlists.when(
                loading: () => const HomeLoadingSkeleton(rows: 6),
                error: (_, _) => HomeErrorState(
                  message: 'Impossible de charger les playlists du compte.',
                  onRetry: () => ref.invalidate(playlistsProvider),
                ),
                data: (items) => items.isEmpty
                    ? const HomeEmptyState(
                        icon: Icons.queue_music_rounded,
                        title: 'Aucune playlist',
                        message: 'Crée une playlist pour organiser tes pistes.',
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(
                          AppLayout.gutter,
                          6,
                          AppLayout.gutter,
                          18,
                        ),
                        itemCount: items.length,
                        separatorBuilder: (_, _) => const SizedBox(height: 10),
                        itemBuilder: (context, index) {
                          final playlist = items[index];
                          return Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                maxWidth: AppLayout.maxContentWidth,
                              ),
                              child: SoftCard(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 12,
                                ),
                                onTap: () {
                                  logUi(
                                    'tap playlist: id=${playlist.id} '
                                    'nom="${playlist.name}"',
                                  );
                                  openPlaylistDetail(context, playlist.id);
                                },
                                semanticLabel: playlist.name,
                                child: Row(
                                  children: [
                                    Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: colors.clayBlue,
                                        borderRadius: AppRadius.chipRadius,
                                      ),
                                      child: Icon(
                                        Icons.queue_music_rounded,
                                        color: colors.clayBlueInk,
                                      ),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            playlist.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.titleMedium
                                                ?.copyWith(
                                              color: colors.textPrimary,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            '${playlist.trackCount} '
                                            '${playlist.trackCount > 1 ? 'pistes' : 'piste'}',
                                            style: theme.textTheme.bodySmall
                                                ?.copyWith(
                                              color: colors.textSecondary,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      color: colors.textTertiary,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }
}
