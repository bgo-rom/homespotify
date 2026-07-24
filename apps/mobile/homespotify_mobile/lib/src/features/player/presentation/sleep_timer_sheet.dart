import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../audio/homespotify_audio_handler.dart';

Future<void> showSleepTimerSheet(BuildContext context, WidgetRef ref) async {
  final handler = ref.read(audioHandlerProvider);
  final message = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: const Color(0xFF17171D),
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _SleepTimerSheet(handler: handler),
  );
  if (message == null || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

class _SleepTimerSheet extends StatefulWidget {
  const _SleepTimerSheet({required this.handler});

  final HomeSpotifyAudioHandler handler;

  @override
  State<_SleepTimerSheet> createState() => _SleepTimerSheetState();
}

class _SleepTimerSheetState extends State<_SleepTimerSheet> {
  static const _durations = <Duration>[
    Duration(minutes: 15),
    Duration(minutes: 30),
    Duration(minutes: 45),
    Duration(hours: 1),
  ];

  Timer? _ticker;

  SleepTimerState get _state => widget.handler.sleepTimerState;

  @override
  void initState() {
    super.initState();
    widget.handler.sleepTimerListenable.addListener(_onTimerChanged);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _state.mode == SleepTimerMode.timed) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.handler.sleepTimerListenable.removeListener(_onTimerChanged);
    super.dispose();
  }

  void _onTimerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          4,
          20,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Row(
              children: [
                Icon(Icons.bedtime_rounded, color: Color(0xFF1DB954)),
                SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Minuteur de sommeil',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              state.isActive
                  ? _activeDescription(state)
                  : 'La lecture se mettra en pause en conservant votre file.',
              style: const TextStyle(color: Colors.white60, height: 1.35),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final duration in _durations)
                  _DurationChoice(
                    label: _durationLabel(duration),
                    onTap: () {
                      widget.handler.armSleepTimer(duration);
                      Navigator.pop(
                        context,
                        'Minuteur réglé sur ${_durationLabel(duration)}.',
                      );
                    },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 4),
              leading: const Icon(
                Icons.skip_next_rounded,
                color: Colors.white70,
              ),
              title: const Text(
                'À la fin du titre',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                'Aucune piste suivante ne démarrera.',
                style: TextStyle(color: Colors.white54),
              ),
              onTap: () {
                widget.handler.armSleepTimerAtEndOfTrack();
                Navigator.pop(
                  context,
                  'La lecture s’arrêtera à la fin du titre.',
                );
              },
            ),
            if (state.isActive) ...[
              const Divider(color: Colors.white12),
              TextButton.icon(
                onPressed: () {
                  widget.handler.cancelSleepTimer();
                  Navigator.pop(context, 'Minuteur annulé.');
                },
                icon: const Icon(Icons.timer_off_rounded),
                label: const Text('Annuler le minuteur'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _activeDescription(SleepTimerState state) {
    if (state.mode == SleepTimerMode.endOfTrack) {
      return 'Actif · arrêt à la fin du titre en cours';
    }
    final remaining = state.remainingAt(DateTime.now());
    if (remaining <= Duration.zero) return 'Expiration imminente…';
    final totalSeconds = remaining.inSeconds;
    final hours = totalSeconds ~/ 3600;
    final minutes = (totalSeconds % 3600) ~/ 60;
    final seconds = totalSeconds % 60;
    if (hours > 0) {
      return 'Actif · ${hours}h ${minutes.toString().padLeft(2, '0')} min restantes';
    }
    return 'Actif · ${minutes.toString().padLeft(2, '0')}:'
        '${seconds.toString().padLeft(2, '0')} restantes';
  }

  static String _durationLabel(Duration duration) => duration.inHours >= 1
      ? '${duration.inHours} heure'
      : '${duration.inMinutes} min';
}

class _DurationChoice extends StatelessWidget {
  const _DurationChoice({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: const Icon(Icons.timer_outlined, size: 18),
      label: Text(label),
      onPressed: onTap,
      backgroundColor: const Color(0xFF272730),
      labelStyle: const TextStyle(color: Colors.white),
      side: const BorderSide(color: Colors.white12),
    );
  }
}
