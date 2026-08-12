import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../core/theme/app_theme.dart';

/// WHAT THE REMINDER CARD IS. `notify_window.dart` owns how the window behaves —
/// the channel, the springs, the lifetime; this file owns the thing you look at.
///
/// Two ideas run through all of it, and both are Apple's rather than ours:
///
///   1. The shell animates REAL GEOMETRY. A width and a height, not a matrix.
///      The contents are laid out at their final size once and never
///      transformed, so no glyph is ever stretched on any frame. Scaling a card
///      together with its text is an imitation of a morph and it always reads
///      cheap — that is the defect this file exists to correct.
///
///   2. Light CONCENTRATES where the pointer is. Liquid Glass calls it lensing:
///      the surface does not get painted grey on hover, it catches more light
///      in one place, and that place follows you with a few frames of lag.
///
/// Silhouettes are rounded superellipses, not rounded rectangles. Apple's
/// corners are continuous; a circular arc is the one detail of a shape the eye
/// reliably clocks as "not Apple" without being able to say why.

// ═══════════════════════════════════════════════════════════════════════════
// GEOMETRY — one source of truth for the painters and the clip
// ═══════════════════════════════════════════════════════════════════════════

/// The card's silhouette at this instant, in the card's own local coordinates.
///
/// [widthT] and [heightT] are the two entrance springs, 0 = seed pill, 1 =
/// settled card; both may overshoot past 1. [collapseT] runs the other way, for
/// the answered exit: 1 means the shell has become a small circle sitting on
/// [collapseCenter], which is the ring the person actually pressed.
@immutable
class ShellShape {
  const ShellShape({
    this.widthT = 1.0,
    this.heightT = 1.0,
    this.collapseT = 0.0,
    this.collapseCenter,
  });

  final double widthT;
  final double heightT;
  final double collapseT;
  final Offset? collapseCenter;

  static const ShellShape settled = ShellShape();

  Rect rect(Size size) {
    // Grown from the bottom edge: the card unfurls upward and outward from
    // where it landed, rather than inflating from thin air in the middle.
    final w = _lerp(AppTheme.notifySeedWidth, size.width, widthT);
    final h = _lerp(AppTheme.notifySeedHeight, size.height, heightT);
    final open = Rect.fromLTWH((size.width - w) / 2, size.height - h, w, h);
    if (collapseT <= 0 || collapseCenter == null) return open;
    final target = Rect.fromCircle(
      center: collapseCenter!,
      radius: AppTheme.notifyRingCollapseRadius,
    );
    return Rect.lerp(open, target, Curves.easeInOutCubic.transform(collapseT))!;
  }

  double radius(Size size) {
    final r = rect(size);
    // Curvature travels WITH the shape rather than snapping between two states
    // — a gradual change of curvature is what makes a morph look grown instead
    // of tweened. Never past half the short side, or the silhouette breaks.
    final open = _lerp(r.height / 2, AppTheme.notifyRadius, heightT);
    // Collapsing, the curvature runs toward HALF THE SHORT SIDE, so the card
    // passes through a capsule on its way to a circle. Lerping toward a fixed
    // small radius leaves a lozenge with square-ish ends instead — the shape
    // reads as a pill being shrunk rather than as the card being drawn into the
    // ring. Note the middle of this animation is still legitimately a capsule;
    // it is only the END that has to be a circle.
    final collapsed = collapseT <= 0
        ? open
        : _lerp(open, r.shortestSide / 2,
            Curves.easeInOutCubic.transform(collapseT));
    return collapsed.clamp(1.0, math.min(r.width, r.height) / 2);
  }

  RSuperellipse shape(Size size) {
    final r = rect(size);
    return RSuperellipse.fromLTRBR(
        r.left, r.top, r.right, r.bottom, Radius.circular(radius(size)));
  }

  /// How far along the whole entrance the CONTENT is — used to fade and
  /// un-blur it. Tied to the height spring, which is the one still working
  /// after the width has arrived.
  double get contentT => ((heightT - AppTheme.notifyContentFadeStart) /
          (AppTheme.notifyContentFadeEnd - AppTheme.notifyContentFadeStart))
      .clamp(0.0, 1.0);

  /// What the contents are actually worth right now, entrance and answered exit
  /// together. One expression, so the renderer and the golden that photographs
  /// it can never disagree about it.
  ///
  /// During the collapse this stays near full almost to the end, and the work
  /// of removing the text is done by the SHRINKING CLIP instead. That is the
  /// difference between "the card is being drawn into the checkmark" and "a
  /// green shape is getting smaller": the shell closes in around the ring, so
  /// the ring is the last thing still inside it. Fading the contents out early
  /// erased the target before the journey to it had started.
  double get contentOpacity {
    final leaving = ((collapseT - 0.75) / 0.25).clamp(0.0, 1.0);
    return contentT * (1.0 - leaving);
  }

  bool get isMorphing =>
      widthT < 0.999 || heightT < 0.999 || widthT > 1.001 || heightT > 1.001;

  @override
  bool operator ==(Object other) =>
      other is ShellShape &&
      other.widthT == widthT &&
      other.heightT == heightT &&
      other.collapseT == collapseT &&
      other.collapseCenter == collapseCenter;

