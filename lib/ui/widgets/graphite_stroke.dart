import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

/// Slate — The Living Graphite Stroke
///
/// Slate's signature mark. Not an icon — a single hand-drawn pencil line that
/// *does work* across the first-run experience:
///   • draws itself under the welcome greeting
///   • becomes the underline beneath the console invite
///   • curls into a check when the first task lands, then dissolves forever
///
/// One mark, three jobs. "Slate" is a writing surface; this is the writing.
///
/// Motion personality = "ink settling": the line draws L→R via path metrics
/// (pencil-on-paper), heavily ease-out, never bouncy. Honors reduce-motion by
/// snapping to the finished shape with no draw-on.

enum GraphiteStrokeMode {
  /// A gentle, hand-drawn horizontal line (welcome underline / console invite).
  underline,

  /// A hand-drawn check (the confirm moment when a blurt becomes a block).
  check,
}

// ─────────────────────────────────────────────────────────────────────────────
// PAINTER — partial-path draw-on with a pencil-grain texture pass
// ─────────────────────────────────────────────────────────────────────────────
class GraphiteStrokePainter extends CustomPainter {
  /// 0 = nothing drawn yet, 1 = fully drawn.
  final double progress;
  final GraphiteStrokeMode mode;
  final Color color;
  final double strokeWidth;

  /// Determines the hand "wobble" — same seed = same line every paint.
  final int seed;

  /// 0..1 honey bloom behind the stroke (used for the breathing "invite" state).
  final double glow;

  GraphiteStrokePainter({
    required this.progress,
    this.mode = GraphiteStrokeMode.underline,
    this.color = AppTheme.graphiteInk,
    this.strokeWidth = 2.2,
    this.seed = 7,
    this.glow = 0.0,
  });

