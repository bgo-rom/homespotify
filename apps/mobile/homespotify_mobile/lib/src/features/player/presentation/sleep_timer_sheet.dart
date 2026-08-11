import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_shapes.dart';
import '../audio/homespotify_audio_handler.dart';

Future<void> showSleepTimerSheet(BuildContext context, WidgetRef ref) async {
  final handler = ref.read(audioHandlerProvider);
  final message = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: context.colors.surface,
    isScrollControlled: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.tile)),
    ),
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
    final colors = context.colors;
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
            Row(
              children: [
                Icon(Icons.bedtime_rounded, color: colors.accent),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Minuteur de sommeil',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colors.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
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
              style: TextStyle(color: colors.textSecondary, height: 1.35),
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
              leading: Icon(
                Icons.skip_next_rounded,
                color: colors.textSecondary,
              ),
              title: Text(
                'À la fin du titre',
                style: TextStyle(color: colors.textPrimary),
              ),
              subtitle: Text(
                'Aucune piste suivante ne démarrera.',
                style: TextStyle(color: colors.textTertiary),
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
              Divider(color: colors.surfaceSunken),
              TextButton.icon(
                style: TextButton.styleFrom(foregroundColor: colors.danger),
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
    final colors = context.colors;
    return ActionChip(
      avatar: Icon(Icons.timer_outlined, size: 18, color: colors.textPrimary),
      label: Text(label),
      onPressed: onTap,
      backgroundColor: colors.surfaceRaised,
      labelStyle: TextStyle(color: colors.textPrimary),
      shape: RoundedRectangleBorder(borderRadius: AppRadius.chipRadius),
      side: BorderSide.none,
    );
  }
}
