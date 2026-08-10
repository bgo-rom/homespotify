import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/authenticated_network_image.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../../../core/widgets/clay_header.dart';
import '../../../core/widgets/home_ui_states.dart';
import '../../../core/widgets/soft_surface.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/library_playback_controller.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/widgets/mini_player.dart';
import '../data/listening_activity_api.dart';
import '../domain/listening_activity.dart';

/// Écran « Activité d'écoute » — refonte Direction 33. Même grammaire que la
/// Bibliothèque : pochette, titre/artiste, progression, sections par jour.
class ListeningActivityScreen extends ConsumerStatefulWidget {
  const ListeningActivityScreen({super.key});

  @override
  ConsumerState<ListeningActivityScreen> createState() =>
      _ListeningActivityScreenState();
}

class _ListeningActivityScreenState
    extends ConsumerState<ListeningActivityScreen> {
  final List<ListeningSession> _sessions = [];
  String? _nextCursor;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<void> _load({required bool reset}) async {
    if (reset) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else {
      if (_loadingMore || _nextCursor == null) return;
      setState(() => _loadingMore = true);
    }
    try {
      final page = await ref
          .read(listeningActivityApiProvider)
          .fetchActivity(cursor: reset ? null : _nextCursor);
      if (!mounted) return;
      setState(() {
        if (reset) _sessions.clear();
        _sessions.addAll(page.items);
        _nextCursor = page.nextCursor;
        _loading = false;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Impossible de charger l’activité d’écoute.';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _play(ListeningSession session, {required bool resume}) async {
    if (!session.track.available) return;
    final durationMs = session.durationMs ?? session.track.durationMs;
    final track = Track(
      id: session.track.id,
      title: session.track.title,
      artist: session.track.artist,
      album: session.track.album,
      hasCover: session.track.coverUrl != null,
      durationSeconds: durationMs == null ? null : durationMs / 1000,
    );
    try {
      await ref
          .read(libraryPlaybackControllerProvider)
          .playQueue(tracks: [track], initialIndex: 0);
      if (resume && durationMs != null) {
        final safePosition =
            session.positionMs > 0 && session.positionMs < durationMs
            ? session.positionMs
            : 0;
        if (safePosition > 0) {
          await ref
              .read(audioHandlerProvider)
              .seek(Duration(milliseconds: safePosition));
        }
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('La lecture n’a pas pu démarrer.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            ClayHeader(
              title: 'Activité d’écoute',
              onBack: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: RefreshIndicator(
                color: colors.accent,
                backgroundColor: colors.surface,
                onRefresh: () => _load(reset: true),
                child: _body(),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: const MiniPlayer(),
    );
  }

  Widget _body() {
    final colors = context.colors;
    if (_loading) {
      return Center(
        child: CircularProgressIndicator(color: colors.accent),
      );
    }
    if (_error != null && _sessions.isEmpty) {
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          HomeErrorState(message: _error!, onRetry: () => _load(reset: true)),
        ],
      );
    }
    if (_sessions.isEmpty) {
      return const _EmptyActivity();
    }
    final grouped = <DateTime, List<ListeningSession>>{};
    for (final session in _sessions) {
      final day = DateTime(
        session.lastActivityAt.year,
        session.lastActivityAt.month,
        session.lastActivityAt.day,
      );
      grouped.putIfAbsent(day, () => []).add(session);
    }
    final entries = grouped.entries.toList(growable: false);
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(
        AppLayout.gutter,
        4,
        AppLayout.gutter,
        32,
      ),
      itemCount: entries.length + 1,
      itemBuilder: (context, index) {
        if (index == entries.length) {
          if (_nextCursor == null) return const SizedBox(height: 24);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _loadingMore
                  ? CircularProgressIndicator(color: colors.accent)
                  : _LoadMoreButton(onTap: () => _load(reset: false)),
            ),
          );
        }
        final entry = entries[index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
              child: Text(
                _dayLabel(entry.key),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: colors.textPrimary,
                ),
              ),
            ),
            ...entry.value.map(
              (session) => _ActivityTile(
                session: session,
                onTap: () => _play(session, resume: session.canResume),
                onRestart: () => _play(session, resume: false),
              ),
            ),
          ],
        );
      },
    );
  }

  String _dayLabel(DateTime day) {
    final today = DateTime.now();
    final midnight = DateTime(today.year, today.month, today.day);
    if (day == midnight) return 'Aujourd’hui';
    if (day == midnight.subtract(const Duration(days: 1))) return 'Hier';
    return '${day.day.toString().padLeft(2, '0')}/'
        '${day.month.toString().padLeft(2, '0')}/${day.year}';
  }
}

