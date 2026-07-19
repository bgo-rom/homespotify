import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/logging/app_logger.dart';
import '../../player/presentation/player_providers.dart';
import '../data/discovery_api.dart';
import '../domain/discovery_models.dart';

/// Délai avant l'autoplay : la carte doit rester active ~400 ms (un swipe
/// rapide ne déclenche jamais de lecture).
const Duration kPreviewAutoplayDelay = Duration(milliseconds: 400);

/// Sous ce ratio d'écoute, un arrêt volontaire = signal PREVIEW_STOPPED_EARLY.
const double _earlyStopRatio = 0.3;

/// État du lecteur d'extraits 30 s de la découverte.
class DiscoveryPreviewState {
  const DiscoveryPreviewState({
    this.candidateId,
    this.playing = false,
    this.loading = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
  });

  /// Candidat dont l'extrait est chargé (null : aucun extrait actif).
  final int? candidateId;
  final bool playing;
  final bool loading;

  /// Progression de l'extrait (barre de la carte active).
  final Duration position;
  final Duration duration;

  bool isActiveFor(int id) => candidateId == id && (playing || loading);

  double get progress => duration.inMilliseconds <= 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  DiscoveryPreviewState copyWith({
    int? candidateId,
    bool clearCandidate = false,
    bool? playing,
    bool? loading,
    Duration? position,
    Duration? duration,
  }) {
    return DiscoveryPreviewState(
      candidateId: clearCandidate ? null : (candidateId ?? this.candidateId),
      playing: playing ?? this.playing,
      loading: loading ?? this.loading,
      position: position ?? this.position,
      duration: duration ?? this.duration,
    );
  }
}

/// Fabrique du lecteur d'extraits — surchargée dans les tests.
final discoveryPreviewPlayerFactoryProvider = Provider<AudioPlayer Function()>(
  (ref) => AudioPlayer.new,
);

/// Lecteur d'extraits UNIQUE et global, totalement séparé du pipeline audio
/// de la bibliothèque (aucun DSP, aucune normalisation, aucun transcodage).
///
/// Autoplay « Swipefy » : quand une carte devient active, un délai de ~400 ms
/// court ; si la carte est toujours active, l'extrait démarre seul. Arrêts :
/// swipe/changement de carte, SKIP, DISLIKE, confirmation de demande, app en
/// arrière-plan, logout, sortie d'écran, lecture bibliothèque.
class DiscoveryPreviewController extends Notifier<DiscoveryPreviewState> {
  /// Créé paresseusement : aucune ressource audio tant qu'aucun extrait
  /// n'est demandé (et rien à initialiser dans les tests widget).
  AudioPlayer? _player;
  StreamSubscription<PlayerState>? _stateSubscription;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<Duration?>? _durationSubscription;
  Timer? _autoplayTimer;
  RecommendationCandidate? _armedCandidate;

  @override
  DiscoveryPreviewState build() {
    // Une lecture bibliothèque qui démarre coupe l'extrait immédiatement.
    // playbackStateProvider est un StreamProvider : si le handler audio n'est
    // pas initialisé (tests), il expose AsyncError — jamais de crash ici.
    ref.listen(playbackStateProvider, (previous, next) {
      final wasPlaying = previous?.asData?.value.playing ?? false;
      final isPlaying = next.asData?.value.playing ?? false;
      if (isPlaying && !wasPlaying) stop();
    });
    ref.onDispose(_cleanup);
    return const DiscoveryPreviewState();
  }

