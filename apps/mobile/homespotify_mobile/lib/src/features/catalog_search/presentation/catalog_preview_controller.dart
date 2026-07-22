import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/logging/app_logger.dart';
import '../../player/audio/homespotify_audio_handler.dart';
import '../../player/presentation/player_providers.dart';
import '../domain/catalog_models.dart';

/// État du lecteur de previews de la recherche catalogue.
///
/// Règles (Phase 18) : UN SEUL preview player, totalement séparé du
/// HomeSpotifyAudioHandler — jamais dans la queue personnelle, jamais de
/// notification audio_service, jamais d'historique d'écoute, jamais de
/// téléchargement ni de cache binaire, jamais de Signalsmith.
class CatalogPreviewState {
  const CatalogPreviewState({
    this.activeKey,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.mainPlaybackInterrupted = false,
    this.attribution,
  });

  /// Clé canonique du résultat en cours de preview (null : aucun).
  final String? activeKey;
  final bool playing;
  final bool loading;
  final Duration position;
  final Duration duration;

  /// La lecture principale jouait quand la preview a démarré : on affiche
  /// « Reprendre ma musique » — JAMAIS de reprise automatique.
  final bool mainPlaybackInterrupted;
  final String? attribution;

  bool isActiveFor(String key) => activeKey == key && (playing || loading);

  double get progress => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  CatalogPreviewState copyWith({
    String? activeKey,
    bool clearActive = false,
    bool? playing,
    bool? loading,
    Duration? position,
    Duration? duration,
    bool? mainPlaybackInterrupted,
    String? attribution,
  }) {
    return CatalogPreviewState(
      activeKey: clearActive ? null : (activeKey ?? this.activeKey),
      playing: playing ?? this.playing,
      loading: loading ?? this.loading,
      position: position ?? this.position,
      duration: duration ?? this.duration,
      mainPlaybackInterrupted:
          mainPlaybackInterrupted ?? this.mainPlaybackInterrupted,
      attribution: attribution ?? this.attribution,
    );
  }
}

/// Fabrique du lecteur de preview — surchargée dans les tests (faux player).
final catalogPreviewPlayerFactoryProvider = Provider<AudioPlayer Function()>(
  (ref) => AudioPlayer.new,
);

class CatalogPreviewController extends Notifier<CatalogPreviewState> {
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;

  @override
  CatalogPreviewState build() {
    ref.onDispose(_cleanup);
    return const CatalogPreviewState();
  }

  void _cleanup() {
    _stateSubscription?.cancel();
    _stateSubscription = null;
    _positionSubscription?.cancel();
    _positionSubscription = null;
    _durationSubscription?.cancel();
    _durationSubscription = null;
    _player?.dispose();
    _player = null;
  }

  AudioPlayer _ensurePlayer() {
    final existing = _player;
    if (existing != null) return existing;
    final player = ref.read(catalogPreviewPlayerFactoryProvider)();
    _stateSubscription = player.playerStateStream.listen((playerState) {
      if (!ref.mounted) return;
      final finished = playerState.processingState == ProcessingState.completed;
      state = state.copyWith(
        clearActive: finished,
        playing: playerState.playing && !finished,
        loading:
            playerState.processingState == ProcessingState.loading ||
            playerState.processingState == ProcessingState.buffering,
      );
    });
    _positionSubscription = player.positionStream.listen((position) {
      if (ref.mounted) state = state.copyWith(position: position);
    });
    _durationSubscription = player.durationStream.listen((duration) {
      if (ref.mounted && duration != null) {
        state = state.copyWith(duration: duration);
      }
    });
    _player = player;
    return player;
  }

  /// Lecture/pause d'une preview. TIDAL (requiresOfficialSdk) n'est jamais lu
  /// ici — l'UI ne doit proposer que « Ouvrir dans TIDAL » dans ce cas.
  Future<void> toggle(String key, CatalogPreview preview) async {
    if (preview.requiresOfficialSdk) return;
    final player = _player;
    if (state.activeKey == key && (player?.playing ?? false)) {
      await player!.pause();
      return;
    }
    await _play(key, preview);
  }

  Future<void> _play(String key, CatalogPreview preview) async {
    final player = _ensurePlayer();
    // Pause de la lecture principale (position et queue CONSERVÉES par le
    // handler) en mémorisant qu'elle jouait — jamais de reprise automatique.
    var interrupted = state.mainPlaybackInterrupted;
    try {
      final mainPlaying =
          ref.read(playbackStateProvider).asData?.value.playing ?? false;
      if (mainPlaying) {
        interrupted = true;
        await ref.read(audioHandlerProvider).pause();
      }
    } catch (error) {
      // Handler non initialisé (tests/démarrage) : la preview reste jouable.
      logError('pause du lecteur principal impossible', error: error);
    }
    try {
      if (state.activeKey == key) {
        state = state.copyWith(mainPlaybackInterrupted: interrupted);
        await player.play();
        return;
      }
      await player.stop();
      state = CatalogPreviewState(
        activeKey: key,
        loading: true,
        mainPlaybackInterrupted: interrupted,
        attribution: preview.attribution,
      );
      // URL https publique du fournisseur : AUCUN header HomeSpotify envoyé.
      await player.setUrl(preview.url);
      await player.play();
    } catch (error) {
      logError('preview catalogue impossible', error: error);
      if (ref.mounted) {
        state = CatalogPreviewState(mainPlaybackInterrupted: interrupted);
      }
    }
  }

  /// Arrêt inconditionnel (changement d'écran, nouvelle demande, logout).
  Future<void> stop() async {
    final player = _player;
    if (state.activeKey != null || (player?.playing ?? false)) {
      state = state.copyWith(clearActive: true, playing: false, loading: false);
    }
    if (player != null) {
      try {
        await player.stop();
      } catch (error) {
        logError('arrêt preview catalogue échoué', error: error);
      }
    }
  }

  /// Bouton « Reprendre ma musique » : reprise EXPLICITE de la lecture
  /// principale, jamais déclenchée automatiquement.
  Future<void> resumeMainPlayback() async {
    await stop();
    state = state.copyWith(mainPlaybackInterrupted: false);
    try {
      await ref.read(audioHandlerProvider).play();
    } catch (error) {
      logError('reprise du lecteur principal échouée', error: error);
    }
  }

  /// Oublie l'interruption (l'utilisateur a relancé sa musique lui-même).
  void clearInterruption() {
    if (state.mainPlaybackInterrupted) {
      state = state.copyWith(mainPlaybackInterrupted: false);
    }
  }
}

final catalogPreviewProvider =
    NotifierProvider<CatalogPreviewController, CatalogPreviewState>(
      CatalogPreviewController.new,
      name: 'catalogPreview',
    );
