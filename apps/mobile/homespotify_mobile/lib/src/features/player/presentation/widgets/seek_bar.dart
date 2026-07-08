import 'package:flutter/material.dart';

/// Barre de progression tactile.
///
/// Robuste : ne plante jamais si la durée est nulle ou inconnue (barre désactivée).
/// Pendant le glissement, suit le doigt localement puis émet la position finale
/// via [onSeek] (on ne spamme pas `seek` à chaque frame).
class SeekBar extends StatefulWidget {
  const SeekBar({
    super.key,
    required this.position,
    required this.duration,
    this.bufferedPosition = Duration.zero,
    this.onSeek,
  });

  final Duration position;
  final Duration duration;
  final Duration bufferedPosition;
  final ValueChanged<Duration>? onSeek;

  @override
  State<SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<SeekBar> {
  double? _dragValueMs;

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration.inMilliseconds;
    final hasDuration = totalMs > 0;
    final maxMs = hasDuration ? totalMs.toDouble() : 1.0;

    final positionMs = widget.position.inMilliseconds.toDouble();
    final currentMs = (_dragValueMs ?? positionMs).clamp(0.0, maxMs);

    final displayed = _dragValueMs != null
        ? Duration(milliseconds: _dragValueMs!.round())
        : widget.position;

    return Column(
      children: [
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            activeTrackColor: const Color(0xFF1DB954),
            inactiveTrackColor: Colors.white24,
            thumbColor: Colors.white,
            overlayColor: const Color(0x291DB954),
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
          ),
          child: Slider(
            min: 0,
            max: maxMs,
            value: currentMs,
            // Désactivé (grisé) tant qu'aucune durée n'est connue.
            onChanged: hasDuration && widget.onSeek != null
                ? (v) => setState(() => _dragValueMs = v)
                : null,
            onChangeEnd: hasDuration && widget.onSeek != null
                ? (v) {
                    widget.onSeek!(Duration(milliseconds: v.round()));
                    setState(() => _dragValueMs = null);
                  }
                : null,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(_format(displayed), style: _timeStyle),
              Text(_format(widget.duration), style: _timeStyle),
            ],
          ),
        ),
      ],
    );
  }

  static const TextStyle _timeStyle = TextStyle(
    color: Colors.white54,
    fontSize: 12,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static String _format(Duration d) {
    if (d < Duration.zero) return '0:00';
    final minutes = d.inMinutes;
    final seconds = d.inSeconds % 60;
    final h = d.inHours;
    final mm = h > 0
        ? minutes.remainder(60).toString().padLeft(2, '0')
        : '$minutes';
    final ss = seconds.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
