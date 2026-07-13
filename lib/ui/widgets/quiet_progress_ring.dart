import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

/// Quiet progress — Slate's one progress mark, used everywhere a "4/13" used
/// to reproach. A small ring fills silently with what's DONE; there is no
/// denominator on screen, no number, no red. Zero tasks → nothing rendered
/// (an empty day is room to breathe, not a zero). The exact "n of m" appears
/// only on hover, only where [revealLabel] asks for it.
class QuietProgressRing extends StatefulWidget {
  final int completed;
  final int total;
  final double size;
  final bool revealLabel;
  /// Hover label side: true → label slides in to the LEFT of the ring
  /// (right-aligned hosts), false → to the right.
  final bool labelOnLeft;

  const QuietProgressRing({
    super.key,
    required this.completed,
    required this.total,
    this.size = 14,
    this.revealLabel = false,
    this.labelOnLeft = false,
  });

  @override
  State<QuietProgressRing> createState() => _QuietProgressRingState();
}

class _QuietProgressRingState extends State<QuietProgressRing> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    if (widget.total <= 0) return const SizedBox.shrink();
    final fraction =
        (widget.completed / widget.total).clamp(0.0, 1.0).toDouble();

    final ring = TweenAnimationBuilder<double>(
      tween: Tween(end: fraction),
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      builder: (context, f, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _RingPainter(fraction: f, complete: fraction >= 1.0),
      ),
    );

    if (!widget.revealLabel) return ring;

    final label = AnimatedOpacity(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      opacity: _hovered ? 1.0 : 0.0,
      child: Text(
        '${widget.completed} of ${widget.total}',
        style: AppFonts.inter(
          fontSize: 10.5,
          fontWeight: FontWeight.w500,
          color: Colors.white.withValues(alpha: 0.38),
          letterSpacing: 0.3,
        ),
      ),
    );

    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: widget.labelOnLeft
            ? [label, const SizedBox(width: 7), ring]
            : [ring, const SizedBox(width: 7), label],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final double fraction;
  final bool complete;
  _RingPainter({required this.fraction, required this.complete});

  static const _done = Color(0xFF30D158); // same green as the checkbox

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = math.max(1.4, size.width / 8.5);
    final center = size.center(Offset.zero);
    final radius = (size.width - stroke) / 2;

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = Colors.white.withValues(alpha: 0.10),
    );

    if (fraction <= 0) return;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        // Complete stays calm too: seven filled rings in a week row must
        // read as "settled", not as seven green lamps.
        ..color = _done.withValues(alpha: complete ? 0.70 : 0.55),
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.fraction != fraction || old.complete != complete;
}
