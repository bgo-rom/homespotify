import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Retour visuel PREMIUM et éphémère « Installation lancée ».
///
/// S'affiche via un [OverlayEntry] enveloppé d'un [IgnorePointer] : l'overlay
/// ne bloque JAMAIS l'interface (le paquet continue de s'animer dessous). La
/// séquence dure ~1,2 s puis l'entrée se retire toute seule (aucune fuite).
///
/// Design : fond sombre semi-transparent avec glassmorphism ([BackdropFilter]),
/// coins très arrondis, fine bordure lumineuse, grand cercle lumineux qui
/// grandit, coche dessinée, éclat de particules/ondes, texte en fondu+glisse.
class AnimatedSuccessOverlay extends StatefulWidget {
  const AnimatedSuccessOverlay({
    super.key,
    required this.title,
    required this.artist,
    required this.onCompleted,
  });

  final String title;
  final String artist;

  /// Appelé une fois l'animation terminée (retrait de l'[OverlayEntry]).
  final VoidCallback onCompleted;

  /// Couleur d'accent lumineuse (vert HomeSpotify).
  static const Color accent = Color(0xFF1DB954);

  /// Insère l'overlay au-dessus de tout et retourne l'entrée créée. L'entrée se
  /// retire seule à la fin ; [onDismissed] est alors invoqué (ex. réarmer
  /// l'autoplay quand la carte suivante est stable).
  static OverlayEntry show(
    BuildContext context, {
    required String title,
    required String artist,
    VoidCallback? onDismissed,
  }) {
    final overlay = Overlay.of(context, rootOverlay: true);
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: AnimatedSuccessOverlay(
          title: title,
          artist: artist,
          onCompleted: () {
            entry.remove();
            onDismissed?.call();
          },
        ),
      ),
    );
    overlay.insert(entry);
    return entry;
  }

  @override
  State<AnimatedSuccessOverlay> createState() => _AnimatedSuccessOverlayState();
}

class _AnimatedSuccessOverlayState extends State<AnimatedSuccessOverlay>
    with SingleTickerProviderStateMixin {
  static const Duration _duration = Duration(milliseconds: 1200);

  late final AnimationController _controller;
  late final Animation<double> _circleScale;
  late final Animation<double> _checkProgress;
  late final Animation<double> _burstProgress;
  late final Animation<double> _textOpacity;
  late final Animation<double> _textSlide;
  late final Animation<double> _fade;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    // Retour haptique léger à l'apparition.
    HapticFeedback.lightImpact();

    _controller = AnimationController(vsync: this, duration: _duration);

    Animation<double> curve(double begin, double end, Curve c) =>
        CurvedAnimation(
          parent: _controller,
          curve: Interval(begin, end, curve: c),
        );

    _circleScale = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(curve(0.0, 0.42, Curves.easeOutBack));
    _checkProgress = curve(0.26, 0.62, Curves.easeInOut);
    _burstProgress = curve(0.14, 0.72, Curves.easeOutCubic);
    _textOpacity = curve(0.34, 0.60, Curves.easeOut);
    _textSlide = Tween<double>(
      begin: 14,
      end: 0,
    ).animate(curve(0.34, 0.66, Curves.easeOutCubic));
    // Apparition rapide du bloc, disparition douce à la fin.
    _fade = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: 1.0), weight: 18),
      TweenSequenceItem(tween: ConstantTween(1.0), weight: 64),
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.0), weight: 18),
    ]).animate(_controller);

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed && !_completed) {
        _completed = true;
        // Retrait DIFFÉRÉ (post-frame) : ne jamais retirer/disposer pendant la
        // notification du contrôleur.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.onCompleted(),
        );
      }
    });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Opacity(
          opacity: _fade.value.clamp(0.0, 1.0),
          child: Stack(
            children: [
              // Scrim très léger : concentre l'attention sans assombrir la carte.
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black.withValues(alpha: 0.28 * _fade.value),
                ),
              ),
              Center(child: _panel()),
            ],
          ),
        );
      },
    );
  }

  Widget _panel() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: AnimatedSuccessOverlay.accent.withValues(alpha: 0.45),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: AnimatedSuccessOverlay.accent.withValues(alpha: 0.22),
            blurRadius: 40,
            spreadRadius: 2,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          color: Colors.black.withValues(alpha: 0.52),
          padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 30),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 108,
                height: 108,
                child: CustomPaint(
                  painter: _BurstPainter(progress: _burstProgress.value),
                  child: Center(
                    child: Transform.scale(
                      scale: _circleScale.value,
                      child: _badge(),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _text(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _badge() {
    return Container(
      width: 76,
      height: 76,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [
            AnimatedSuccessOverlay.accent.withValues(alpha: 0.95),
            const Color(0xFF12833B),
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: AnimatedSuccessOverlay.accent.withValues(alpha: 0.55),
            blurRadius: 26,
            spreadRadius: 1,
          ),
        ],
      ),
      child: CustomPaint(
        painter: _CheckPainter(progress: _checkProgress.value),
      ),
    );
  }

  Widget _text() {
    return Opacity(
      opacity: _textOpacity.value,
      child: Transform.translate(
        offset: Offset(0, _textSlide.value),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Installation lancée',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${widget.title} — ${widget.artist}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 13.5),
            ),
          ],
        ),
      ),
    );
  }
}

/// Dessine la coche à l'intérieur du cercle, tracée progressivement (0→1).
class _CheckPainter extends CustomPainter {
  _CheckPainter({required this.progress});

  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // Coche relative à la taille (deux segments).
    final p1 = Offset(size.width * 0.28, size.height * 0.52);
    final p2 = Offset(size.width * 0.44, size.height * 0.67);
    final p3 = Offset(size.width * 0.74, size.height * 0.34);

    final path = Path()
      ..moveTo(p1.dx, p1.dy)
      ..lineTo(p2.dx, p2.dy)
      ..lineTo(p3.dx, p3.dy);
    final metric = path.computeMetrics().first;
    final drawn = metric.extractPath(
      0,
      metric.length * progress.clamp(0.0, 1.0),
    );
    canvas.drawPath(drawn, paint);
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress;
}

/// Onde d'expansion + petites particules radiales (éclat de confirmation).
class _BurstPainter extends CustomPainter {
  _BurstPainter({required this.progress});

  final double progress;
  static const int _particleCount = 8;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final center = size.center(Offset.zero);
    final maxRadius = size.width * 0.5;

    // Onde annulaire qui s'élargit et s'estompe.
    final ringOpacity = (1.0 - progress).clamp(0.0, 1.0);
    if (ringOpacity > 0) {
      final ringPaint = Paint()
        ..color = AnimatedSuccessOverlay.accent.withValues(
          alpha: 0.5 * ringOpacity,
        )
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5;
      canvas.drawCircle(
        center,
        maxRadius * (0.55 + 0.45 * progress),
        ringPaint,
      );
    }

    // Particules qui jaillissent puis s'éteignent.
    final particleOpacity = (1.0 - progress).clamp(0.0, 1.0);
    if (particleOpacity > 0) {
      final dotPaint = Paint()
        ..color = AnimatedSuccessOverlay.accent.withValues(
          alpha: particleOpacity,
        );
      for (var i = 0; i < _particleCount; i++) {
        final angle = (2 * math.pi / _particleCount) * i;
        final distance = maxRadius * (0.5 + 0.5 * progress);
        final dx = center.dx + math.cos(angle) * distance;
        final dy = center.dy + math.sin(angle) * distance;
        canvas.drawCircle(Offset(dx, dy), 2.6 * particleOpacity, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(_BurstPainter old) => old.progress != progress;
}
