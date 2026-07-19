import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/remote_search_controller.dart';
import '../domain/remote_track.dart';

const Color _background = Color(0xFF0D0D10);
const Color _surface = Color(0xFF1A1A22);
const Color _accent = Color(0xFF1DB954);
const Color _error = Color(0xFFE57373);

class RemoteSearchScreen extends ConsumerStatefulWidget {
  const RemoteSearchScreen({super.key});

  @override
  ConsumerState<RemoteSearchScreen> createState() => _RemoteSearchScreenState();
}

class _RemoteSearchScreenState extends ConsumerState<RemoteSearchScreen> {
  final TextEditingController _queryController = TextEditingController();

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  Future<void> _search() {
    FocusScope.of(context).unfocus();
    return ref
        .read(remoteSearchControllerProvider.notifier)
        .search(_queryController.text);
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(remoteSearchControllerProvider);
    return Scaffold(
      backgroundColor: _background,
      appBar: AppBar(
        backgroundColor: _background,
        foregroundColor: Colors.white,
        title: const Text(
          'Recherche distante',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('remote-search-field'),
                    controller: _queryController,
                    enabled: !state.loading,
                    textInputAction: TextInputAction.search,
                    autocorrect: false,
                    style: const TextStyle(color: Colors.white),
                    decoration: InputDecoration(
                      hintText: 'Titre ou artiste',
                      hintStyle: const TextStyle(color: Colors.white38),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: _accent,
                      ),
                      filled: true,
                      fillColor: _surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  height: 56,
                  child: FilledButton(
                    key: const ValueKey('remote-search-submit'),
                    style: FilledButton.styleFrom(
                      backgroundColor: _accent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: state.loading ? null : _search,
                    child: state.loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.black54,
                            ),
                          )
                        : const Text('Rechercher'),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: _RemoteSearchBody(state: state)),
        ],
      ),
    );
  }
}

class _RemoteSearchBody extends ConsumerWidget {
  const _RemoteSearchBody({required this.state});

  final RemoteSearchState state;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (state.loading) {
      return const Center(child: CircularProgressIndicator(color: _accent));
    }
    if (state.error != null) {
      return _MessageState(
        icon: Icons.cloud_off_rounded,
        message: state.error!,
        color: _error,
      );
    }
    if (!state.searched) {
      return const _MessageState(
        icon: Icons.travel_explore_rounded,
        message:
            'Recherche une piste sur le nœud privé configuré par ton serveur.',
      );
    }
    if (state.results.isEmpty) {
      return const _MessageState(
        icon: Icons.search_off_rounded,
        message: 'Aucune piste distante trouvée.',
      );
    }
    return ListView.separated(
      key: const ValueKey('remote-search-results'),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 28),
      itemCount: state.results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final track = state.results[index];
        final progress = state.imports[track.trackId];
        return _RemoteTrackTile(track: track, progress: progress);
      },
    );
  }
}

class _RemoteTrackTile extends ConsumerWidget {
  const _RemoteTrackTile({required this.track, required this.progress});

  final RemoteTrack track;
  final RemoteImportState? progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DecoratedBox(
      key: ValueKey('remote-track-${track.trackId}'),
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white10),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            _RemoteCover(url: track.coverUrl),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    track.artist,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white54),
                  ),
                  if (progress?.message != null) ...[
                    const SizedBox(height: 7),
                    Text(
                      progress!.message!,
                      key: ValueKey('remote-import-status-${track.trackId}'),
                      style: TextStyle(
                        color: progress!.phase == RemoteImportPhase.failed
                            ? _error
                            : progress!.phase ==
                                  RemoteImportPhase.readyForImport
                            ? _accent
                            : const Color(0xFF64B5F6),
                        fontSize: 12,
                        height: 1.25,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            _ImportAction(trackId: track.trackId, progress: progress),
          ],
        ),
      ),
    );
  }
}

class _ImportAction extends ConsumerWidget {
  const _ImportAction({required this.trackId, required this.progress});

  final String trackId;
  final RemoteImportState? progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phase = progress?.phase ?? RemoteImportPhase.idle;
    if (progress?.isActive ?? false) {
      return SizedBox(
        key: ValueKey('remote-import-progress-$trackId'),
        width: 32,
        height: 32,
        child: const Padding(
          padding: EdgeInsets.all(5),
          child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
        ),
      );
    }
    if (phase == RemoteImportPhase.readyForImport) {
      return Icon(
        Icons.check_circle_rounded,
        key: ValueKey('remote-import-ready-$trackId'),
        color: _accent,
      );
    }
    if (phase == RemoteImportPhase.monitoringPaused) {
      return IconButton(
        key: ValueKey('remote-import-resume-$trackId'),
        tooltip: 'Reprendre le suivi',
        color: _accent,
        onPressed: () => ref
            .read(remoteSearchControllerProvider.notifier)
            .resumeMonitoring(trackId),
        icon: const Icon(Icons.refresh_rounded),
      );
    }
    return OutlinedButton(
      key: ValueKey('remote-import-$trackId'),
      style: OutlinedButton.styleFrom(
        foregroundColor: phase == RemoteImportPhase.failed ? _error : _accent,
        side: BorderSide(
          color: phase == RemoteImportPhase.failed ? _error : _accent,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      onPressed: () => ref
          .read(remoteSearchControllerProvider.notifier)
          .importTrack(trackId),
      child: Text(phase == RemoteImportPhase.failed ? 'Réessayer' : 'Importer'),
    );
  }
}

class _RemoteCover extends StatelessWidget {
  const _RemoteCover({required this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    final placeholder = Container(
      width: 58,
      height: 58,
      decoration: BoxDecoration(
        color: Colors.white10,
        borderRadius: BorderRadius.circular(10),
      ),
      child: const Icon(Icons.music_note_rounded, color: Colors.white38),
    );
    final value = url;
    if (value == null || value.isEmpty) return placeholder;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Image.network(
        value,
        width: 58,
        height: 58,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.message,
    this.color = Colors.white38,
  });

  final IconData icon;
  final String message;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 44),
            const SizedBox(height: 14),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}
