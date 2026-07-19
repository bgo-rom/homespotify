import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:just_audio/just_audio.dart';

import '../../../core/logging/app_logger.dart';
import '../../discovery/presentation/discovery_preview_controller.dart';
import '../audio/homespotify_audio_handler.dart';
import '../audio/time_stretch_engine.dart';
import '../data/playback_settings_api.dart';

const _background = Color(0xFF15151B);
const _surface = Color(0xFF24242D);
const _accent = Color(0xFF1DB954);
const _presets = <double>[0.7, 0.8, 0.9, 1, 1.1, 1.2, 1.3];
const _defaultAnalysisPollInterval = Duration(seconds: 2);
const _defaultMaxAnalysisPolls = 105;

class TrackSpeedTarget {
  const TrackSpeedTarget({
    required this.id,
    required this.title,
    required this.artist,
    required this.streamUri,
    this.headers,
  });

  final int id;
  final String title;
  final String artist;
  final Uri streamUri;
  final Map<String, String>? headers;
}

double normalizeSpeedSelection(double value) {
  final clamped = value.clamp(0.7, 1.3).toDouble();
  if ((clamped - 1).abs() <= 0.025) return 1;
  return (clamped * 100).round() / 100;
}

double effectiveBpm(double originalBpm, double speedRatio) {
  return (originalBpm * speedRatio * 10).round() / 10;
}

String speedFactorLabel(double ratio) {
  final percent = ((ratio - 1) * 100).round();
  final sign = percent > 0 ? '+' : '';
  return '${ratio.toStringAsFixed(2)}x · $sign$percent %';
}

Future<void> showTrackSpeedSheet(
  BuildContext context,
  WidgetRef ref, {
  required TrackSpeedTarget target,
  AudioPlayer Function()? auditionPlayerFactory,
}) async {
  // Événement utilisateur, avant le montage de la feuille : aucune mutation
  // Riverpod n'est effectuée depuis initState/dispose (L-037).
  final previewController = ref.read(discoveryPreviewProvider.notifier);
  final handler = ref.read(audioHandlerProvider);
  final repository = ref.read(playbackSettingsRepositoryProvider);
  await previewController.stop();
  if (!context.mounted) return;
  final session = _TrackSpeedSession(
    target: target,
    handler: handler,
    repository: repository,
    auditionPlayerFactory: auditionPlayerFactory ?? AudioPlayer.new,
  );
  try {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: _background,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
      builder: (_) => TrackSpeedSheet(session: session),
    );
  } finally {
    await session.close();
  }
}

class TrackSpeedInitialState {
  const TrackSpeedInitialState({required this.ratio, required this.analysis});

  final double ratio;
  final TrackAudioAnalysis analysis;
}

abstract interface class TrackSpeedSessionController {
  TrackSpeedTarget get target;
  Future<TrackSpeedInitialState> initialize();
  Future<TrackAudioAnalysis> refreshAnalysis();
  Future<void> preview(double ratio);
  Future<void> commit(double ratio);
}

class _TrackSpeedSession implements TrackSpeedSessionController {
  _TrackSpeedSession({
    required this.target,
    required this.handler,
    required this.repository,
    required this.auditionPlayerFactory,
  });

  @override
  final TrackSpeedTarget target;
  final HomeSpotifyAudioHandler handler;
  final PlaybackSettingsRepository repository;
  final AudioPlayer Function() auditionPlayerFactory;

  AudioPlayer? _auditionPlayer;
  TimeStretchEngine? _auditionTimeStretchEngine;
  double _originalRatio = 1;
  double? _retainedSessionRatio;
  bool _liveMainPlayer = false;
  bool _resumeMainPlayer = false;
  bool _committed = false;
  bool _closed = false;

