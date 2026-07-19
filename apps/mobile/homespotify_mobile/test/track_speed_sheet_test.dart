import 'dart:async';
import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:homespotify_mobile/src/features/player/audio/homespotify_audio_handler.dart';
import 'package:homespotify_mobile/src/features/player/data/playback_settings_api.dart';
import 'package:homespotify_mobile/src/features/player/presentation/track_speed_sheet.dart';

void main() {
  test('calcul BPM dynamique et snap central sans erreur flottante', () {
    expect(normalizeSpeedSelection(1.019), 1);
    expect(normalizeSpeedSelection(1.026), 1.03);
    expect(normalizeSpeedSelection(1.199999), 1.2);
    expect(effectiveBpm(118, 1.1), 129.8);
    expect(speedFactorLabel(1.1), '1.10x · +10 %');
  });

  testWidgets('la feuille affiche les données utiles sans badge marketing', (
    tester,
  ) async {
    final session = _FakeTrackSpeedSession();
    await _openSpeedSheet(tester, session);

    expect(find.text('Vitesse du titre'), findsOneWidget);
    expect(find.text('≈ 118 BPM'), findsNWidgets(2));
    expect(find.text('Mode compatible'), findsOneWidget);
    expect(find.text('Traitement en temps réel'), findsOneWidget);
    expect(find.textContaining('Tonalité préservée'), findsNothing);
    expect(find.textContaining('pitch 1.0'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('speed-preset-1.1')));
    await tester.pumpAndSettle();

    expect(find.text('1.10x · +10 %'), findsOneWidget);
    expect(find.text('≈ 129.8 BPM'), findsOneWidget);
    expect(session.previewedRatios.last, 1.1);

    await tester.tap(find.byKey(const ValueKey('apply-track-speed')));
    await tester.pumpAndSettle();
    expect(session.committedRatio, 1.1);
    expect(find.text('Vitesse du titre'), findsNothing);
  });

  testWidgets('ANALYZING est actualisé jusqu’au résultat BPM', (tester) async {
    final session = _FakeTrackSpeedSession(
      analysis: const TrackAudioAnalysis(trackId: 1, status: 'ANALYZING'),
      refreshedAnalyses: const [
        TrackAudioAnalysis(
          trackId: 1,
          status: 'LOW_CONFIDENCE',
          bpm: 118,
          confidence: 0.62,
        ),
      ],
    );
    await _pumpDirectSheet(
      tester,
      session,
      analysisPollInterval: const Duration(milliseconds: 1),
      maxAnalysisPolls: 3,
    );

    expect(find.text('BPM en cours d’analyse'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(find.text('≈ 118 BPM'), findsNWidgets(2));
    expect(session.analysisRefreshCount, 1);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('le polling BPM borné termine en état indisponible', (
    tester,
  ) async {
    final session = _FakeTrackSpeedSession(
      analysis: const TrackAudioAnalysis(trackId: 1, status: 'PENDING'),
    );
    await _pumpDirectSheet(
      tester,
      session,
      analysisPollInterval: const Duration(milliseconds: 1),
      maxAnalysisPolls: 2,
    );

    for (var index = 0; index < 3; index += 1) {
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
    }

    expect(find.text('Analyse BPM indisponible'), findsOneWidget);
    expect(session.analysisRefreshCount, 2);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('les échecs BPM distinguent absence et indisponibilité', (
    tester,
  ) async {
    await _pumpDirectSheet(
      tester,
      _FakeTrackSpeedSession(
        analysis: const TrackAudioAnalysis(
          trackId: 1,
          status: 'FAILED',
          failureReason: 'BPM_NOT_DETECTED',
        ),
      ),
    );
    expect(find.text('BPM non détecté'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    await _pumpDirectSheet(
      tester,
      _FakeTrackSpeedSession(
        analysis: const TrackAudioAnalysis(trackId: 1, status: 'FAILED'),
      ),
    );
    expect(find.text('Analyse BPM indisponible'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('un échec moteur affiche une erreur précise', (tester) async {
    final session = _FakeTrackSpeedSession(
      commitOutcomes: Queue<Object?>.from([
        const TrackSpeedApplyException('native engine refused ratio'),
      ]),
    );
    await _openSpeedSheet(tester, session);

    await tester.tap(find.byKey(const ValueKey('apply-track-speed')));
    await tester.pumpAndSettle();

    expect(
      find.text('La vitesse n’a pas pu être appliquée au lecteur'),
      findsOneWidget,
    );
    expect(find.text('Appliquer'), findsOneWidget);
    expect(find.text('Vitesse du titre'), findsOneWidget);

    await tester.tap(find.byTooltip('Fermer'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'un échec de persistance conserve la feuille et permet un retry',
    (tester) async {
      final session = _FakeTrackSpeedSession(
        commitOutcomes: Queue<Object?>.from([
          const TrackSpeedPersistenceException('backend unavailable'),
          null,
        ]),
      );
      await _openSpeedSheet(tester, session);

      await tester.tap(find.byKey(const ValueKey('apply-track-speed')));
      await tester.pumpAndSettle();

      expect(
        find.text('Vitesse appliquée, mais non enregistrée.'),
        findsOneWidget,
      );
      expect(find.text('Appliquée pour cette écoute'), findsOneWidget);
      expect(find.text('Réessayer'), findsOneWidget);
      expect(find.text('Vitesse du titre'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('apply-track-speed')));
      await tester.pumpAndSettle();

      expect(session.commitCount, 2);
      expect(find.text('Vitesse du titre'), findsNothing);
    },
  );

  testWidgets('les doubles appuis ne lancent qu’une application', (
    tester,
  ) async {
    final pendingCommit = Completer<void>();
    final session = _FakeTrackSpeedSession(commitCompleter: pendingCommit);
    await _openSpeedSheet(tester, session);

    final applyButton = find.byKey(const ValueKey('apply-track-speed'));
    await tester.tap(applyButton);
    await tester.tap(applyButton);
    await tester.pump();

    expect(session.commitCount, 1);
    expect(find.text('Application…'), findsNWidgets(2));

    pendingCommit.complete();
    await tester.pumpAndSettle();
    expect(find.text('Vitesse du titre'), findsNothing);
  });
}

Future<void> _openSpeedSheet(
  WidgetTester tester,
  TrackSpeedSessionController session,
) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              key: const ValueKey('open-speed-sheet'),
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                isScrollControlled: true,
                builder: (_) => TrackSpeedSheet(session: session),
              ),
              child: const Text('Vitesse'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(const ValueKey('open-speed-sheet')));
  await tester.pumpAndSettle();
}

Future<void> _pumpDirectSheet(
  WidgetTester tester,
  TrackSpeedSessionController session, {
  Duration analysisPollInterval = const Duration(seconds: 2),
  int maxAnalysisPolls = 105,
}) async {
  await tester.binding.setSurfaceSize(const Size(420, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        body: TrackSpeedSheet(
          session: session,
          analysisPollInterval: analysisPollInterval,
          maxAnalysisPolls: maxAnalysisPolls,
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

class _FakeTrackSpeedSession implements TrackSpeedSessionController {
  _FakeTrackSpeedSession({
    this.analysis = const TrackAudioAnalysis(
      trackId: 1,
      status: 'READY',
      bpm: 118,
      confidence: 0.62,
      source: 'FFMPEG_TEMPO',
    ),
    this.refreshedAnalyses = const [],
    Queue<Object?>? commitOutcomes,
    this.commitCompleter,
  }) : commitOutcomes = commitOutcomes ?? Queue<Object?>();

  final TrackAudioAnalysis analysis;
  final List<TrackAudioAnalysis> refreshedAnalyses;
  final Queue<Object?> commitOutcomes;
  final Completer<void>? commitCompleter;

  @override
  final TrackSpeedTarget target = TrackSpeedTarget(
    id: 1,
    title: 'Titre',
    artist: 'Artiste',
    streamUri: Uri.parse('https://homespotify.test/1'),
  );

  final List<double> previewedRatios = <double>[];
  double? committedRatio;
  int commitCount = 0;
  int analysisRefreshCount = 0;

  @override
  Future<TrackSpeedInitialState> initialize() async =>
      TrackSpeedInitialState(ratio: 1, analysis: analysis);

  @override
  Future<void> preview(double ratio) async => previewedRatios.add(ratio);

  @override
  Future<void> commit(double ratio) async {
    commitCount += 1;
    final pending = commitCompleter;
    if (pending != null) await pending.future;
    if (commitOutcomes.isNotEmpty) {
      final outcome = commitOutcomes.removeFirst();
      if (outcome != null) throw outcome;
    }
    committedRatio = ratio;
  }

  @override
  Future<TrackAudioAnalysis> refreshAnalysis() async {
    final index = analysisRefreshCount;
    analysisRefreshCount += 1;
    if (refreshedAnalyses.isEmpty) return analysis;
    final boundedIndex = index.clamp(0, refreshedAnalyses.length - 1).toInt();
    return refreshedAnalyses[boundedIndex];
  }
}
