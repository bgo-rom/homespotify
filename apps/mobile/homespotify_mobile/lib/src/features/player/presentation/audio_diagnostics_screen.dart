import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../auth/application/auth_controller.dart';
import '../audio/audio_diagnostics.dart';
import '../audio/homespotify_audio_handler.dart';

class AudioDiagnosticsScreen extends ConsumerStatefulWidget {
  const AudioDiagnosticsScreen({super.key});

  @override
  ConsumerState<AudioDiagnosticsScreen> createState() =>
      _AudioDiagnosticsScreenState();
}

class _AudioDiagnosticsScreenState
    extends ConsumerState<AudioDiagnosticsScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(
      authControllerProvider.select((state) => state.user),
    );
    if (user?.isOwner != true && !kDebugMode) {
      return const Scaffold(
        body: Center(child: Text('Diagnostic réservé au propriétaire.')),
      );
    }
    final handler = ref.read(audioHandlerProvider);
    final diagnostics = AudioDiagnostics.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostic audio')),
      body: ValueListenableBuilder<int>(
        valueListenable: diagnostics.revision,
        builder: (context, _, child) => StreamBuilder<PlayerPositionData>(
          stream: handler.positionDataStream,
          initialData: PlayerPositionData.zero,
          builder: (context, positionSnapshot) {
            final state = <String, Object?>{
              ...handler.diagnosticState,
              'positionMs': positionSnapshot.data?.position.inMilliseconds,
              'bufferedPositionMs':
                  positionSnapshot.data?.bufferedPosition.inMilliseconds,
              'durationMs': positionSnapshot.data?.duration.inMilliseconds,
            };
            final events = diagnostics.structuredSnapshot();
            final lastError = _lastEvent(
              events,
              (event) => event.contains('ERROR') || event.contains('FAILED'),
            );
            final lastNetwork = _lastEvent(
              events,
              (event) => event.contains('NETWORK') || event.contains('HTTP'),
            );
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
              children: [
                _StatusCard(
                  title: 'Lecteur',
                  values: {
                    'État': state['processingState'],
                    'Lecture': state['playing'],
                    'Index': state['currentIndex'],
                    'Taille file': state['queueLength'],
                    'Piste': state['trackId'],
                    'Position': _duration(state['positionMs']),
                    'Durée': _duration(state['durationMs']),
                    'Tampon': _duration(state['bufferedPositionMs']),
                    'Repeat': state['repeatMode'],
                    'Shuffle': state['shuffleMode'],
                    'Moteur': state['timeStretchEngine'],
                    'Vitesse': state['timeStretchRatio'],
                  },
                ),
                _StatusCard(
                  title: 'Fiabilité',
                  values: {
                    'Token expire dans': _duration(state['tokenExpiresInMs']),
                    'Refresh actif': state['authorizationRecoveryInFlight'],
                    'Recovery actif': state['trackRecoveryInFlight'],
                    'Bufferings': state['bufferingCount'],
                    'Buffering total': _duration(state['totalBufferingMs']),
                    'Plus long buffering': _duration(
                      state['longestBufferingMs'],
                    ),
                    'Événements': diagnostics.eventCount,
                    'Session': diagnostics.playbackSessionId,
                    'Révision file': diagnostics.queueRevisionId,
                    'Dernier réseau': lastNetwork?['event'],
                    'Dernière erreur':
                        lastError?['message'] ??
                        lastError?['error'] ??
                        lastError?['event'],
                  },
                ),
                SwitchListTile(
                  title: const Text('Diagnostic audio'),
                  subtitle: const Text('Journal normal roulant et borné.'),
                  value: AudioDiagnostics.enabled,
                  onChanged: AudioDiagnostics.available
                      ? diagnostics.setEnabled
                      : null,
                ),
                SwitchListTile(
                  title: const Text('Trace audio verbeuse'),
                  subtitle: const Text(
                    'Désactivation automatique après 15 minutes.',
                  ),
                  value: diagnostics.isTraceEnabled,
                  onChanged:
                      (kDebugMode || AudioDiagnostics.traceAvailable) &&
                          AudioDiagnostics.available
                      ? diagnostics.setTraceEnabled
                      : null,
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: () {
                    diagnostics.markProblem(context: handler.diagnosticState);
                    _show('Problème marqué, contexte étendu pendant 2 min.');
                  },
                  icon: const Icon(Icons.flag_rounded),
                  label: const Text('Marquer maintenant comme problème'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _export(handler),
                  icon: const Icon(Icons.ios_share_rounded),
                  label: const Text('Exporter les logs'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    await Clipboard.setData(
                      ClipboardData(
                        text: const JsonEncoder.withIndent('  ').convert({
                          ...diagnostics.summary(),
                          'audioState': handler.diagnosticState,
                          'lastError': lastError,
                        }),
                      ),
                    );
                    _show('Résumé copié.');
                  },
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('Copier le résumé'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _showGuidedTest,
                  icon: const Icon(Icons.playlist_play_rounded),
                  label: const Text('Lancer un test audio guidé'),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: _busy ? null : _clear,
                  icon: const Icon(Icons.delete_outline_rounded),
                  label: const Text('Effacer les diagnostics'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Map<String, Object?>? _lastEvent(
    List<Map<String, Object?>> events,
    bool Function(String event) predicate,
  ) {
    for (final item in events.reversed) {
      final event = item['event']?.toString() ?? '';
      if (predicate(event)) return item;
    }
    return null;
  }

  String _duration(Object? milliseconds) {
    if (milliseconds is! num) return '—';
    final value = milliseconds.toInt();
    if (value < 0) return 'expiré';
    final duration = Duration(milliseconds: value);
    final minutes = duration.inMinutes;
    final seconds = duration.inSeconds.remainder(60);
    final millis = duration.inMilliseconds.remainder(1000);
    return minutes > 0
        ? '$minutes min ${seconds.toString().padLeft(2, '0')} s'
        : '$seconds.${millis.toString().padLeft(3, '0')} s';
  }

  Future<void> _export(HomeSpotifyAudioHandler handler) async {
    setState(() => _busy = true);
    try {
      await AudioDiagnostics.instance.exportToFile(
        device: {
          'operatingSystem': Platform.operatingSystem,
          'operatingSystemVersion': Platform.operatingSystemVersion,
          'locale': Platform.localeName,
        },
        audioState: handler.diagnosticState,
      );
      await Clipboard.setData(
        ClipboardData(text: AudioDiagnostics.instance.export()),
      );
      _show('Export créé et journal JSON Lines copié.');
    } catch (error) {
      AudioDiagnostics.instance.log('AUDIO_DIAGNOSTIC_EXPORT_FAILED', {
        'error': error,
      });
      _show('Export impossible.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    try {
      await AudioDiagnostics.instance.clear();
      _show('Diagnostics effacés.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showGuidedTest() {
    AudioDiagnostics.instance.log('AUDIO_GUIDED_TEST_STARTED');
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Test audio guidé'),
        content: const Text(
          '1. Lance une playlist de 20 pistes.\n'
          '2. Verrouille l’écran pendant 60 minutes.\n'
          '3. Teste ensuite Wi-Fi → 5G, pause/reprise et Bluetooth.\n'
          '4. En cas d’incident, marque immédiatement le problème.\n'
          '5. Reviens ici puis exporte les diagnostics.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Compris'),
          ),
        ],
      ),
    );
  }

  void _show(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.title, required this.values});

  final String title;
  final Map<String, Object?> values;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final entry in values.entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Text(
                        entry.key,
                        style: const TextStyle(color: Colors.white60),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        entry.value?.toString() ?? '—',
                        textAlign: TextAlign.end,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