  @override
  Future<TrackSpeedInitialState> initialize() async {
    // Les deux lectures partent en parallèle et possèdent un repli local :
    // l'indisponibilité du backend ne peut jamais bloquer la feuille.
    final settingsFuture = _loadSettings();
    final analysisFuture = _loadAnalysis();
    final settings = await settingsFuture;
    final analysis = await analysisFuture;
    _originalRatio = normalizeSpeedSelection(settings.speedRatio);
    final currentId = int.tryParse(handler.mediaItem.value?.id ?? '');
    _liveMainPlayer =
        currentId == target.id && handler.playbackState.value.playing;

    if (_liveMainPlayer) {
      await handler.previewTrackSpeed(target.id, _originalRatio);
    } else {
      _resumeMainPlayer = handler.playbackState.value.playing;
      if (_resumeMainPlayer) await handler.pause();
      final player = auditionPlayerFactory();
      _auditionPlayer = player;
      final timeStretchEngine = HomeSpotifyProductionTimeStretchEngine(player);
      _auditionTimeStretchEngine = timeStretchEngine;
      await timeStretchEngine.setTempoRatio(_originalRatio);
      await player.setAudioSource(
        AudioSource.uri(target.streamUri, headers: target.headers),
      );
      await player.setClip(
        start: Duration.zero,
        end: const Duration(seconds: 15),
      );
      unawaited(
        player.play().catchError((Object error, StackTrace stackTrace) {
          logError(
            'audition vitesse impossible',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
    }
    return TrackSpeedInitialState(ratio: _originalRatio, analysis: analysis);
  }

  @override
  Future<TrackAudioAnalysis> refreshAnalysis() => _loadAnalysis();

  Future<TrackPlaybackSettings> _loadSettings() async {
    try {
      return await repository
          .fetch(target.id)
          .timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      logError(
        'réglage vitesse indisponible; défaut 1.00x',
        error: error,
        stackTrace: stackTrace,
      );
      return TrackPlaybackSettings(
        trackId: target.id,
        speedRatio: 1,
        preservePitch: true,
        isDefault: true,
      );
    }
  }

  Future<TrackAudioAnalysis> _loadAnalysis() async {
    try {
      return await repository
          .fetchAnalysis(target.id)
          .timeout(const Duration(seconds: 2));
    } catch (error, stackTrace) {
      logError(
        'analyse BPM indisponible',
        error: error,
        stackTrace: stackTrace,
      );
      return TrackAudioAnalysis(
        trackId: target.id,
        status: 'FAILED',
        failureReason: 'ANALYZER_UNAVAILABLE',
      );
    }
  }

  @override
  Future<void> preview(double ratio) async {
    final normalized = normalizeSpeedSelection(ratio);
    final retained = _retainedSessionRatio;
    if (retained != null && _liveMainPlayer) {
      _committed = normalized == retained;
    }
    if (_liveMainPlayer) {
      await handler.previewTrackSpeed(target.id, normalized);
      return;
    }
    await _auditionTimeStretchEngine?.setTempoRatio(normalized);
  }

  @override
  Future<void> commit(double ratio) async {
    final normalized = normalizeSpeedSelection(ratio);
    try {
      if (normalized == 1) {
        await handler.resetTrackSpeed(target.id);
      } else {
        await handler.setTrackSpeed(target.id, normalized);
      }
      _committed = true;
      _retainedSessionRatio = null;
    } on TrackSpeedPersistenceException {
      // Le moteur a confirmé la vitesse. Fermer après un échec réseau ne doit
      // pas annuler ce réglage temporaire, même si la préférence reste à sauver.
      _committed = true;
      _retainedSessionRatio = normalized;
      rethrow;
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (!_committed && _liveMainPlayer) {
      await handler.previewTrackSpeed(target.id, _originalRatio);
    }
    final player = _auditionPlayer;
    if (player != null) {
      await player.stop();
      await _auditionTimeStretchEngine?.dispose();
      _auditionTimeStretchEngine = null;
      await player.dispose();
      _auditionPlayer = null;
    }
    if (_resumeMainPlayer) await handler.play();
  }
}

class TrackSpeedSheet extends StatefulWidget {
  const TrackSpeedSheet({
    super.key,
    required this.session,
    this.analysisPollInterval = _defaultAnalysisPollInterval,
    this.maxAnalysisPolls = _defaultMaxAnalysisPolls,
  }) : assert(maxAnalysisPolls > 0);

  final TrackSpeedSessionController session;
  final Duration analysisPollInterval;
  final int maxAnalysisPolls;

  @override
  State<TrackSpeedSheet> createState() => _TrackSpeedSheetState();
}

class _TrackSpeedSheetState extends State<TrackSpeedSheet> {
  double _ratio = 1;
  TrackAudioAnalysis? _analysis;
  Timer? _analysisTimer;
  String? _error;
  bool _loading = true;
  bool _saving = false;
  bool _retryPersistence = false;
  bool _analysisPollingTimedOut = false;
  int _analysisPollCount = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  @override
  void dispose() {
    _analysisTimer?.cancel();
    super.dispose();
  }

  Future<void> _initialize() async {
    try {
      final initial = await widget.session.initialize();
      if (!mounted) return;
      setState(() {
        _ratio = initial.ratio;
        _analysis = initial.analysis;
        _analysisPollCount = 0;
        _analysisPollingTimedOut = false;
        _loading = false;
      });
      _scheduleAnalysisRefresh();
    } catch (error, stackTrace) {
      logError(
        'initialisation vitesse impossible',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _loading = false;
          _error = 'Impossible de préparer l’audition.';
        });
      }
    }
  }

  void _scheduleAnalysisRefresh() {
    _analysisTimer?.cancel();
    if (!_analysisIsRunning(_analysis)) return;
    if (_analysisPollCount >= widget.maxAnalysisPolls) {
      if (mounted) setState(() => _analysisPollingTimedOut = true);
      return;
    }
    _analysisTimer = Timer(widget.analysisPollInterval, () {
      unawaited(_refreshAnalysis());
    });
  }

  Future<void> _refreshAnalysis() async {
    _analysisPollCount += 1;
    try {
      final analysis = await widget.session.refreshAnalysis();
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        _analysisPollingTimedOut = false;
      });
      _scheduleAnalysisRefresh();
    } catch (error, stackTrace) {
      if (!mounted) return;
      if (_analysisPollCount >= widget.maxAnalysisPolls) {
        setState(() => _analysisPollingTimedOut = true);
      } else {
        _scheduleAnalysisRefresh();
      }
      logError(
        'rafraîchissement BPM interrompu',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _changeRatio(double rawRatio) async {
    final next = normalizeSpeedSelection(rawRatio);
    if (next == 1 && _ratio != 1) unawaited(HapticFeedback.selectionClick());
    setState(() {
      _ratio = next;
      _error = null;
      _retryPersistence = false;
    });
    try {
      await widget.session.preview(next);
      if (mounted) setState(() {});
    } catch (error, stackTrace) {
      logError(
        'préécoute vitesse impossible',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) setState(() => _error = 'Préécoute indisponible.');
    }
  }

  Future<void> _apply() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _retryPersistence = false;
    });
    try {
      await widget.session.commit(_ratio);
      if (mounted) Navigator.pop(context);
    } on TrackSpeedPersistenceException catch (error, stackTrace) {
      logError(
        'vitesse appliquée mais non persistée',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _saving = false;
          _retryPersistence = true;
          _error = 'Vitesse appliquée, mais non enregistrée.';
        });
      }
    } on TrackSpeedApplyException catch (error, stackTrace) {
      logError(
        'application de vitesse refusée par le lecteur',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'La vitesse n’a pas pu être appliquée au lecteur';
        });
      }
    } catch (error, stackTrace) {
      logError(
        'enregistrement vitesse impossible',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Impossible d’enregistrer ce réglage.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final analysis = _analysis;
    final originalBpm = analysis?.bpm;
    final adjustedBpm = originalBpm == null
        ? null
        : effectiveBpm(originalBpm, _ratio);
    return FractionallySizedBox(
      heightFactor: 0.92,
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 42,
            height: 5,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 12, 8),
            child: Row(
              children: [
                const Icon(Icons.speed_rounded, color: _accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Vitesse du titre',
                        style: TextStyle(
                          fontSize: 21,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        '${widget.session.target.title} · ${widget.session.target.artist}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white54),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Fermer',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _accent))
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
                    child: Column(
                      children: [
                        _BpmPanel(
                          analysis: analysis,
                          originalBpm: originalBpm,
                          effectiveBpmValue: adjustedBpm,
                          pollingTimedOut: _analysisPollingTimedOut,
                        ),
                        const SizedBox(height: 22),
                        Text(
                          speedFactorLabel(_ratio),
                          key: const ValueKey('speed-factor-label'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 8),
                        _EngineStatusPanel(
                          ratio: _ratio,
                          applying: _saving,
                          appliedForCurrentSession: _retryPersistence,
                        ),
                        const SizedBox(height: 24),
                        Slider(
                          key: const ValueKey('track-speed-slider'),
                          min: 0.7,
                          max: 1.3,
                          divisions: 60,
                          value: _ratio,
                          activeColor: _accent,
                          onChanged: _saving
                              ? null
                              : (value) => _changeRatio(value),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: const [
                            Text(
                              '0.70x',
                              style: TextStyle(color: Colors.white38),
                            ),
                            Text(
                              '1.00x',
                              style: TextStyle(color: Colors.white70),
                            ),
                            Text(
                              '1.30x',
                              style: TextStyle(color: Colors.white38),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final preset in _presets)
                              ChoiceChip(
                                key: ValueKey(
                                  'speed-preset-${preset.toStringAsFixed(1)}',
                                ),
                                label: Text(
                                  '${((preset - 1) * 100).round()} %',
                                ),
                                selected: _ratio == preset,
                                onSelected: _saving
                                    ? null
                                    : (_) => _changeRatio(preset),
                              ),
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 18),
                          Text(
                            _error!,
                            style: const TextStyle(color: Color(0xFFE57373)),
                          ),
                        ],
                      ],
                    ),
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 18),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: const Text('Annuler'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton(
                    key: const ValueKey('apply-track-speed'),
                    onPressed: _loading || _saving ? null : _apply,
                    child: _saving
                        ? const FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                SizedBox(
                                  width: 18,
                                  height: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                                SizedBox(width: 8),
                                Text('Application…'),
                              ],
                            ),
                          )
                        : Text(_retryPersistence ? 'Réessayer' : 'Appliquer'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _BpmPanel extends StatelessWidget {
  const _BpmPanel({
    required this.analysis,
    required this.originalBpm,
    required this.effectiveBpmValue,
    required this.pollingTimedOut,
  });

  final TrackAudioAnalysis? analysis;
  final double? originalBpm;
  final double? effectiveBpmValue;
  final bool pollingTimedOut;

  @override
  Widget build(BuildContext context) {
    final analysisRunning = _analysisIsRunning(analysis);
    final pending = !pollingTimedOut && analysisRunning;
    final status = analysis?.status.toUpperCase();
    final approximate =
        status == 'LOW_CONFIDENCE' || (analysis?.isApproximate ?? false);
    final notDetected =
        !pollingTimedOut &&
        (analysis?.failureReason == 'BPM_NOT_DETECTED' ||
            status == 'NOT_DETECTED' ||
            status == 'BPM_NOT_DETECTED' ||
            (!analysisRunning && status != 'FAILED' && originalBpm == null));
    final unavailable =
        !notDetected &&
        (pollingTimedOut ||
            status == 'FAILED' ||
            status == 'ERROR' ||
            status == 'UNAVAILABLE');
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(22),
      ),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            Expanded(
              child: _BpmValue(
                label: 'BPM original',
                value: pending
                    ? 'BPM en cours d’analyse'
                    : unavailable
                    ? 'Analyse BPM indisponible'
                    : notDetected
                    ? 'BPM non détecté'
                    : originalBpm == null
                    ? 'BPM non détecté'
                    : '${approximate ? '≈ ' : ''}${_formatBpm(originalBpm!)}',
              ),
            ),
            Container(width: 1, height: 45, color: Colors.white12),
            Expanded(
              child: _BpmValue(
                label: 'BPM effectif',
                value: effectiveBpmValue == null
                    ? '—'
                    : '${approximate ? '≈ ' : ''}${_formatBpm(effectiveBpmValue!)}',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _BpmValue extends StatelessWidget {
  const _BpmValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
      const SizedBox(height: 6),
      Text(
        value,
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
      ),
    ],
  );
}

class _EngineStatusPanel extends StatelessWidget {
  const _EngineStatusPanel({
    required this.ratio,
    required this.applying,
    required this.appliedForCurrentSession,
  });

  final double ratio;
  final bool applying;
  final bool appliedForCurrentSession;

  @override
  Widget build(BuildContext context) => GestureDetector(
    // Accès développeur discret : appui long → laboratoire A/B du moteur.
    onLongPress: () => context.push('/dev/stretch-lab'),
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: _surface,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: _EngineStatusValue(
                label: 'Mode audio',
                value: currentTimeStretchQualityLabel,
              ),
            ),
            Container(width: 1, height: 38, color: Colors.white12),
            Expanded(
              child: _EngineStatusValue(
                label: 'État',
                value: applying
                    ? 'Application…'
                    : appliedForCurrentSession
                    ? 'Appliquée pour cette écoute'
                    : 'Traitement en temps réel',
              ),
            ),
            Container(width: 1, height: 38, color: Colors.white12),
            Expanded(
              child: _EngineStatusValue(
                label: 'Vitesse',
                value: '${ratio.toStringAsFixed(2)}x',
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _EngineStatusValue extends StatelessWidget {
  const _EngineStatusValue({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 5),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white54, fontSize: 11),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );
}

bool _analysisIsRunning(TrackAudioAnalysis? analysis) {
  final status = analysis?.status.toUpperCase();
  return analysis == null || status == 'PENDING' || status == 'ANALYZING';
}

String _formatBpm(double bpm) {
  return bpm == bpm.roundToDouble()
      ? '${bpm.round()} BPM'
      : '${bpm.toStringAsFixed(1)} BPM';
}
