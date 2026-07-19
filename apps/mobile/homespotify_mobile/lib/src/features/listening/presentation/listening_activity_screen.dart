import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/app_config.dart';
import '../../../core/network/authenticated_network_image.dart';
import '../../library/domain/track.dart';
import '../../library/presentation/library_playback_controller.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../data/listening_activity_api.dart';
import '../domain/listening_activity.dart';

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
    return Scaffold(
      appBar: AppBar(title: const Text('Activité d’écoute')),
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: _body(),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _sessions.isEmpty) {
      return ListView(
        children: [
          const SizedBox(height: 160),
          const Icon(Icons.history_toggle_off_rounded, size: 52),
          const SizedBox(height: 16),
          Text(_error!, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Center(
            child: FilledButton(
              onPressed: () => _load(reset: true),
              child: const Text('Réessayer'),
            ),
          ),
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
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      itemCount: entries.length + 1,
      itemBuilder: (context, index) {
        if (index == entries.length) {
          if (_nextCursor == null) return const SizedBox(height: 24);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Center(
              child: _loadingMore
                  ? const CircularProgressIndicator()
                  : OutlinedButton(
                      onPressed: () => _load(reset: false),
                      child: const Text('Afficher plus'),
                    ),
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
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
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
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        enabled: session.track.available,
        contentPadding: const EdgeInsets.all(10),
        leading: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox.square(
            dimension: 54,
            child: coverUrl == null
                ? const ColoredBox(
                    color: Color(0xFF24242D),
                    child: Icon(Icons.music_note_rounded),
                  )
                : AuthenticatedNetworkImage(
                    coverUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const ColoredBox(
                      color: Color(0xFF24242D),
                      child: Icon(Icons.music_note_rounded),
                    ),
                  ),
          ),
        ),
        title: Text(
          session.track.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              session.track.artist,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            if (!session.completed && progress > 0)
              LinearProgressIndicator(value: progress, minHeight: 3),
            const SizedBox(height: 5),
            Text(
              session.completed
                  ? 'Terminé · ${_duration(session.listenedMs)} écoutées'
                  : '${_duration(session.listenedMs)} écoutées',
              style: const TextStyle(fontSize: 11),
            ),
          ],
        ),
        trailing: PopupMenuButton<String>(
          onSelected: (_) => onRestart(),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'restart', child: Text('Recommencer')),
          ],
        ),
        onTap: onTap,
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
      children: const [
        SizedBox(height: 160),
        Icon(Icons.history_rounded, size: 56, color: Colors.white38),
        SizedBox(height: 16),
        Text(
          'Aucune écoute enregistrée',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
        SizedBox(height: 8),
        Text(
          'Vos prochaines écoutes apparaîtront ici.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white54),
        ),
      ],
    );
  }
}
