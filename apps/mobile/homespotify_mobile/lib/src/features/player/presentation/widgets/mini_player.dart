import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/navigation.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_shapes.dart';
import '../../../../core/theme/home_design.dart';
import '../../../../core/widgets/artwork_thumb.dart';
import '../../../../core/widgets/soft_surface.dart';
import '../../audio/homespotify_audio_handler.dart';
import '../player_providers.dart';

String? _lastMiniArtworkTrace;

void _traceMiniArtwork(MediaItem mediaItem) {
  if (!kDebugMode) return;
  final uri = mediaItem.artUri;
  final key = '${mediaItem.id}|$uri';
  if (_lastMiniArtworkTrace == key) return;
  _lastMiniArtworkTrace = key;
  debugPrint(
    '[ARTWORK_TRACE] F mini-player trackId=${mediaItem.id} '
    'mediaItemId=${mediaItem.id} artUri=${uri ?? 'null'} '
    'scheme=${uri?.scheme.isEmpty ?? true ? 'null' : uri!.scheme} '
    'widget=${uri == null ? 'placeholder' : 'AuthenticatedNetworkImage'} '
    'fallback=${uri == null} reason=${uri == null ? 'artUri_null' : 'none'}',
  );
}

/// Mini-player réactif partagé par les pages principales et les écrans détail.
/// Les ticks de position sont isolés dans [_MiniProgress].
///
/// Direction 33 : carte flottante sculptée, plus de bandeau plein cadre.
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key, this.safeAreaBottom = true});

  final bool safeAreaBottom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    if (mediaItem == null) return const SizedBox.shrink();
    _traceMiniArtwork(mediaItem);

    final colors = context.colors;
    final theme = Theme.of(context);
    final playback = ref.watch(playbackStateProvider).asData?.value;
    final playing = playback?.playing ?? false;
    final speed = playback?.speed ?? 1;
    final processing = playback?.processingState;
    final isBusy =
        processing == AudioProcessingState.loading ||
        processing == AudioProcessingState.buffering;
    final queue = ref.watch(queueProvider).asData?.value ?? const <MediaItem>[];
    final queueIndex = playback?.queueIndex ?? -1;
    final wrap =
        playback?.shuffleMode == AudioServiceShuffleMode.all ||
        playback?.repeatMode == AudioServiceRepeatMode.all;
    final canSkipPrevious =
        queueIndex >= 0 &&
        queueIndex < queue.length &&
        queue.length > 1 &&
        (wrap || queueIndex > 0);
    final canSkipNext =
        queueIndex >= 0 &&
        queue.length > 1 &&
        (wrap || queueIndex < queue.length - 1);

    return SafeArea(
      top: false,
      bottom: safeAreaBottom,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
        child: SoftCard(
          radius: AppRadius.tile,
          shadows: colors.clayShadowFloating,
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final showPrevious = constraints.maxWidth >= 330;
                  return Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          borderRadius: AppRadius.chipRadius,
                          onTap: () {
                            logUi('tap mini-player (ouvrir lecteur complet)');
                            openPlayer(context);
                          },
                          child: Row(
                            children: [
                              ArtworkThumb(
                                size: 46,
                                radius: 14,
                                identity: 'mini-${mediaItem.id}',
                                artUri: mediaItem.artUri,
                                traceLabel:
                                    'mini-player trackId=${mediaItem.id}',
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: AnimatedSwitcher(
                                  duration: HomeDesign.animationDuration(
                                    context,
                                    HomeDesign.stateAnimation,
                                  ),
                                  switchInCurve: HomeDesign.animationCurve,
                                  transitionBuilder: (child, animation) =>
                                      FadeTransition(
                                        opacity: animation,
                                        child: child,
                                      ),
                                  child: Column(
                                    key: ValueKey<String>(
                                      'mini-metadata-${mediaItem.id}',
                                    ),
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        mediaItem.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.titleMedium
                                            ?.copyWith(
                                              fontSize: 14.5,
                                              color: colors.textPrimary,
                                            ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        speed == 1
                                            ? (mediaItem.artist ?? '—')
                                            : '${mediaItem.artist ?? '—'} · ${speed.toStringAsFixed(2)}x',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              fontSize: 12,
                                              color: colors.textSecondary,
                                            ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (showPrevious)
                        IconButton(
                          tooltip: 'Piste précédente',
                          onPressed: canSkipPrevious
                              ? () {
                                  logUi('tap mini-player: précédent');
                                  ref
                                      .read(audioHandlerProvider)
                                      .skipToPrevious();
                                }
                              : null,
                          color: colors.textSecondary,
                          disabledColor: colors.textTertiary,
                          iconSize: 24,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.skip_previous_rounded),
                        ),
                      _MiniPlayButton(
                        playing: playing,
                        busy: isBusy,
                        onPressed: () {
                          logUi(
                            'tap mini-player: '
                            '${playing ? 'pause' : 'lecture'}',
                          );
                          final handler = ref.read(audioHandlerProvider);
                          playing ? handler.pause() : handler.play();
                        },
                      ),
                      IconButton(
                        tooltip: 'Piste suivante',
                        onPressed: canSkipNext
                            ? () {
                                logUi('tap mini-player: suivant');
                                ref.read(audioHandlerProvider).skipToNext();
                              }
                            : null,
                        color: colors.textSecondary,
                        disabledColor: colors.textTertiary,
                        iconSize: 24,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 8),
              const _MiniProgress(),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bouton de lecture sculpté : crème en clair, argile en sombre.
class _MiniPlayButton extends StatelessWidget {
  const _MiniPlayButton({
    required this.playing,
    required this.busy,
    required this.onPressed,
  });

  final bool playing;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: SoftCircle(
        size: 46,
        color: colors.playSurface,
        onTap: busy ? null : onPressed,
        tooltip: playing ? 'Pause' : 'Lecture',
        child: busy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: colors.playInk,
                ),
              )
            : Icon(
                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                color: colors.playInk,
                size: 26,
              ),
      ),
    );
  }
}

class _MiniProgress extends ConsumerWidget {
  const _MiniProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final position = ref.watch(positionDataProvider).asData?.value;
    final durationMs = position?.duration.inMilliseconds ?? 0;
    final value = durationMs <= 0
        ? 0.0
        : ((position?.position.inMilliseconds ?? 0) / durationMs).clamp(
            0.0,
            1.0,
          );
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: LinearProgressIndicator(
        key: const ValueKey('mini-player-progress'),
        minHeight: 3,
        value: value,
        backgroundColor: colors.surfaceSunken,
        valueColor: AlwaysStoppedAnimation<Color>(colors.accent),
      ),
    );
  }
}
