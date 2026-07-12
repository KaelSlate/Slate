import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/engine/capture_destination.dart';
import '../../core/engine/quick_capture_controller.dart';
import '../../core/engine/slate_core_bridge.dart';
import '../../core/engine/spatial_zoom_engine.dart';
import '../../core/state/task_state.dart';
import '../screens/main_screen.dart';
import '../widgets/smart_day_input.dart';

/// The floating capture scene. Two hosts, same look:
/// - [inApp] false: the window is morphed into a Spotlight overlay.
/// - [inApp] true: stacked over MainScreen while Slate itself is focused —
///   the window is never touched.
/// Entrance: expands from the middle outwards on a spring (Apple input-reveal),
/// slight rise, fast fade-in. Exit: 170ms shrink + fade. Esc / outside click /
/// window blur all dismiss. Enter captures and dissolves; Shift+Enter captures
/// and keeps the pill open for a rapid dump.
class QuickCaptureOverlay extends ConsumerStatefulWidget {
  final bool inApp;
  const QuickCaptureOverlay({super.key, this.inApp = false});

  @override
  ConsumerState<QuickCaptureOverlay> createState() => _QuickCaptureOverlayState();
}

class _QuickCaptureOverlayState extends ConsumerState<QuickCaptureOverlay>
    with TickerProviderStateMixin {
  final FocusNode _focusNode = FocusNode();
  final SmartInputNotifier _notifier = SmartInputNotifier();
  late final AnimationController _enter;
  late final AnimationController _exit;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(vsync: this, lowerBound: 0.0, upperBound: 1.2);
    _exit = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 170));
    _enter.animateWith(SpringSimulation(
      SpringDescription(
        mass: 1.0,
        stiffness: 420.0,
        damping: 2 * 0.86 * math.sqrt(420.0),
      ),
      0.0,
      1.0,
      0.0,
    ));
    HardwareKeyboard.instance.addHandler(_keyHandler);
    QuickCaptureController.instance.dismissTick.addListener(_dismiss);
    // In-app: the pill is modal — pulse_layer/day_flow shortcuts stand down
    // (same contract as the day pill).
    if (widget.inApp) StaircaseState.isComposingTask = true;
  }

  @override
  void dispose() {
    if (widget.inApp) StaircaseState.isComposingTask = false;
    QuickCaptureController.instance.dismissTick.removeListener(_dismiss);
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    _enter.dispose();
    _exit.dispose();
    _focusNode.dispose();
    _notifier.dispose();
    super.dispose();
  }

  /// Plain Escape only. Escape WITH Alt still held never arrives here — Windows
  /// keeps Alt+Esc for itself — so the controller borrows that chord while the
  /// scene is up and routes it to [QuickCaptureController.dismissTick].
  bool _keyHandler(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _dismiss();
      return true;
    }
    return false;
  }

  void _onSubmit(String cleanTitle, ParseResult result) {
    final dest = resolveCapture(result, DateTime.now());
    ref.read(taskStateProvider).createCaptured(cleanTitle, result, dest);
    // Shift+Enter = rapid dump: capture and keep the pill open (field already
    // cleared + refocused by the widget). Plain Enter = one breath out —
    // let the submit pulse read, then dissolve back to work.
    if (HardwareKeyboard.instance.isShiftPressed) return;
    Future.delayed(const Duration(milliseconds: 140), _dismiss);
  }

  Future<void> _dismiss() async {
    if (_leaving || !mounted) return;
    _leaving = true;
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    _enter.stop();
    await _exit.animateTo(1.0, curve: Curves.easeInCubic);
    await QuickCaptureController.instance.finishAndRestore();
    // Restore was skipped (raced a concurrent morph) — this scene must stay
    // dismissable, not a frozen zombie that eats every later Escape.
    if (mounted &&
        !widget.inApp &&
        QuickCaptureController.instance.overlayMode.value) {
      _leaving = false;
      HardwareKeyboard.instance.addHandler(_keyHandler);
    }
  }

  /// Live MainScreen painted at the swallowed window's exact screen spot —
  /// summoning over a windowed Slate no longer makes the app "vanish".
  /// IgnorePointer: it's scenery; clicks fall through to the dismiss scrim.
  Widget? _windowGhost(BuildContext context) {
    final ctrl = QuickCaptureController.instance;
    final ghost = ctrl.ghostRect;
    final overlay = ctrl.overlayRect;
    if (widget.inApp || ghost == null || overlay == null) return null;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final rect = Rect.fromLTWH(
      (ghost.left - overlay.left) / dpr,
      (ghost.top - overlay.top) / dpr,
      ghost.width / dpr,
      ghost.height / dpr,
    );
    return Positioned.fromRect(
      rect: rect,
      child: IgnorePointer(
        child: ClipRect(
          // Same key as the app root → the LIVE MainScreen element reparents
          // here in one frame; no remount, no rebuild blink, state kept.
          child: KeyedSubtree(
            key: QuickCaptureController.mainScreenHostKey,
            child: const MainScreen(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final windowGhost = _windowGhost(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _dismiss,
        child: Stack(
          children: [
            if (windowGhost != null) windowGhost,
            // Whisper scrim over the whole desktop — focuses the eye on the
            // pill, fades with the entrance/exit. Same weight as the in-app
            // capture scrim.
            Positioned.fill(
              child: AnimatedBuilder(
                animation: Listenable.merge([_enter, _exit]),
                builder: (context, _) {
                  final tc = _enter.value.clamp(0.0, 1.0);
                  return ColoredBox(
                    color: Colors.black
                        .withOpacity(0.10 * tc * (1.0 - _exit.value)),
                  );
                },
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 48,
              child: Center(
                child: SizedBox(
                  width: 600,
                  child: GestureDetector(
                    onTap: () => _focusNode.requestFocus(),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.text,
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_enter, _exit]),
                        builder: (context, child) {
                          final t = _enter.value;
                          final tc = t.clamp(0.0, 1.0);
                          final ex = _exit.value;
                          final moving = _enter.isAnimating || _exit.isAnimating;
                          final scaled = Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.diagonal3Values(
                              (0.55 + 0.45 * t) * (1 - 0.06 * ex),
                              (0.90 + 0.10 * t) * (1 - 0.06 * ex),
                              1.0,
                            ),
                            // The text-hop rule wants filterQuality here, but it
                            // pushes an ImageFilterLayer (a saveLayer). In-app the
                            // pill is a real lens: its BackdropFilter would sample
                            // that empty layer for the WHOLE entrance and only
                            // "switch the blur on" at rest — the crystal-to-warm
                            // morph. Only the opaque out-of-app body may raster.
                            filterQuality: !widget.inApp && moving
                                ? FilterQuality.low
                                : null,
                            child: child,
                          );
                          return Transform.translate(
                            offset: Offset(0, (1 - tc) * 10 + ex * 6),
                            // In-app the pill is a REAL lens, and an animating
                            // Opacity above a BackdropFilter makes it sample an
                            // empty saveLayer for a frame — the glass blinks. So
                            // the fade only rides the opaque, out-of-app body;
                            // in-app the scrim's fade carries the reveal instead.
                            child: widget.inApp
                                ? scaled
                                : Opacity(
                                    opacity: ((tc / 0.35).clamp(0.0, 1.0) *
                                            (1.0 - ex))
                                        .clamp(0.0, 1.0),
                                    child: scaled,
                                  ),
                          );
                        },
                        child: SmartDayInputWidget(
                          core: SlateCore(),
                          focusNode: _focusNode,
                          notifier: _notifier,
                          floating: true,
                          opaqueBackdrop: !widget.inApp,
                          destinationLabel: (r) =>
                              resolveCapture(r, DateTime.now()).label,
                          onSubmit: _onSubmit,
                          onDismiss: _dismiss,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
