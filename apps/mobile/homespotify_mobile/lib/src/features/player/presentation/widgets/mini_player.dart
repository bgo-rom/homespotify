import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../app/navigation.dart';
import '../../../../core/logging/app_logger.dart';
import '../../../../core/network/authenticated_network_image.dart';
import '../../../../core/theme/home_design.dart';
import '../../audio/homespotify_audio_handler.dart';
import '../player_providers.dart';

String? _lastMiniArtworkTrace;
final Set<String> _miniArtworkErrors = <String>{};

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
class MiniPlayer extends ConsumerWidget {
  const MiniPlayer({super.key, this.safeAreaBottom = true});

  final bool safeAreaBottom;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mediaItem = ref.watch(mediaItemProvider).asData?.value;
    if (mediaItem == null) return const SizedBox.shrink();
    _traceMiniArtwork(mediaItem);

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
      child: Material(
        color: HomeDesign.surfaceRaised,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 64,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final showPrevious = constraints.maxWidth >= 370;
                  return Row(
                    children: [
                      Expanded(
                        child: InkWell(
                          onTap: () {
                            logUi('tap mini-player (ouvrir lecteur complet)');
                            openPlayer(context);
                          },
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Row(
                              children: [
                                _MiniArtwork(
                                  trackId: mediaItem.id,
                                  artUri: mediaItem.artUri,
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
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          mediaItem.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          speed == 1
                                              ? (mediaItem.artist ?? '—')
                                              : '${mediaItem.artist ?? '—'} · ${speed.toStringAsFixed(2)}x',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white54,
                                            fontSize: 11.5,
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
                          color: Colors.white,
                          disabledColor: Colors.white24,
                          iconSize: 25,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.skip_previous_rounded),
                        ),
                      IconButton(
                        tooltip: playing ? 'Pause' : 'Lecture',
                        onPressed: isBusy
                            ? null
                            : () {
                                logUi(
                                  'tap mini-player: '
                                  '${playing ? 'pause' : 'lecture'}',
                                );
                                final handler = ref.read(audioHandlerProvider);
                                playing ? handler.pause() : handler.play();
                              },
                        color: Colors.white,
                        disabledColor: Colors.white38,
                        iconSize: 30,
                        icon: isBusy
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.4,
                                  color: HomeDesign.accent,
                                ),
                              )
                            : Icon(
                                playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                      ),
                      IconButton(
                        tooltip: 'Piste suivante',
                        onPressed: canSkipNext
                            ? () {
                                logUi('tap mini-player: suivant');
                                ref.read(audioHandlerProvider).skipToNext();
                              }
                            : null,
                        color: Colors.white,
                        disabledColor: Colors.white24,
                        iconSize: 25,
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.skip_next_rounded),
                      ),
                      const SizedBox(width: 4),
                    ],
                  );
                },
              ),
            ),
            const _MiniProgress(),
          ],
        ),
      ),
    );
  }
}

class _MiniProgress extends ConsumerWidget {
  const _MiniProgress();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final position = ref.watch(positionDataProvider).asData?.value;
    final durationMs = position?.duration.inMilliseconds ?? 0;
    final value = durationMs <= 0
        ? 0.0
        : ((position?.position.inMilliseconds ?? 0) / durationMs).clamp(
            0.0,
            1.0,
          );
    return LinearProgressIndicator(
      key: const ValueKey('mini-player-progress'),
      minHeight: 2,
      value: value,
      backgroundColor: Colors.white10,
      valueColor: const AlwaysStoppedAnimation<Color>(HomeDesign.accent),
    );
  }
}

class _MiniArtwork extends StatelessWidget {
  const _MiniArtwork({required this.trackId, this.artUri});

  final String trackId;
  final Uri? artUri;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 44,
        height: 44,
        child: artUri == null
            ? const _MiniArtworkPlaceholder()
            : AuthenticatedNetworkImage(
                artUri.toString(),
                key: ValueKey('mini_${trackId}_$artUri'),
                artworkTraceLabel: 'mini-player trackId=$trackId',
                fit: BoxFit.cover,
                cacheWidth: 88,
                cacheHeight: 88,
                filterQuality: FilterQuality.low,
                gaplessPlayback: true,
                errorBuilder: (_, error, stackTrace) {
                  final key = '$trackId|$artUri|$error';
                  if (kDebugMode && _miniArtworkErrors.add(key)) {
                    final stack = stackTrace
                        ?.toString()
                        .split('\n')
                        .take(3)
                        .join(' | ');
                    debugPrint(
                      '[ARTWORK_TRACE] G mini-player trackId=$trackId '
                      'uri=$artUri errorType=${error.runtimeType} '
                      'message=$error stack=${stack ?? 'none'}',
                    );
                  }
                  return const _MiniArtworkPlaceholder();
                },
                loadingBuilder: (context, child, progress) =>
                    progress == null ? child : const _MiniArtworkPlaceholder(),
              ),
      ),
    );
  }
}

class _MiniArtworkPlaceholder extends StatelessWidget {
  const _MiniArtworkPlaceholder();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: HomeDesign.surfaceMuted,
      child: Icon(Icons.music_note_rounded, color: Colors.white24, size: 20),
    );
  }
}
