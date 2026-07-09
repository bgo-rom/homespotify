import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../audio/homespotify_audio_handler.dart';
import 'player_providers.dart';
import 'widgets/seek_bar.dart';

const Color _accent = Color(0xFF1DB954);

/// Écran principal de lecture.
///
/// Sombre, centré, branché sur les streams de [HomeSpotifyAudioHandler] via
/// Riverpod. Le tick de position est isolé dans [_ProgressBar] pour ne pas
/// reconstruire la pochette/les contrôles ~5 fois par seconde.
class PlayerScreen extends ConsumerWidget {
  const PlayerScreen({super.key});

  static const Duration _seekStep = Duration(seconds: 10);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    final playback = ref.watch(playbackStateProvider).asData?.value;
    final queue = ref.watch(queueProvider).asData?.value ?? const <MediaItem>[];

    final hasTrack = mediaItem != null;
    final playing = playback?.playing ?? false;
    final processing = playback?.processingState;
    final isBusy =
        processing == AudioProcessingState.loading ||
        processing == AudioProcessingState.buffering;
    final hasError = processing == AudioProcessingState.error;
    final queueIndex = playback?.queueIndex ?? -1;
    final canSkipPrevious = queueIndex > 0 && queueIndex < queue.length;
    final canSkipNext = queueIndex >= 0 && queueIndex < queue.length - 1;

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
                Row(
                  children: [
                    IconButton(
                      tooltip: 'Retour',
                      onPressed: () =>
                          context.canPop() ? context.pop() : context.go('/'),
                      color: Colors.white,
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: Text(
                        'EN LECTURE',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 12,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Arrêter',
                      onPressed: hasTrack
                          ? () => ref.read(audioHandlerProvider).stop()
                          : null,
                      color: Colors.white,
                      disabledColor: Colors.white24,
                      icon: const Icon(Icons.stop_rounded),
                    ),
                  ],
                ),
                if (isBusy) ...[
                  const SizedBox(height: 8),
                  _PlaybackStatus(processingState: processing),
                ],
                const Spacer(flex: 2),
                _Artwork(artUri: mediaItem?.artUri),
                const Spacer(),
                _TrackInfo(
                  title: mediaItem?.title ?? 'Aucune piste en lecture',
                  artist: mediaItem?.artist ?? '—',
                  dimmed: !hasTrack,
                ),
                if (hasError) _ErrorBanner(message: playback?.errorMessage),
                const SizedBox(height: 24),
                _ProgressBar(enabled: hasTrack),
                const SizedBox(height: 8),
                _Controls(
                  playing: playing,
                  isBusy: isBusy,
                  enabled: hasTrack,
                  onPlayPause: isBusy && !playing
                      ? null
                      : hasError
                      ? null
                      : () {
                          final handler = ref.read(audioHandlerProvider);
                          playing ? handler.pause() : handler.play();
                        },
                  onPrevious: canSkipPrevious
                      ? () => ref.read(audioHandlerProvider).skipToPrevious()
                      : null,
                  onNext: canSkipNext
                      ? () => ref.read(audioHandlerProvider).skipToNext()
                      : null,
                  onSeekBackward: () => _seekBy(ref, -_seekStep),
                  onSeekForward: () => _seekBy(ref, _seekStep),
                ),
                const SizedBox(height: 8),
                const _VolumeControl(),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _seekBy(WidgetRef ref, Duration delta) {
    final data = ref.read(positionDataProvider).asData?.value;
    if (data == null || data.duration <= Duration.zero) return;
    var target = data.position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > data.duration) target = data.duration;
    ref.read(audioHandlerProvider).seek(target);
  }
}

/// Barre de progression isolée : seul ce widget se reconstruit à chaque tick.
class _ProgressBar extends ConsumerWidget {
  const _ProgressBar({required this.enabled});

  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data =
        ref.watch(positionDataProvider).asData?.value ??
        PlayerPositionData.zero;
    return SeekBar(
      position: data.position,
      bufferedPosition: data.bufferedPosition,
      duration: data.duration,
      onSeek: enabled
          ? (pos) => ref.read(audioHandlerProvider).seek(pos)
          : null,
    );
  }
}

/// Volume interne du lecteur, borné à 0–100 % sans gain supérieur à l'unité.
class _VolumeControl extends ConsumerWidget {
  const _VolumeControl();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volume = (ref.watch(volumeProvider).asData?.value ?? 1.0)
        .clamp(0.0, 1.0)
        .toDouble();
    return Row(
      children: [
        Icon(
          volume <= 0.0 ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          color: Colors.white54,
          size: 20,
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              activeTrackColor: Colors.white70,
              inactiveTrackColor: Colors.white24,
              thumbColor: Colors.white,
              overlayColor: const Color(0x291DB954),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: volume,
              onChanged: (v) => ref.read(audioHandlerProvider).setVolume(v),
            ),
          ),
        ),
        SizedBox(
          width: 44,
          child: Text(
            '${(volume * 100).round()} %',
            textAlign: TextAlign.end,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({this.message});

  final String? message;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFE57373),
            size: 16,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              message ?? 'Erreur audio pendant la lecture.',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Color(0xFFE57373), fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaybackStatus extends StatelessWidget {
  const _PlaybackStatus({required this.processingState});

  final AudioProcessingState? processingState;

  @override
  Widget build(BuildContext context) {
    final label = processingState == AudioProcessingState.buffering
        ? 'Mise en tampon audio...'
        : 'Preparation de la lecture...';
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2, color: _accent),
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  const _Artwork({this.artUri});

  final Uri? artUri;

  @override
  Widget build(BuildContext context) {
    final side = (MediaQuery.sizeOf(context).width - 48).clamp(0.0, 340.0);
    final cacheSide = (side * MediaQuery.devicePixelRatioOf(context)).round();
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
                  cacheWidth: cacheSide,
                  cacheHeight: cacheSide,
                  filterQuality: FilterQuality.medium,
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
    required this.onPrevious,
    required this.onNext,
    required this.onSeekBackward,
    required this.onSeekForward,
  });

  final bool playing;
  final bool isBusy;
  final bool enabled;
  final VoidCallback? onPlayPause;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback onSeekBackward;
  final VoidCallback onSeekForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundIcon(
          tooltip: 'Piste précédente',
          icon: Icons.skip_previous_rounded,
          onPressed: enabled ? onPrevious : null,
        ),
        _RoundIcon(
          tooltip: 'Reculer de 10 secondes',
          icon: Icons.replay_10_rounded,
          onPressed: enabled ? onSeekBackward : null,
        ),
        _PlayPauseButton(
          playing: playing,
          isBusy: isBusy,
          onPressed: enabled ? onPlayPause : null,
        ),
        _RoundIcon(
          tooltip: 'Avancer de 10 secondes',
          icon: Icons.forward_10_rounded,
          onPressed: enabled ? onSeekForward : null,
        ),
        _RoundIcon(
          tooltip: 'Piste suivante',
          icon: Icons.skip_next_rounded,
          onPressed: enabled ? onNext : null,
        ),
      ],
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.tooltip, required this.icon, this.onPressed});

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
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
      color: enabled ? _accent : Colors.white12,
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