  @override
  int get hashCode => Object.hash(widthT, heightT, collapseT, collapseCenter);
}

double _lerp(double a, double b, double t) => a + (b - a) * t;

/// Blur radius to sigma, the conversion `BoxShadow` itself uses. Shadows are
/// the one legitimate use of `MaskFilter.blur` here — it is exactly what a
/// `BoxDecoration` does under the hood. It stays OUT of the rim light, where it
/// once recomposited non-deterministically and made the edge flicker.
double _sigma(double radius) => radius * 0.57735 + 0.5;

class _MorphClipper extends CustomClipper<RSuperellipse> {
  const _MorphClipper(this.shape);
  final ShellShape shape;

  @override
  RSuperellipse getClip(Size size) => shape.shape(size);

  @override
  bool shouldReclip(_MorphClipper old) => old.shape != shape;
}

// ═══════════════════════════════════════════════════════════════════════════
// SHELL
// ═══════════════════════════════════════════════════════════════════════════

/// The body, its shadow stack, its rim, and the light that follows the pointer.
///
/// Hover is answered with DEPTH and LIGHT and never with a wash. Painting the
/// surface grey is Material and Windows grammar, and it is the single thing
/// that reads cheap on a dark card.
class ReminderCardShell extends StatefulWidget {
  const ReminderCardShell({
    super.key,
    required this.child,
    required this.acrylic,
    this.shape = ShellShape.settled,
    this.shadowShape,
    this.pressed = false,
    this.onHoverChanged,
    this.paintKey,
  });

  /// Attached to the box the painters actually paint in. Anything measuring a
  /// position for the shell — the collapse target, for instance — has to
  /// measure against THIS and not against the card's outer box, or the hover
  /// lift sitting between them shifts the answer by its own four pixels.
  final GlobalKey? paintKey;

  final Widget child;

  /// The compositor is blurring the desktop behind this window, so the body can
  /// be genuinely translucent — real glass rather than a dark rectangle.
  final bool acrylic;

  final ShellShape shape;

  /// The shadow's own, slightly-behind silhouette. That lag is the mass.
  final ShellShape? shadowShape;

  final bool pressed;
  final ValueChanged<bool>? onHoverChanged;

  @override
  State<ReminderCardShell> createState() => _ReminderCardShellState();
}

