import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class DesktopScrollWrapper extends StatefulWidget {
  final ScrollController? scrollController;
  final PageController? pageController;
  final Widget child;
  final double scrollMultiplier;
  final int baseDurationMs;

  /// Quantum a wheel notch moves a [scrollController], in pixels. Set it and the
  /// wheel behaves exactly like the paged path: one notch = one unit, animated,
  /// rapid notches coalescing into one longer glide.
  ///
  /// The day ribbon passes its hour-column width. Without it the wheel did
  /// `jumpTo(offset + rawDelta)`, so whatever sub-column phase the view opened
  /// with survived every scroll — the leading hour label stayed sliced through
  /// the digits and there was no way to dial it back onto the line.
  final double? snapExtent;

  /// While this reads true the wheel is ignored, so a modal layer above the
  /// child (the month's opened-day popover) can own the scroll instead of the
  /// month paging under it. This handler acts synchronously and never touches
  /// the pointer-signal resolver, so a descendant cannot starve it — the gate
  /// has to live here.
  final ValueListenable<bool>? paused;

  const DesktopScrollWrapper({
    super.key,
    this.scrollController,
    this.pageController,
    required this.child,
    this.scrollMultiplier = 1.0,
    this.baseDurationMs = 400,
    this.snapExtent,
    this.paused,
  }) : assert(
         scrollController != null || pageController != null,
         'Provide either scrollController or pageController',
       );

  @override
  State<DesktopScrollWrapper> createState() => _DesktopScrollWrapperState();
}

class _DesktopScrollWrapperState extends State<DesktopScrollWrapper> {
  int? _targetPage;
  /// Snapped path: the unit index the ribbon is currently gliding towards, so
  /// rapid notches accumulate instead of restarting from the live position.
  int? _targetUnit;
  int _gen = 0;

  static const Curve _curve = Curves.easeOutCubic; // Быстрый старт, уверенный финиш без "затянутого" медленного хвоста

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: _handlePointerSignal,
      child: widget.child,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (widget.paused?.value ?? false) return; // a modal layer owns the wheel
    if (HardwareKeyboard.instance.isControlPressed) return;

    final dy = event.scrollDelta.dy;
    if (dy == 0) return;

    if (widget.pageController != null) {
      _onTick(dy);
      return;
    }

    final sc = widget.scrollController!;
    if (!sc.hasClients) return;

    final snap = widget.snapExtent;
    if (snap != null && snap > 0) {
      _onSnappedTick(sc, snap, dy);
      return;
    }

    final newOffset = (sc.offset + dy * widget.scrollMultiplier).clamp(
      sc.position.minScrollExtent,
      sc.position.maxScrollExtent,
    );
    sc.jumpTo(newOffset);
  }

  /// One notch = one [snap] unit, animated. Mirrors [_onTick] exactly — the day
  /// ribbon should tick like the week and the month tick, because it is the same
  /// gesture asking for the same thing.
  void _onSnappedTick(ScrollController sc, double snap, double dy) {
    final live = sc.offset / snap;
    final base = _targetUnit ?? live.round();
    final step = dy > 0 ? 1 : -1;
    final minUnit = (sc.position.minScrollExtent / snap).ceil();
    final maxUnit = (sc.position.maxScrollExtent / snap).floor();
    final newTarget = (base + step).clamp(minUnit, maxUnit);

    if (newTarget == _targetUnit) return;
    // Already hard against an end — nothing to glide to, and no click for it.
    if (newTarget == base && (sc.offset - base * snap).abs() < 0.5) return;

    HapticFeedback.selectionClick();
    _targetUnit = newTarget;

    final distance = (newTarget - live).abs();
    // Shorter than a page flip: this moves 100px, not a whole screen.
    final durationMs = (220 + 80 * distance).round().clamp(220, 600);
    final myGen = ++_gen;

    sc
        .animateTo(
          newTarget * snap,
          duration: Duration(milliseconds: durationMs),
          curve: _curve,
        )
        .then((_) {
          if (!mounted || _gen != myGen) return;
          _targetUnit = null;
        });
  }

  void _onTick(double dy) {
    final pc = widget.pageController!;
    if (!pc.hasClients) return;

    final livePos = pc.page ?? 0.0;
    final base = _targetPage ?? livePos.round();
    final step = dy > 0 ? 1 : -1;
    final newTarget = (base + step).clamp(0, 99999);

    if (newTarget == base && _targetPage == null) return;
    if (newTarget == _targetPage) return;

    // Apple-tier Haptics: отклик только при реальном переключении "тика"
    HapticFeedback.selectionClick();

    _targetPage = newTarget;

    final distance = (newTarget - livePos).abs();
    // Используем baseDurationMs, чтобы компенсировать разницу в пикселях между Week и Month
    final durationMs = (widget.baseDurationMs + 200 * distance).round().clamp(widget.baseDurationMs + 200, 2500);
    
    final myGen = ++_gen;

    pc
        .animateToPage(
          newTarget,
          duration: Duration(milliseconds: durationMs),
          curve: _curve,
        )
        .then((_) {
          if (!mounted || _gen != myGen) return;
          _targetPage = null;
        });
  }
}
