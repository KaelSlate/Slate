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
    final newOffset = (sc.offset + dy * widget.scrollMultiplier).clamp(
      sc.position.minScrollExtent,
      sc.position.maxScrollExtent,
    );
    sc.jumpTo(newOffset);
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