  void _cleanup() {
    _autoplayTimer?.cancel();
    _autoplayTimer = null;
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
    final player = ref.read(discoveryPreviewPlayerFactoryProvider)();
    _stateSubscription = player.playerStateStream.listen((playerState) {
      if (!ref.mounted) return;
      final finished = playerState.processingState == ProcessingState.completed;
      state = state.copyWith(
        clearCandidate: finished,
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

  /// La carte [candidate] vient de devenir active : arme l'autoplay différé.
  /// Sans previewUrl, ne fait rien (l'appelant vérifie aussi le réglage).
  void armAutoplay(RecommendationCandidate candidate) {
    _autoplayTimer?.cancel();
    if (candidate.previewUrl == null || candidate.previewUrl!.isEmpty) return;
    _armedCandidate = candidate;
    _autoplayTimer = Timer(kPreviewAutoplayDelay, () {
      final armed = _armedCandidate;
      _autoplayTimer = null;
      // Toujours la même carte active après le délai → lecture automatique.
      if (armed != null && armed.id == candidate.id) {
        _play(armed);
      }
    });
  }

  /// Annule un autoplay armé (carte swipée avant le délai).
  void disarmAutoplay() {
    _autoplayTimer?.cancel();
    _autoplayTimer = null;
    _armedCandidate = null;
  }

  Future<void> _play(RecommendationCandidate candidate) async {
    final url = candidate.previewUrl;
    if (url == null || url.isEmpty) return;
    final player = _ensurePlayer();
    try {
      if (state.candidateId == candidate.id) {
        await player.play();
        return;
      }
      await player.stop();
      state = DiscoveryPreviewState(candidateId: candidate.id, loading: true);
      // Aucune en-tête d'authentification : l'URL est un média public tiers,
      // le Bearer HomeSpotify ne sort JAMAIS vers un domaine externe.
      await player.setUrl(url);
      await player.play();
    } catch (error) {
      logError('extrait impossible pour "${candidate.title}"', error: error);
      if (ref.mounted) state = const DiscoveryPreviewState();
    }
  }

  /// Lecture/pause manuelle. Une pause précoce envoie le signal faible
  /// PREVIEW_STOPPED_EARLY (l'utilisateur a coupé l'extrait volontairement).
  Future<void> toggle(RecommendationCandidate candidate) async {
    disarmAutoplay();
    final player = _player;
    if (state.candidateId == candidate.id && (player?.playing ?? false)) {
      _reportEarlyStopIfNeeded(candidate.id);
      await player!.pause();
      return;
    }
    await _play(candidate);
  }

  /// Arrêt inconditionnel. [reportEarlyStop] : true pour les gestes
  /// UTILISATEUR (swipe, skip, dislike, demande) — jamais pour les arrêts
  /// techniques (arrière-plan, logout, sortie d'écran, lecture bibliothèque).
  Future<void> stop({bool reportEarlyStop = false}) async {
    disarmAutoplay();
    final player = _player;
    final activeCandidate = state.candidateId;
    if (reportEarlyStop && activeCandidate != null) {
      _reportEarlyStopIfNeeded(activeCandidate);
    }
    if (activeCandidate != null || (player?.playing ?? false)) {
      state = const DiscoveryPreviewState();
    }
    if (player != null) {
      try {
        await player.stop();
      } catch (error) {
        logError('arrêt extrait échoué', error: error);
      }
    }
  }

  /// Signal FAIBLE : extrait coupé tôt (< 30 % écoutés, > 500 ms lus).
  void _reportEarlyStopIfNeeded(int candidateId) {
    final playedMs = state.position.inMilliseconds;
    final totalMs = state.duration.inMilliseconds;
    if (!state.playing || playedMs < 500) return;
    if (totalMs > 0 && playedMs / totalMs >= _earlyStopRatio) return;
    ref
        .read(discoveryApiProvider)
        .sendAction(candidateId, RecommendationSwipeAction.previewStoppedEarly)
        .catchError((Object error) {
          logError('signal PREVIEW_STOPPED_EARLY non envoyé', error: error);
        });
  }
}

final discoveryPreviewProvider =
    NotifierProvider<DiscoveryPreviewController, DiscoveryPreviewState>(
      DiscoveryPreviewController.new,
      name: 'discoveryPreview',
    );