/// Bouton discret « Afficher plus » — pastille sculptée, pas un bouton
/// Material contouré générique.
class _LoadMoreButton extends StatelessWidget {
  const _LoadMoreButton({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: AppRadius.pillRadius,
        boxShadow: colors.clayShadowSmall,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: AppRadius.pillRadius,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 11),
            child: Text(
              'Afficher plus',
              style: theme.textTheme.labelLarge?.copyWith(
                color: colors.textPrimary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Ligne d'écoute : pochette, titre/artiste, progression, durée écoutée.
class _ActivityTile extends StatelessWidget {
  const _ActivityTile({
    required this.session,
    required this.onTap,
    required this.onRestart,
  });

  final ListeningSession session;
  final VoidCallback onTap;
  final VoidCallback onRestart;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final theme = Theme.of(context);
    final duration = session.durationMs ?? session.track.durationMs;
    final progress = duration == null || duration <= 0
        ? 0.0
        : (session.positionMs / duration).clamp(0.0, 1.0);
    final cover = session.track.coverUrl;
    final coverUrl = cover == null
        ? null
        : cover.startsWith('http')
        ? cover
        : '${AppConfig.apiBaseUrl}$cover';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: SoftCard(
        onTap: session.track.available ? onTap : null,
        padding: const EdgeInsets.all(10),
        child: Opacity(
          // Piste indisponible (source retirée) : même grammaire que la
          // Bibliothèque, atténuée plutôt que masquée.
          opacity: session.track.available ? 1 : 0.45,
          child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ClipRRect(
              borderRadius: AppRadius.artworkRadius,
              child: SizedBox.square(
                dimension: 54,
                child: coverUrl == null
                    ? ColoredBox(
                        color: colors.surfaceSunken,
                        child: Icon(
                          Icons.music_note_rounded,
                          color: colors.textTertiary,
                        ),
                      )
                    : AuthenticatedNetworkImage(
                        coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => ColoredBox(
                          color: colors.surfaceSunken,
                          child: Icon(
                            Icons.music_note_rounded,
                            color: colors.textTertiary,
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    session.track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: colors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    session.track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  if (!session.completed && progress > 0) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        backgroundColor: colors.surfaceSunken,
                        color: colors.accent,
                      ),
                    ),
                    const SizedBox(height: 5),
                  ],
                  Text(
                    session.completed
                        ? 'Terminé · ${_duration(session.listenedMs)} écoutées'
                        : '${_duration(session.listenedMs)} écoutées',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colors.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: colors.textSecondary),
              onSelected: (_) => onRestart(),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'restart', child: Text('Recommencer')),
              ],
            ),
          ],
          ),
        ),
      ),
    );
  }

  static String _duration(int milliseconds) {
    final duration = Duration(milliseconds: milliseconds);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _EmptyActivity extends StatelessWidget {
  const _EmptyActivity();

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: const [
        HomeEmptyState(
          icon: Icons.history_rounded,
          title: 'Aucune écoute enregistrée',
          message: 'Vos prochaines écoutes apparaîtront ici.',
        ),
      ],
    );
  }
}
