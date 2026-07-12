import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

/// Slate — Paper Grain
///
/// A faint white-noise overlay so the warm-graphite canvas reads like a *page*
/// rather than a flat void. ~2.2% by default ([AppTheme.paperGrainOpacity]).
///
/// Performance: a single small noise tile is generated ONCE (cached static
/// future) and tiled via an [ImageShader]. The painter never repaints, so this
/// costs one raster and nothing thereafter. Wrap any surface, or drop it in a
/// Stack as a `Positioned.fill` overlay.
class PaperGrain extends StatefulWidget {
  final double opacity;

  /// Optional child painted *under* the grain. If null, the grain is just a
  /// transparent texture layer (use inside a Stack / Positioned.fill).
  final Widget? child;

  const PaperGrain({
    super.key,
    this.opacity = AppTheme.paperGrainOpacity,
    this.child,
  });

  @override
  State<PaperGrain> createState() => _PaperGrainState();
}

class _PaperGrainState extends State<PaperGrain> {
  static const int _tile = 96;
  static Future<ui.Image>? _cached;

  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    (_cached ??= _generate(_tile)).then((img) {
      if (mounted) setState(() => _image = img);
    });
  }

  static Future<ui.Image> _generate(int size) {
    final rnd = math.Random(0x51A7E); // fixed seed → stable grain
    final pixels = Uint8List(size * size * 4);
    for (int i = 0; i < size * size; i++) {
      // White noise in alpha; opacity is applied later via the paint color.
      final a = rnd.nextInt(256);
      pixels[i * 4] = 255;
      pixels[i * 4 + 1] = 255;
      pixels[i * 4 + 2] = 255;
      pixels[i * 4 + 3] = a;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      size,
      size,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    return completer.future;
  }

  @override
  Widget build(BuildContext context) {
    final img = _image;
    final grain = (img == null)
        ? const SizedBox.shrink()
        : IgnorePointer(
            child: CustomPaint(
              painter: _GrainPainter(img, widget.opacity),
              size: Size.infinite,
            ),
          );

    if (widget.child == null) return grain;
    return Stack(
      fit: StackFit.passthrough,
      children: [widget.child!, Positioned.fill(child: grain)],
    );
  }
}

class _GrainPainter extends CustomPainter {
  final ui.Image image;
  final double opacity;
  _GrainPainter(this.image, this.opacity);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..shader = ImageShader(
        image,
        TileMode.repeated,
        TileMode.repeated,
        Matrix4.identity().storage,
      )
      // ImageShader ignores paint.color, so modulate alpha down to `opacity`.
      ..colorFilter = ColorFilter.mode(
        Colors.white.withOpacity(opacity),
        BlendMode.modulate,
      );
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(_GrainPainter old) =>
      old.image != image || old.opacity != opacity;
}