class _ReminderCardShellState extends State<ReminderCardShell>
    with TickerProviderStateMixin {
  late final AnimationController _hover;

  /// [_hover] shaped so that arriving and leaving both ease OUT.
  late final CurvedAnimation _hoverCurve;

  /// Where the light is, as opposed to where the pointer is. The gap between
  /// the two is the whole point.
  final ValueNotifier<Offset?> _light = ValueNotifier<Offset?>(null);
  Offset? _pointer;
  Ticker? _chase;

  /// Built ONCE. `Listenable.merge([...])` in a build method hands the
  /// AnimatedBuilder a brand-new object every frame, so it unsubscribes and
  /// resubscribes to both sources sixty times a second for no reason.
  late final Listenable _merged;

  /// True only while the press scale is actually travelling — see the note on
  /// `filterQuality` in [build].
  bool _pressMoving = false;

  @override
  void initState() {
    super.initState();
    _hover = AnimationController(
      vsync: this,
      duration: AppTheme.notifyHoverDuration,
      reverseDuration: AppTheme.notifyHoverDuration,
    );
    // The curve has to be on the ANIMATION, not on the controller's raw value.
    // Reading `easeOutCubic.transform(_hover.value)` off a linearly reversing
    // controller plays the curve backwards on exit: the derivative starts at 0
    // and ends at −3, so the light crept away and then vanished. Flipped, the
    // exit eases out too, which is what "the light leaves" should look like.
    _hoverCurve = CurvedAnimation(
      parent: _hover,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeOutCubic.flipped,
    );
    _merged = Listenable.merge([_hoverCurve, _light]);
  }

  @override
  void didUpdateWidget(ReminderCardShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pressed != oldWidget.pressed) _pressMoving = true;
  }

  @override
  void dispose() {
    _chase?.dispose();
    _hoverCurve.dispose();
    _hover.dispose();
    _light.dispose();
    super.dispose();
  }

  bool get _stillMotion => MediaQuery.of(context).disableAnimations;

  /// The card's own size, captured from a pointer callback (where reading a
  /// render object is legal) so the tilt can normalise the cursor position
  /// without a LayoutBuilder wrapping the whole shell.
  Size? _box;

  void _measure() {
    final b = context.findRenderObject();
    if (b is RenderBox && b.hasSize) _box = b.size;
  }

  void _enter(Offset local) {
    _measure();
    _pointer = local;
    // The light does not fly in from wherever it was left: it is simply already
    // where you arrived, and only lags once you start moving.
    _light.value ??= local;
    _chaseOrSnap();
    _hover.forward();
    widget.onHoverChanged?.call(true);
  }

  void _move(Offset local) {
    _pointer = local;
    _chaseOrSnap();
  }

  void _exit() {
    _pointer = null;
    // Forget where the light was. Left set, the `??=` in [_enter] only ever
    // snapped on the very first hover and every later one eased the light in
    // from wherever the cursor had last left — the exact "flying in" the note
    // up there says does not happen.
    _light.value = null;
    _chase?.stop();
    _hover.reverse();
    widget.onHoverChanged?.call(false);
  }

  void _chaseOrSnap() {
    if (_stillMotion) {
      _light.value = _pointer;
      return;
    }
    _chase ??= createTicker(_step);
    if (!_chase!.isActive) _chase!.start();
  }

  /// The light eases toward the pointer and then STOPS. A ticker that never
  /// stops would repaint the card sixty times a second while the cursor sits
  /// still — and it would also mean the widget never settles, which is exactly
  /// the sort of thing that makes a test hang instead of failing honestly.
  void _step(Duration _) {
    final target = _pointer;
    final current = _light.value;
    if (target == null || current == null) {
      _chase?.stop();
      return;
    }
    if ((target - current).distance < 0.15) {
      _light.value = target;
      _chase?.stop();
      return;
    }
    _light.value = Offset.lerp(current, target, AppTheme.notifyLightEase);
  }

  /// Lean away from the pointer, plus the lift, in one matrix.
  ///
  /// The lift travels in Z rather than in Y: raising a perspective object by
  /// moving it up the screen is the flat way to fake depth, and it fights the
  /// tilt. Bringing it toward the viewer is the same gesture told honestly —
  /// it grows very slightly, its shadow spreads, and the two agree.
  Matrix4 _tilt(double hover) {
    final m = Matrix4.identity()..setEntry(3, 2, AppTheme.notifyPerspective);
    if (hover <= 0.001) return m;
    m.translateByDouble(0.0, 0.0, AppTheme.notifyHoverLift * hover * -6.0, 1.0);
    final box = _box;
    final l = _light.value;
    if (box == null || l == null || box.width < 1 || box.height < 1) return m;
    // −1..1 from the centre, clamped, because the pointer can sit in the
    // shadow padding outside the card itself.
    final nx = ((l.dx / box.width) * 2 - 1).clamp(-1.0, 1.0);
    final ny = ((l.dy / box.height) * 2 - 1).clamp(-1.0, 1.0);
    m.rotateX(-ny * AppTheme.notifyTiltX * hover);
    m.rotateY(nx * AppTheme.notifyTiltY * hover);
    return m;
  }

  @override
  Widget build(BuildContext context) {
    final shadowShape = widget.shadowShape ?? widget.shape;
    return MouseRegion(
      onEnter: (e) => _enter(e.localPosition),
      onHover: (e) => _move(e.localPosition),
      onExit: (_) => _exit(),
      child: AnimatedBuilder(
        animation: _merged,
        builder: (context, child) {
          final hover = _hoverCurve.value;
          return Transform(
            // THE CARD IS A PHYSICAL OBJECT UNDER YOUR HAND.
            //
            // It leans away from the pointer — a real perspective rotation, not
            // a lift and a wash. This is the direction Apple took visionOS and
            // is now carrying into iOS and macOS 26: surfaces that answer where
            // you are with orientation, so shadow and specular shift together
            // and the glass reads as something you could pick up.
            //
            // The angles are small on purpose. Past about three degrees a card
            // this size stops looking like glass and starts looking like a
            // playing card being flipped, which is the web version of this idea
            // and the reason it usually reads as a gimmick.
            transform: _tilt(hover),
            alignment: Alignment.center,
            // The whole card leans, text included, so nothing shears against
            // anything else. At two degrees the resampling is invisible; what
            // is NOT invisible is a shell that tilts while its own contents
            // stay flat.
            filterQuality: hover > 0.001 ? FilterQuality.low : null,
            child: AnimatedScale(
              scale: widget.pressed ? AppTheme.notifyPressScale : 1.0,
              duration: AppTheme.notifyPressDuration,
              curve: Curves.easeOut,
              // Live text under a scale: without this the glyphs hop a pixel on
              // the last frame (manifest, section 7). Set ONLY while it moves —
              // a non-null filterQuality makes RenderTransform push an
              // ImageFilterLayer unconditionally and marks the subtree as
              // always-compositing, so leaving it on resamples the whole card
              // through an offscreen forever, at rest, for nothing.
              filterQuality: _pressMoving ? FilterQuality.low : null,
              onEnd: () {
                if (mounted) setState(() => _pressMoving = false);
              },
              child: Stack(
                children: [
                  // The shadow is three Gaussian blurs and it does NOT depend on
                  // where the pointer is. Behind its own boundary, so moving the
                  // light re-records the body and the rim and leaves ~350k px of
                  // blur coverage sitting in a retained raster.
                  Positioned.fill(
                    child: RepaintBoundary(
                      child: IgnorePointer(
                        child: CustomPaint(
                          painter: _ShadowPainter(
                            shape: shadowShape,
                            hover: hover,
                            collapseT: widget.shape.collapseT,
                          ),
                        ),
                      ),
                    ),
                  ),
                  CustomPaint(
                    key: widget.paintKey,
                    painter: _ShellPainter(
                      shape: widget.shape,
                      acrylic: widget.acrylic,
                      collapseT: widget.shape.collapseT,
                    ),
                    foregroundPainter: _ShellRimPainter(
                      shape: widget.shape,
                      hover: hover,
                      collapseT: widget.shape.collapseT,
                    ),
                    // Deliberately a clip that also clips HIT TESTING: a control
                    // you cannot see is a control you must not be able to press.
                    // While the shell is still a 140 px pill the ring is not on
                    // screen yet, and a stray click landing on it would complete
                    // a task the person never read.
                    child: ClipRSuperellipse(
                      clipper: _MorphClipper(widget.shape),
                      child: child,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
        child: widget.child,
      ),
    );
  }
}

/// The shadow, and NOTHING else.
///
/// Three Gaussian blurs covering roughly 350k device pixels, and not one of
/// them depends on where the pointer is. Sharing a painter with the light meant
/// re-rasterising all of it on every frame the cursor moved. Behind its own
/// `RepaintBoundary` the raster is simply retained.
///
/// Drawn as rounded RECTANGLES on purpose: nobody alive can distinguish a
/// superellipse from a rounded rect through a 30-sigma blur, and `drawRRect` is
/// the shape with the guaranteed analytic blur fast path.
class _ShadowPainter extends CustomPainter {
  const _ShadowPainter({
    required this.shape,
    required this.hover,
    required this.collapseT,
  });

  final ShellShape shape;
  final double hover;
  final double collapseT;

  @override
  void paint(Canvas canvas, Size size) {
    final r = shape.rect(size);
    final radius = shape.radius(size);

    // The wide one puts the card in the room, the middle one gives it a body,
    // and the tight one at the very edge is what sets it ON the desk instead of
    // floating vaguely above it.
    void drop(double alpha, double blur, double dy) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r.shift(Offset(0, dy)), Radius.circular(radius)),
        Paint()
          ..color = Colors.black.withValues(alpha: alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, _sigma(blur)),
      );
    }

    final fade = 1.0 - collapseT;
    if (fade <= 0.001) return;
    drop(_lerp(0.42, 0.56, hover) * fade, _lerp(38, 54, hover),
        _lerp(16, 22, hover));
    drop(0.30 * fade, 16, 6);
    drop(0.22 * fade, 3, 1);
  }

  @override
  bool shouldRepaint(_ShadowPainter old) =>
      old.shape != shape ||
      old.hover != hover ||
      old.collapseT != collapseT;
}

/// Behind the contents: the body. Nothing else — the light lives on the rim,
/// and none of it depends on the pointer, so this painter no longer repaints
/// while the mouse moves.
class _ShellPainter extends CustomPainter {
  const _ShellPainter({
    required this.shape,
    required this.acrylic,
    required this.collapseT,
  });

  final ShellShape shape;
  final bool acrylic;
  final double collapseT;

  @override
  void paint(Canvas canvas, Size size) {
    final body = shape.shape(size);

    // ── body ─────────────────────────────────────────────────────────────────
    // Over real acrylic the body is a TINT, not a wall: the desktop stays
    // visible through it. Without acrylic (Windows 10) it falls back to the
    // solid body — degraded, never broken.
    final base = acrylic
        ? AppTheme.background.withValues(alpha: AppTheme.notifyAcrylicBody)
        : AppTheme.glassOpaqueBody;
    // On the answered exit the shell greens as it shrinks, so what winks out is
    // unmistakably the completion and not a card being taken away. The tint is
    // blended INTO the body rather than lerped toward a translucent green:
    // lerping the colour also lerps its alpha, and the card turned into a pale
    // see-through blob on its way out.
    // Eased IN, so the card does not flash green the instant it is answered.
    // It stays itself while it is still a card and only becomes the ring's
    // colour as it becomes the ring's size — the tint arrives with the shape
    // rather than announcing it.
    final bodyColor = Color.lerp(
      base,
      Color.alphaBlend(
          AppTheme.taskDone.withValues(alpha: AppTheme.notifyCollapseTint),
          base),
      Curves.easeInCubic.transform(collapseT.clamp(0.0, 1.0)),
    )!;
    canvas.drawRSuperellipse(body, Paint()..color = bodyColor);

    // ── NO LIGHT ON THE SURFACE. THIS IS DELIBERATE. ─────────────────────────
    //
    // There used to be a specular pool here that followed the pointer, then a
    // version that slid against it as the reflection of a fixed lamp. Both were
    // wrong for this surface, and the second was wrong in a louder way: motion
    // against the cursor draws MORE attention to the fact that a decoration is
    // moving.
    //
    // The reference settles it. macOS notification banners do not respond to
    // where the cursor is — no travelling highlight, no glow, nothing. Hover
    // reveals an affordance; it does not light the glass. The travelling
    // specular is a visionOS and tvOS idiom, and those are FOCUS-driven
    // surfaces on displays you do not touch with a pointer. Transplanted onto a
    // desktop banner it is the grammar of a landing-page card, which is exactly
    // what it read as.
    //
    // What remains is one fixed overhead source, expressed entirely on the rim:
    // bright top edge, faint bottom caustic, dark outer boundary. The card
    // still answers the pointer — it leans, it lifts, its shadow spreads — but
    // the LIGHT never moves, because in the real world the lamp does not follow
    // your hand. One source, honestly placed, and nothing chasing anything.
  }

  @override
  bool shouldRepaint(_ShellPainter old) =>
      old.shape != shape ||
      old.acrylic != acrylic ||
      old.collapseT != collapseT;
}

/// Over the contents: the glass edge, lit by ONE fixed overhead source. A dark
/// boundary outside, an even hairline, light on the top curve, light leaving
/// the bottom edge (that is thickness). Nothing here follows the pointer;
/// `hover` only changes how bright the top is, never where it is.
class _ShellRimPainter extends CustomPainter {
  const _ShellRimPainter({
    required this.shape,
    required this.hover,
    required this.collapseT,
  });

  final ShellShape shape;
  final double hover;
  final double collapseT;

  @override
  void paint(Canvas canvas, Size size) {
    final w = AppTheme.glassSpecCoreWidth;
    final r = shape.rect(size);
    final radius = shape.radius(size);
    final inset = RSuperellipse.fromLTRBR(
      r.left + w / 2,
      r.top + w / 2,
      r.right - w / 2,
      r.bottom - w / 2,
      Radius.circular(math.max(0.5, radius - w / 2)),
    );
    Paint stroke() => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w;

    final fade = 1.0 - collapseT;

    // ── the dark edge, FIRST and OUTSIDE ─────────────────────────────────────
    // Everything below is light landing on this. Without it, brightening the
    // top rim only makes the card glow and dissolve into a pale background;
    // with it, the same highlight becomes the lit edge of a solid object. That
    // contrast is where the sense of thickness comes from — it is why Golden
    // Gate darkened the edge and brightened the specular in one move, and not
    // one without the other.
    //
    // On the OUTSET path and even all round: the object has thickness
    // everywhere, only the light is directional. Drawn outside the silhouette,
    // which is fine — this is a foreground painter and it is not clipped, and
    // the window's region has ~50 px of shadow padding beyond it.
    final dw = AppTheme.notifyRimDarkWidth;
    canvas.drawRSuperellipse(
      RSuperellipse.fromLTRBR(
        r.left - dw / 2,
        r.top - dw / 2,
        r.right + dw / 2,
        r.bottom + dw / 2,
        Radius.circular(radius + dw / 2),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = dw
        ..color = Colors.black
            .withValues(alpha: AppTheme.notifyRimDarkOpacity * fade),
    );

    // Even hairline around the whole perimeter — or, on the answered exit, the
    // ring's own border, since by then the shell IS the ring.
    canvas.drawRSuperellipse(
      inset,
      stroke()
        ..color = Color.lerp(
          Colors.white.withValues(alpha: AppTheme.notifyRimEvenOpacity),
          AppTheme.taskDone.withValues(alpha: 0.60),
          collapseT,
        )!,
    );

    // Clipped to the INSET path, the one the strokes are actually centred on.
    // Clipping to the outer silhouette cut the outer half of every stroke, so
    // the gradient rims measured half-width, and the clip's antialias multiplied
    // with the stroke's along the curves — a dirtier, darker edge on the corners
    // only, which is exactly the sort of thing you see and cannot name.
    canvas.save();
    canvas.clipRSuperellipse(inset);

    // Overhead light on the curved top, brighter when the card is lifted.
    canvas.drawRSuperellipse(
      inset,
      stroke()
        ..shader = ui.Gradient.linear(
          Offset(r.center.dx, r.top),
          Offset(r.center.dx, r.bottom),
          [
            Colors.white.withValues(
                alpha: (_lerp(AppTheme.notifyRimTopOpacity,
                            AppTheme.notifyRimTopHoverOpacity, hover) *
                        fade)
                    .clamp(0.0, 1.0)),
            Colors.white.withValues(alpha: 0.0),
          ],
          const [0.0, 0.35],
        ),
    );

    // Light exiting the bottom edge = thickness.
    canvas.drawRSuperellipse(
      inset,
      stroke()
        ..shader = ui.Gradient.linear(
          Offset(r.center.dx, r.bottom),
          Offset(r.center.dx, r.top),
          [
            Colors.white.withValues(
                alpha: AppTheme.glassRimBottomOpacity * fade),
            Colors.white.withValues(alpha: 0.0),
          ],
          const [0.0, 0.25],
        ),
    );

    // The pointer-tracking lens lived here and is gone with the surface pool.
    // Keeping it would have been the same mistake in a smaller place: a bright
    // spot travelling along the edge is still a light source riding the cursor,
    // and the top gradient above already says the lamp is fixed and overhead.
    // The rim answers hover by getting BRIGHTER, not by lighting somewhere
    // else — see notifyRimTopHoverOpacity.
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ShellRimPainter old) =>
      old.shape != shape ||
      old.hover != hover ||
      old.collapseT != collapseT;
}

/// The contents MATERIALISE into a shell that has already arrived: opacity,
/// blur and a few pixels of drift, all on the same clock.
///
/// Apple's rule is that a thing materialises by animating its blur TOGETHER
/// with its other properties — fading alone is a slide with the lights off.
/// Nothing here is ever scaled, so no glyph is ever distorted.
class MaterialisingContent extends StatelessWidget {
  const MaterialisingContent({
    super.key,
    required this.t,
    required this.child,
  });

  /// 0 = not there yet, 1 = fully present and perfectly sharp.
  final double t;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final clamped = t.clamp(0.0, 1.0);
    return Opacity(
      opacity: clamped,
      // ONE widget type, always. Mounting an `ImageFiltered` only while the
      // blur is non-zero looks like the thrifty version and is a trap: the slot
      // changes runtimeType, so `Widget.canUpdate` fails and Flutter tears down
      // and re-inflates the ENTIRE content subtree — every row, every state
      // object — in a single frame, at the tail of the entrance, which is the
      // most jank-sensitive moment there is. `_MaybeBlur` keeps the element
      // identical and decides about the layer at paint time instead.
      child: _MaybeBlur(
        sigma: AppTheme.notifyContentBlurSigma * (1.0 - clamped),
        child: Transform.translate(
          offset: Offset(0, (1.0 - clamped) * AppTheme.notifyContentRise),
          child: child,
        ),
      ),
    );
  }
}

/// A blur that can be zero without changing the shape of the widget tree.
class _MaybeBlur extends SingleChildRenderObjectWidget {
  const _MaybeBlur({required this.sigma, super.child});

  final double sigma;

  @override
  _RenderMaybeBlur createRenderObject(BuildContext context) =>
      _RenderMaybeBlur(sigma);

  @override
  void updateRenderObject(BuildContext context, _RenderMaybeBlur renderObject) {
    renderObject.sigma = sigma;
  }
}

class _RenderMaybeBlur extends RenderProxyBox {
  _RenderMaybeBlur(this._sigma);

  /// Below this the blur is sub-pixel — paying for an offscreen to draw the
  /// picture unchanged.
  static const double _floor = 0.05;

  double _sigma;
  set sigma(double value) {
    if (_sigma == value) return;
    final wasBlurring = _sigma > _floor;
    _sigma = value;
    if (wasBlurring != (value > _floor)) markNeedsCompositingBitsUpdate();
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => _sigma > _floor;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    if (_sigma <= _floor) {
      layer = null;
      context.paintChild(child!, offset);
      return;
    }
    final filter = ui.ImageFilter.blur(sigmaX: _sigma, sigmaY: _sigma);
    final blur = (layer as ImageFilterLayer?) ?? ImageFilterLayer();
    blur.imageFilter = filter;
    layer = blur;
    context.pushLayer(blur, super.paint, offset);
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// ROW
// ═══════════════════════════════════════════════════════════════════════════

/// One reminder. The app mark lives INSIDE the first row and the others reserve
/// its width, so the text column stays one straight edge. Hoisting the mark
/// into its own column looked tidy and broke three things at once: the hover
/// stopped short of it, a collapsing row dragged the text up past a mark that
/// stayed put, and the ring could not own its own pointer.
class ReminderRow extends StatefulWidget {
  const ReminderRow({
    super.key,
    required this.title,
    required this.time,
    required this.lede,
    required this.priority,
    required this.showMark,
    required this.isLastRow,
    required this.showDivider,
    required this.striking,
    required this.onOpen,
    required this.onDone,
    required this.onCollapsed,
    required this.onPressedChanged,
    this.ringKey,
  });

  final String title;
  final String time;

  /// Already written by the main isolate — how far ahead this is, in words.
  /// This file composes no copy: the sentence used to be the literal string
  /// `in five minutes` sitting right here, which was both a layering violation
  /// and, in a merged stack, a lie about two of the three rows.
  final String lede;

  final int priority;

  /// Only the first row carries Slate's face.
  final bool showMark;

  /// The only row left: the whole card leaves rather than a row collapsing
  /// inside a card that would then be empty.
  final bool isLastRow;
  final bool showDivider;
  final bool striking;
  final VoidCallback onOpen;
  final VoidCallback onDone;
  final VoidCallback onCollapsed;
  final ValueChanged<bool> onPressedChanged;

  /// Lets the scene find this ring's centre — the answered exit collapses the
  /// whole card into it.
  final GlobalKey? ringKey;

  @override
  State<ReminderRow> createState() => ReminderRowState();
}

class ReminderRowState extends State<ReminderRow> {
  double _height = 1.0;

  Color? get _accent => switch (widget.priority) {
        2 => AppTheme.priorityCritical,
        1 => AppTheme.priorityHigh,
        _ => null,
      };

  @override
  void didUpdateWidget(ReminderRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.striking && !oldWidget.striking && !widget.isLastRow) {
      // One of several: this row folds and the rest close up over it. The LAST
      // row never folds — the scene collapses the whole card into the ring
      // instead, which is both prettier and the reason the contents no longer
      // slide up past a mark that stayed put.
      setState(() => _height = 0.0);
      Future<void>.delayed(AppTheme.notifyCollapseDuration, () {
        if (mounted) widget.onCollapsed();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    return AnimatedSize(
      duration: AppTheme.notifyCollapseDuration,
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: SizedBox(
        height: _height == 0.0 ? 0 : null,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => widget.onPressedChanged(true),
          onTapCancel: () => widget.onPressedChanged(false),
          onTap: () {
            widget.onPressedChanged(false);
            widget.onOpen();
          },
          child: DecoratedBox(
            // NO wash. Hover is answered by the whole card lifting and catching
            // more light (ReminderCardShell).
            decoration: BoxDecoration(
              border: widget.showDivider
                  ? const Border(
                      top: BorderSide(
                          color: AppTheme.panelDivider, width: 0.5),
                    )
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 52,
                  child: widget.showMark
                      ? Padding(
                          padding: const EdgeInsets.only(left: 13),
                          child: ClipRSuperellipse(
                            borderRadius: BorderRadius.circular(7),
                            child: Image.asset(
                              'assets/icons/app_mark.png',
                              width: 28,
                              height: 28,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                        )
                      : null,
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 11, 4, 11),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          // Two lines, not one: a reminder that hides what the
                          // task actually says is not a reminder.
                          widget.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: AppFonts.inter(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.1,
                            height: 1.2,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            // PRIORITY, on a channel that is not colour.
                            //
                            // Whether a dot is there is not a judgement about
                            // hue, so this is the part a colour-blind reader
                            // gets. Only `!` and `!!` carry one — absence is
                            // the third state, and it stops working the moment
                            // every card has a mark.
                            if (accent != null) ...[
                              Container(
                                width: AppTheme.notifyPriorityDot,
                                height: AppTheme.notifyPriorityDot,
                                margin: const EdgeInsets.only(right: 6),
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: accent.withValues(alpha: 0.90),
                                ),
                              ),
                            ],
                            // Monospace time, exactly as the task cards in the
                            // app write it. Heavier when it matters — weight is
                            // the second non-chromatic channel.
                            Text(
                              widget.time,
                              style: AppFonts.robotoMono(
                                fontSize: 10.5,
                                fontWeight: accent != null
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                                letterSpacing: 0.2,
                                color: accent?.withValues(alpha: 0.85) ??
                                    Colors.white.withValues(alpha: 0.52),
                              ),
                            ),
                            // No sentence, no separator: an empty lede must not
                            // leave a hairline hanging after the time.
                            if (widget.lede.isNotEmpty) ...[
                              Container(
                                width: 0.5,
                                height: 9,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 7),
                                color: Colors.white.withValues(alpha: 0.10),
                              ),
                              // Written upstream, never here. Never "overdue",
                              // never a count of anything undone.
                              Text(
                                widget.lede,
                                style: AppFonts.inter(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w400,
                                  color: AppTheme.textTertiary,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                DoneRing(
                  key: widget.ringKey,
                  struck: widget.striking,
                  onTap: widget.onDone,
                ),
                const SizedBox(width: 10),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// THE RING
// ═══════════════════════════════════════════════════════════════════════════

/// The tick, drawn rather than typed.
///
/// A glyph from an icon font arrives all at once and its weight is whatever the
/// font decided. Stroking the path lets it DRAW itself — with round caps and a
/// weight chosen to match the ring.
class CheckPainter extends CustomPainter {
  const CheckPainter({required this.progress, required this.color});

  /// 0 = nothing, 1 = the whole tick. The two legs are drawn in sequence, the
  /// short one first, exactly as a hand would.
  final double progress;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final w = size.width, h = size.height;
    final a = Offset(w * 0.22, h * 0.52);
    final b = Offset(w * 0.42, h * 0.72);
    final c = Offset(w * 0.78, h * 0.30);

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.135
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = color;

    // Leg lengths decide how the progress is split, so the pen moves at a
    // constant speed instead of racing through the short leg.
    final l1 = (b - a).distance;
    final l2 = (c - b).distance;
    final total = l1 + l2;
    final travelled = total * progress.clamp(0.0, 1.0);

    final path = Path()..moveTo(a.dx, a.dy);
    if (travelled <= l1) {
      final t = travelled / l1;
      path.lineTo(a.dx + (b.dx - a.dx) * t, a.dy + (b.dy - a.dy) * t);
    } else {
      path.lineTo(b.dx, b.dy);
      final t = ((travelled - l1) / l2).clamp(0.0, 1.0);
      path.lineTo(b.dx + (c.dx - b.dx) * t, b.dy + (c.dy - b.dy) * t);
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(CheckPainter old) =>
      old.progress != progress || old.color != color;
}

/// The same GREEN as every checkbox in the app (`hover_task_card.dart`), so
/// finishing a task from the card lands in the same vocabulary as finishing it
/// anywhere else. It is not the same widget and the numbers deliberately differ:
/// this ring sits on glass over someone else's window rather than on a list, so
/// its resting border is brighter and its hit target is a full 44x44. Claiming
/// they were identical was simply untrue.
///
/// Hover does NOT preview the tick. Showing the result before the click spends
/// the reward, and at rest it reads as "this is already done". The ring simply
/// wakes up: greener, a little larger, a hint of fill.
///
/// Press is answered on POINTER-DOWN and instantly, because that is the moment
/// the finger is on it. The release springs back with real overshoot — bounce
/// is legitimate here precisely because a gesture earned it — and the tick
/// strokes itself in the same instant.
class DoneRing extends StatefulWidget {
  const DoneRing({super.key, required this.struck, required this.onTap});

  final bool struck;
  final VoidCallback onTap;

  @override
  State<DoneRing> createState() => DoneRingState();
}

class DoneRingState extends State<DoneRing> with TickerProviderStateMixin {
  bool _over = false;
  bool _down = false;

  /// The scale itself, so a spring can carry it past 1.0 and back.
  late final AnimationController _scale;
  late final AnimationController _draw;

  static const _green = AppTheme.taskDone;

  @override
  void initState() {
    super.initState();
    _scale = AnimationController(
      vsync: this,
      lowerBound: 0.5,
      upperBound: 1.5,
      value: 1.0,
    );
    _draw = AnimationController(
        vsync: this, duration: AppTheme.notifyTickDrawDuration);
    if (widget.struck) _draw.value = 1;
  }

  @override
  void didUpdateWidget(DoneRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.struck && !oldWidget.struck) {
      _draw.forward(from: 0);
    } else if (!widget.struck && oldWidget.struck) {
      _draw.value = 0;
    }
  }

  @override
  void dispose() {
    _scale.dispose();
    _draw.dispose();
    super.dispose();
  }

  bool get _stillMotion => MediaQuery.of(context).disableAnimations;

  double get _restingScale =>
      (_over && !widget.struck) ? AppTheme.notifyRingHoverScale : 1.0;

  void _springTo(double target, double damping) {
    if (_stillMotion) {
      _scale.value = target;
      return;
    }
    _scale.animateWith(
      SpringSimulation(
        SpringDescription(
          mass: 1.0,
          stiffness: AppTheme.notifyRingStiffness,
          damping: damping,
        ),
        _scale.value,
        target,
        _scale.velocity,
      ),
    );
  }

  void _setOver(bool over) {
    if (_over == over) return;
    setState(() => _over = over);
    if (!_down) _springTo(_restingScale, AppTheme.notifyRingHoverDamping);
  }

  void _press() {
    setState(() => _down = true);
    if (_stillMotion) {
      _scale.value = AppTheme.notifyRingPressScale;
      return;
    }
    _scale.animateTo(
      AppTheme.notifyRingPressScale,
      duration: AppTheme.notifyRingPressDuration,
      curve: Curves.easeOut,
    );
  }

  void _release() {
    if (!_down) return;
    setState(() => _down = false);
    _springTo(_restingScale, AppTheme.notifyRingReleaseDamping);
  }

  @override
  Widget build(BuildContext context) {
    final struck = widget.struck;
    final lit = _over && !struck;
    final down = _down && !struck;
    // A 14 % dent on an eighteen-pixel ring is a pixel and a half — real, and
    // completely invisible. The press has to answer in LIGHT as well as in
    // size, or there is no feedback at the moment the finger is actually down.
    final border = struck
        ? _green.withValues(alpha: 0.60)
        : down
            ? _green.withValues(alpha: 0.85)
            : lit
                ? _green.withValues(alpha: 0.62)
                // At 0.26 it had to be HUNTED FOR on the resting card. This is the
            // only thing on the card you can act on; everything louder than it
            // is text that does nothing. Visibility of the single action is not
            // the same as demanding attention.
            : Colors.white.withValues(alpha: 0.34);
    final fill = struck
        ? _green.withValues(alpha: 0.14)
        : down
            ? _green.withValues(alpha: 0.20)
            : lit
                ? _green.withValues(alpha: 0.08)
                : Colors.transparent;
    return MouseRegion(
      onEnter: (_) => _setOver(true),
      onExit: (_) => _setOver(false),
      // Listener, NOT `GestureDetector.onTapDown`.
      //
      // A tap recogniser does not report the press when the finger lands: it
      // waits either to win its arena — which for a fast click happens at
      // pointer-UP — or for the 100 ms press timeout. Either way the dent
      // arrived after the click was over, or not at all, which is the opposite
      // of Apple's rule and the opposite of what the comment below claimed.
      // A raw pointer event has no arena and no deadline.
      child: Listener(
        onPointerDown: struck ? null : (_) => _press(),
        onPointerUp: (_) => _release(),
        onPointerCancel: (_) => _release(),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: struck ? null : widget.onTap,
          // 44x44 is Apple's minimum click target. The ring stays small and
          // quiet; the area you can hit is generous. Missing it would open the
          // whole app and blow away whatever the person was doing.
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: AnimatedBuilder(
                animation: _scale,
                builder: (context, child) => Transform.scale(
                  scale: _scale.value,
                  // NO filterQuality here, ever.
                  //
                  // There is no live text under this — it is a circle, a border
                  // and a painted tick — so the manifest's rule does not apply.
                  // What toggling it DID do was flip `alwaysNeedsCompositing`
                  // on and off as the hover spring started and stopped, tearing
                  // down and rebuilding an ImageFilterLayer around an 18 px
                  // widget on the very frames it was animating. That is the
                  // ring "vanishing and coming back green".
                  child: child,
                ),
                child: AnimatedContainer(
                  // The press has to land NOW, not over a fifth of a second.
                  duration: down
                      ? AppTheme.notifyRingPressDuration
                      : const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: fill,
                    border: Border.all(
                      color: border,
                      width: struck || down ? 1.5 : 1.2,
                    ),
                    boxShadow: struck || down
                        ? [
                            BoxShadow(
                              color:
                                  _green.withValues(alpha: down ? 0.35 : 0.25),
                              blurRadius: 8,
                            )
                          ]
                        : null,
                  ),
                  child: AnimatedBuilder(
                    animation: _draw,
                    builder: (context, _) => CustomPaint(
                      painter: CheckPainter(
                        progress: _draw.value,
                        color: _green.withValues(alpha: 0.95),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
