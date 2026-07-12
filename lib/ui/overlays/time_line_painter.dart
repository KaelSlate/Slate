import 'dart:async';
import 'package:flutter/material.dart';

/// Slate — TIME LASER (Phase 16 — Global Coordinates)
/// Restored: Deep Cyan Neon Laser Aesthetic (static, no pulse).
/// Logic: Perfect Quartz 1-second ticks (rebuilds only when seconds change).
/// Zero-latency, 1 FPS update rate when idle.

class TimeLineOverlay extends StatefulWidget {
  final double hourColumnWidth;
  final DateTime zeroDate; // The anchor midnight for the ribbon
  final ScrollController? scrollController;
  final int centerIndex;

  const TimeLineOverlay({
    super.key,
    this.hourColumnWidth = 100,
    required this.zeroDate,
    this.scrollController,
    this.centerIndex = 2400,
  });

  @override
  State<TimeLineOverlay> createState() => _TimeLineOverlayState();
}

class _TimeLineOverlayState extends State<TimeLineOverlay> {
  Timer? _timer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Update exactly once a second.
    // Rebuilds only 1 frame per second when idle, avoiding any heavy battery usage.
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Listenable scrollListenable = widget.scrollController ?? ValueNotifier<int>(0);

    return AnimatedBuilder(
      animation: scrollListenable,
      builder: (context, _) {
        final scrollOffset = (widget.scrollController != null &&
            widget.scrollController!.hasClients)
            ? widget.scrollController!.offset
            : 0.0;

        final hoursDiff = _now.difference(widget.zeroDate).inHours;

        return CustomPaint(
          painter: _LaserBeamPainter(
            hoursDiff: hoursDiff,
            minute: _now.minute,
            second: _now.second,
            colWidth: widget.hourColumnWidth,
            scrollOffset: scrollOffset,
            centerIndex: widget.centerIndex,
          ),
          size: Size.infinite,
        );
      },
    );
  }
}

class _LaserBeamPainter extends CustomPainter {
  final int hoursDiff, minute, second;
  final double colWidth;
  final double scrollOffset;
  final int centerIndex;

  _LaserBeamPainter({
    required this.hoursDiff,
    required this.minute,
    required this.second,
    required this.colWidth,
    required this.scrollOffset,
    required this.centerIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Fraction includes seconds so the line ticks exactly once per second.
    final frac = minute / 60.0 + second / 3600.0;
    
    // Global absolute pixel position using hoursDiff from zeroDate
    final x = (centerIndex + hoursDiff + frac) * colWidth - scrollOffset;
    
    if (x < -100 || x > size.width + 100) return;

    // ═══════════════════════════════════════════════════════════════
    // LAYER 1 — Deep cyan atmospheric glow (STATIC, NO PULSE)
    // ═══════════════════════════════════════════════════════════════
    canvas.drawRect(
      Rect.fromLTWH(x - 20, 0, 40, size.height),
      Paint()
        ..color = const Color.fromRGBO(0, 229, 255, 0.015) // #00E5FF
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );

    // ═══════════════════════════════════════════════════════════════
    // LAYER 2 — Cyan edge halo
    // ═══════════════════════════════════════════════════════════════
    canvas.drawLine(
      Offset(x, 0), Offset(x, size.height),
      Paint()
        ..color = const Color.fromRGBO(0, 229, 255, 0.15) // #00E5FF
        ..strokeWidth = 3.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // ═══════════════════════════════════════════════════════════════
    // LAYER 3 — Core white line (1.5px, razor-sharp)
    // ═══════════════════════════════════════════════════════════════
    canvas.drawLine(
      Offset(x, 0), Offset(x, size.height),
      Paint()
        ..color = const Color.fromRGBO(255, 255, 255, 0.75)
        ..strokeWidth = 1.5
        ..strokeCap = StrokeCap.round,
    );

    // ═══════════════════════════════════════════════════════════════
    // LAYER 4 — The Dot
    // ═══════════════════════════════════════════════════════════════
    const dotY = 8.0;
    const dotR = 3.0;

    // Cyan outer bloom
    canvas.drawCircle(
      Offset(x, dotY), dotR + 4,
      Paint()
        ..color = const Color.fromRGBO(0, 229, 255, 0.08)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // White core dot
    canvas.drawCircle(
      Offset(x, dotY), dotR,
      Paint()..color = const Color.fromRGBO(255, 255, 255, 0.9),
    );

    // ═══════════════════════════════════════════════════════════════
    // LAYER 5 — Time pill BELOW hour headers (dy=40)
    // Translucent, borderless, elegant
    // ═══════════════════════════════════════════════════════════════
    final displayHour = ((hoursDiff % 24) + 24) % 24;
    // Show seconds! HH:MM:SS
    final label = '${displayHour.toString().padLeft(2, '0')}:'
        '${minute.toString().padLeft(2, '0')}:'
        '${second.toString().padLeft(2, '0')}';
        
    const ph = 20.0;
    final px = x + 8;
    const py = 40.0; // Below hour headers

    final tp = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          color: Color.fromRGBO(255, 255, 255, 0.8),
          fontSize: 10,
          fontWeight: FontWeight.w600,
          fontFamily: 'Inter',
          letterSpacing: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final pw = tp.width + 12; // Premium dynamic width to guarantee perfect balance
    final pillRect = Rect.fromLTWH(px, py, pw, ph);
    final pill = RRect.fromRectAndRadius(pillRect, const Radius.circular(10));

    // Pill background — highly translucent, no border
    canvas.drawRRect(pill, Paint()
      ..color = const Color.fromRGBO(0, 0, 0, 0.40));
    
    tp.paint(canvas, Offset(px + 6, py + (ph - tp.height) / 2));
  }

  @override
  bool shouldRepaint(covariant _LaserBeamPainter old) {
    // Only repaint if minute, second, or scroll position changes!
    return old.hoursDiff != hoursDiff ||
           old.minute != minute ||
           old.second != second ||
           old.scrollOffset != scrollOffset ||
           old.colWidth != colWidth ||
           old.centerIndex != centerIndex;
  }
}
