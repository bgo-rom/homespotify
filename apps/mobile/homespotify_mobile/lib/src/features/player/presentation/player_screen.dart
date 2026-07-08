import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/homespotify_audio_handler.dart';
import 'player_providers.dart';
import 'widgets/seek_bar.dart';

/// Écran de lecture principal (page d'accueil de l'app).
///
/// Sombre, centré, branché sur les streams de [HomeSpotifyAudioHandler] via
/// Riverpod. Aucune duplication d'état : tout vient des `StreamProvider`.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  static const Duration _seekStep = Duration(seconds: 10);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    final playback = ref.watch(playbackStateProvider).asData?.value;
    final positionData =
        ref.watch(positionDataProvider).asData?.value ??
        PlayerPositionData.zero;

    final hasTrack = mediaItem != null;
    final playing = playback?.playing ?? false;
    final processing = playback?.processingState;
    final isBusy =
        processing == AudioProcessingState.loading ||
        processing == AudioProcessingState.buffering;

    return Scaffold(
      backgroundColor: const Color(0xFF0D0D10),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF20202A), Color(0xFF0D0D10)],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 12),
                Text(
                  'EN LECTURE',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                    letterSpacing: 2,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(flex: 2),
                _Artwork(artUri: mediaItem?.artUri),
                const Spacer(),
                _TrackInfo(
                  title: mediaItem?.title ?? 'Aucune piste en lecture',
                  artist: mediaItem?.artist ?? '—',
                  dimmed: !hasTrack,
                ),
                const SizedBox(height: 24),
                SeekBar(
                  position: positionData.position,
                  bufferedPosition: positionData.bufferedPosition,
                  duration: positionData.duration,
                  onSeek: hasTrack
                      ? (pos) => ref.read(audioHandlerProvider).seek(pos)
                      : null,
                ),
                const SizedBox(height: 8),
                _Controls(
                  playing: playing,
                  isBusy: isBusy,
                  enabled: hasTrack,
                  onPlayPause: () {
                    final handler = ref.read(audioHandlerProvider);
                    playing ? handler.pause() : handler.play();
                  },
                  onStop: () => ref.read(audioHandlerProvider).stop(),
                  onSeekBackward: () => _seekBy(ref, -_seekStep, positionData),
                  onSeekForward: () => _seekBy(ref, _seekStep, positionData),
                ),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _seekBy(WidgetRef ref, Duration delta, PlayerPositionData data) {
    if (data.duration <= Duration.zero) return;
    var target = data.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > data.duration) target = data.duration;
    ref.read(audioHandlerProvider).seek(target);
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({this.artUri});

  final Uri? artUri;

  @override
  Widget build(BuildContext context) {
    final side = (MediaQuery.sizeOf(context).width - 48).clamp(0.0, 340.0);
    return SizedBox(
      width: side,
      height: side,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: const [
            BoxShadow(
              color: Colors.black54,
              blurRadius: 32,
              offset: Offset(0, 12),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: artUri == null
              ? const _ArtworkPlaceholder()
              : Image.network(
                  artUri.toString(),
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const _ArtworkPlaceholder(),
                  loadingBuilder: (context, child, progress) =>
                      progress == null ? child : const _ArtworkPlaceholder(),
                ),
        ),
      ),
    );
  }
}

class _ArtworkPlaceholder extends StatelessWidget {
  const _ArtworkPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF33333F), Color(0xFF1A1A22)],
        ),
      ),
      child: Center(
        child: Icon(Icons.music_note_rounded, size: 88, color: Colors.white24),
      ),
    );
  }
}

class _TrackInfo extends StatelessWidget {
  const _TrackInfo({
    required this.title,
    required this.artist,
    required this.dimmed,
  });

  final String title;
  final String artist;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          title,
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: dimmed ? Colors.white54 : Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          artist,
          maxLines: 1,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white60, fontSize: 15),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  const _Controls({
    required this.playing,
    required this.isBusy,
    required this.enabled,
    required this.onPlayPause,
    required this.onStop,
    required this.onSeekBackward,
    required this.onSeekForward,
  });

  final bool playing;
  final bool isBusy;
  final bool enabled;
  final VoidCallback onPlayPause;
  final VoidCallback onStop;
  final VoidCallback onSeekBackward;
  final VoidCallback onSeekForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundIcon(
          icon: Icons.replay_10_rounded,
          onPressed: enabled ? onSeekBackward : null,
        ),
        _PlayPauseButton(
          playing: playing,
          isBusy: isBusy,
          onPressed: enabled ? onPlayPause : null,
        ),
        _RoundIcon(
          icon: Icons.stop_rounded,
          onPressed: enabled ? onStop : null,
        ),
        _RoundIcon(
          icon: Icons.forward_10_rounded,
          onPressed: enabled ? onSeekForward : null,
        ),
      ],
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, this.onPressed});

  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      iconSize: 32,
      color: Colors.white,
      disabledColor: Colors.white24,
      icon: Icon(icon),
    );
  }
}

class _PlayPauseButton extends StatelessWidget {
  const _PlayPauseButton({
    required this.playing,
    required this.isBusy,
    this.onPressed,
  });

  final bool playing;
  final bool isBusy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: enabled ? const Color(0xFF1DB954) : Colors.white12,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox(
          width: 72,
          height: 72,
          child: isBusy
              ? const Padding(
                  padding: EdgeInsets.all(22),
                  child: CircularProgressIndicator(
                    strokeWidth: 3,
                    color: Colors.white,
                  ),
                )
              : Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  size: 40,
                  color: enabled ? Colors.black : Colors.white38,
                ),
        ),
      ),
    );
  }
}