  Path _buildPath(Size size) {
    final path = Path();

    if (mode == GraphiteStrokeMode.check) {
      // A hand-drawn check, centered, sized to the box.
      final cx = size.width / 2;
      final cy = size.height / 2;
      final s = math.min(size.width, size.height) * 0.42;
      path.moveTo(cx - s, cy + s * 0.05);
      // slight bow in each leg so it reads as drawn, not vector-perfect
      path.quadraticBezierTo(
          cx - s * 0.55, cy + s * 0.5, cx - s * 0.22, cy + s * 0.72);
      path.quadraticBezierTo(
          cx + s * 0.2, cy + s * 0.1, cx + s, cy - s * 0.72);
      return path;
    }

    // Underline: a near-horizontal line with small organic vertical jitter,
    // drawn as smooth cubics between jittered control points.
    final rnd = math.Random(seed);
    final y = size.height / 2;
    const segments = 5;
    final dx = size.width / segments;
    final amp = size.height * 0.28; // how much the hand "wavers"

    double prevX = 0;
    double prevY = y + (rnd.nextDouble() - 0.5) * amp * 0.5;
    path.moveTo(prevX, prevY);

    for (int i = 1; i <= segments; i++) {
      final x = dx * i;
      // ends settle near center; the middle is freer — like a real pen stroke
      final edgeDamp = (i == segments) ? 0.4 : 1.0;
      final ny = y + (rnd.nextDouble() - 0.5) * amp * edgeDamp;
      path.cubicTo(prevX + dx * 0.5, prevY, x - dx * 0.5, ny, x, ny);
      prevX = x;
      prevY = ny;
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final fullPath = _buildPath(size);

    // Extract the partial path up to `progress` of total length — the draw-on.
    final metrics = fullPath.computeMetrics().toList();
    final totalLen = metrics.fold<double>(0, (a, m) => a + m.length);
    double remaining = totalLen * progress.clamp(0.0, 1.0);
    final drawn = Path();
    for (final m in metrics) {
      if (remaining <= 0) break;
      final seg = math.min(remaining, m.length);
      drawn.addPath(m.extractPath(0, seg), Offset.zero);
      remaining -= seg;
    }

    // Honey bloom behind the line (the warm "invite" pulse).
    if (glow > 0) {
      final glowPaint = Paint()
        ..color = AppTheme.honey.withOpacity(0.20 * glow)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth * 3.4
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5 * glow + 2);
      canvas.drawPath(drawn, glowPaint);
    }

    // Main stroke. For the underline, a horizontal gradient fades the two ends
    // so it reads like pencil pressure easing in and out.
    final main = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    if (mode == GraphiteStrokeMode.underline) {
      main.shader = ui.Gradient.linear(
        Offset.zero,
        Offset(size.width, 0),
        [
          color.withOpacity(0.0),
          color.withOpacity(0.95),
          color.withOpacity(0.95),
          color.withOpacity(0.0),
        ],
        const [0.0, 0.07, 0.93, 1.0],
      );
    } else {
      main.color = color.withOpacity(0.95);
    }
    canvas.drawPath(drawn, main);

    // Texture pass: a fainter, slightly offset second line = pencil grain.
    final texture = Paint()
      ..color = AppTheme.graphiteInkSub.withOpacity(0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth * 0.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.save();
    canvas.translate(0, 0.6);
    canvas.drawPath(drawn, texture);
    canvas.restore();
  }

  @override
  bool shouldRepaint(GraphiteStrokePainter old) =>
      old.progress != progress ||
      old.mode != mode ||
      old.glow != glow ||
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.seed != seed;
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGET — drives the draw-on (and optional breathing honey glow)
// ─────────────────────────────────────────────────────────────────────────────
class GraphiteStroke extends StatefulWidget {
  final double width;
  final double height;
  final GraphiteStrokeMode mode;
  final Color color;
  final double strokeWidth;
  final int seed;

  /// Draw-on duration. "Ink settling" default — slow, unhurried.
  final Duration duration;
  final Duration delay;

  /// When true, draws on mount. When false, stays empty until set true.
  final bool play;

  /// After the line finishes drawing, breathe a soft honey glow (the "invite"
  /// state under the console). Ignored for [GraphiteStrokeMode.check].
  final bool breathe;

  /// Fires once the draw-on completes (e.g. to chain the check → dissolve).
  final VoidCallback? onDrawn;

  const GraphiteStroke({
    super.key,
    this.width = 220,
    this.height = 14,
    this.mode = GraphiteStrokeMode.underline,
    this.color = AppTheme.graphiteInk,
    this.strokeWidth = 2.2,
    this.seed = 7,
    this.duration = const Duration(milliseconds: 800),
    this.delay = Duration.zero,
    this.play = true,
    this.breathe = false,
    this.onDrawn,
  });

  @override
  State<GraphiteStroke> createState() => _GraphiteStrokeState();
}

class _GraphiteStrokeState extends State<GraphiteStroke>
    with TickerProviderStateMixin {
  late final AnimationController _draw;
  late final Animation<double> _drawCurve;
  late final AnimationController _breath;

  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _draw = AnimationController(vsync: this, duration: widget.duration);
    _drawCurve = CurvedAnimation(parent: _draw, curve: Curves.easeOutCubic);
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    );
    _draw.addStatusListener((s) {
      if (s == AnimationStatus.completed) {
        widget.onDrawn?.call();
        if (widget.breathe && widget.mode == GraphiteStrokeMode.underline) {
          _breath.repeat(reverse: true);
        }
      }
    });
    if (widget.play) _kickoff();
  }

  void _kickoff() {
    Future.delayed(widget.delay, () {
      if (mounted) _draw.forward();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the OS "reduce motion" setting — snap to finished, no draw-on.
    _reduceMotion = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
  }

  @override
  void didUpdateWidget(GraphiteStroke old) {
    super.didUpdateWidget(old);
    if (widget.play && !old.play) _kickoff();
    if (!widget.play && old.play) {
      _draw.reset();
      _breath.stop();
    }
  }

  @override
  void dispose() {
    _draw.dispose();
    _breath.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_reduceMotion && widget.play && !_draw.isCompleted) {
      _draw.value = 1.0;
    }
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: AnimatedBuilder(
        animation: Listenable.merge([_drawCurve, _breath]),
        builder: (context, _) {
          final glow = (widget.breathe && !_reduceMotion)
              ? 0.25 + _breath.value * 0.75
              : 0.0;
          return CustomPaint(
            painter: GraphiteStrokePainter(
              progress: _reduceMotion && widget.play ? 1.0 : _drawCurve.value,
              mode: widget.mode,
              color: widget.color,
              strokeWidth: widget.strokeWidth,
              seed: widget.seed,
              glow: glow,
            ),
          );
        },
      ),
    );
  }
}
