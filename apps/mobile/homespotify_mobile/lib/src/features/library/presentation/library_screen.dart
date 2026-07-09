import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../player/audio/homespotify_audio_handler.dart';
import '../data/library_api.dart';
import '../domain/track.dart';

const Color _bg = Color(0xFF0D0D10);
const Color _accent = Color(0xFF1DB954);

/// Écran bibliothèque : liste les pistes du serveur, lance la lecture au tap.
class LibraryScreen extends ConsumerWidget {
  const LibraryScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final library = ref.watch(libraryProvider);

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Bibliothèque',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          IconButton(
            tooltip: 'Lecteur',
            icon: const Icon(Icons.music_note_rounded),
            onPressed: () => context.push('/player'),
          ),
        ],
      ),
      body: library.when(
        loading: () =>
            const Center(child: CircularProgressIndicator(color: _accent)),
        error: (error, _) => _ErrorState(
          message: error is LibraryApiException
              ? error.message
              : 'Erreur inattendue.',
          onRetry: () => ref.invalidate(libraryProvider),
        ),
        data: (tracks) => tracks.isEmpty
            ? const _EmptyState()
            : RefreshIndicator(
                color: _accent,
                backgroundColor: _bg,
                onRefresh: () => ref.refresh(libraryProvider.future),
                child: Builder(
                  builder: (context) {
                    final api = ref.read(libraryApiProvider);
                    return ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: tracks.length,
                      itemBuilder: (context, i) {
                        final track = tracks[i];
                        return _TrackTile(
                          track: track,
                          coverUrl: track.hasCover
                              ? api.coverUri(track.id).toString()
                              : null,
                          onTap: () => _playTrack(context, ref, track),
                        );
                      },
                    );
                  },
                ),
              ),
      ),
    );
  }

  Future<void> _playTrack(
    BuildContext context,
    WidgetRef ref,
    Track track,
  ) async {
    final api = ref.read(libraryApiProvider);
    final handler = ref.read(audioHandlerProvider);
    try {
      await handler.setTrack(
        trackId: '${track.id}',
        streamUri: api.streamUri(track.id),
        title: track.title,
        artist: track.artist,
        album: track.album.isEmpty ? null : track.album,
        artUri: track.hasCover ? api.coverUri(track.id) : null,
        duration: track.duration,
      );
      await handler.play();
      if (context.mounted) context.push('/player');
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lecture impossible de « ${track.title} ». '
              'Vérifie que le serveur est accessible.',
            ),
          ),
        );
      }
    }
  }
}

class _TrackTile extends StatelessWidget {
  const _TrackTile({
    required this.track,
    required this.coverUrl,
    required this.onTap,
  });

  final Track track;
  final String? coverUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final subtitle = [
      track.artist,
      if (track.album.isNotEmpty) track.album,
    ].join(' · ');

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: _Thumbnail(url: coverUrl),
      title: Text(
        track.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: Row(
          children: [
            if (track.formatLabel != null) ...[
              _FormatChip(label: track.formatLabel!),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white54, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
      trailing: _TrailingMeta(
        duration: track.duration,
        specs: track.quality?.shortLabel,
      ),
    );
  }
}

/// Durée + specs (kHz/bit) alignées à droite, sur deux lignes.
class _TrailingMeta extends StatelessWidget {
  const _TrailingMeta({required this.duration, required this.specs});

  final Duration? duration;
  final String? specs;

  @override
  Widget build(BuildContext context) {
    if (duration == null && specs == null) return const SizedBox.shrink();
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        if (duration != null)
          Text(
            _formatDuration(duration!),
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        if (specs != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              specs!,
              style: const TextStyle(color: Colors.white30, fontSize: 10.5),
            ),
          ),
      ],
    );
  }
}

/// Petite pastille de format : FLAC (accent) ou WAV (neutre).
class _FormatChip extends StatelessWidget {
  const _FormatChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final isFlac = label == 'FLAC';
    final color = isFlac ? _accent : Colors.white54;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }
}

class _Thumbnail extends StatelessWidget {
  const _Thumbnail({this.url});

  final String? url;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 52,
        height: 52,
        child: url == null
            ? const _ThumbnailPlaceholder()
            : Image.network(
                url!,
                fit: BoxFit.cover,
                cacheWidth: 104,
                gaplessPlayback: true,
                errorBuilder: (_, _, _) => const _ThumbnailPlaceholder(),
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const _ThumbnailPlaceholder(),
              ),
      ),
    );
  }
}

class _ThumbnailPlaceholder extends StatelessWidget {
  const _ThumbnailPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF23232B),
      child: Icon(Icons.music_note_rounded, color: Colors.white24, size: 24),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.library_music_outlined, size: 64, color: Colors.white24),
            SizedBox(height: 16),
            Text(
              'Aucune piste dans la bibliothèque',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            SizedBox(height: 8),
            Text(
              'Importe des fichiers WAV ou FLAC côté serveur, puis rafraîchis.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white38, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.cloud_off_rounded,
              size: 64,
              color: Colors.white24,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 15),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: _accent,
                foregroundColor: Colors.black,
              ),
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Réessayer'),
            ),
          ],
        ),
      ),
    );
  }
}

String _formatDuration(Duration d) {
  final minutes = d.inMinutes;
  final seconds = (d.inSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}
