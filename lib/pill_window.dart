import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'core/engine/capture_destination.dart';
import 'core/engine/slate_core_bridge.dart';
import 'core/sfx/sfx.dart';
import 'core/theme/app_theme.dart';
import 'ui/widgets/smart_day_input.dart';

/// Entry for the SEPARATE pill window — a second Flutter engine the runner
/// launches with `--pill`. It is the global capture pill and NOTHING else, so
/// the main app window is never morphed (no cold swapchain, no jerk, no
/// maximize desync, no taskbar flash — the whole rounds 1-8 class is gone).
///
/// Native <-> pill talk over the `slate/pill` channel:
///   native -> dart : `warmup`  (start presenting frames — see _warmup)
///                    `reveal`  (window just shown → clear + play entrance + focus)
///   dart -> native : `capture` (serialized ParseResult → main isolate creates it)
///                    `dismiss` (hide the window, hand focus back)
const _channel = MethodChannel('slate/pill');

Future<void> runPillWindow() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Window.initialize();
  // Per-pixel transparent window: only the scrim + pill paint, everything else
  // is see-through — the Spotlight look, no black box.
  await Window.setEffect(
      effect: WindowEffect.transparent, color: Colors.transparent);
  // This is a SECOND isolate, so it has its own copy of Sfx's statics — arming
  // the main one does nothing here. Safe to arm immediately: unlike the main
  // window there is no warmup stage mounting phantom widgets, and the pill
  // cannot make a sound before the user summons it.
  await Sfx.init();
  Sfx.armed = true;
  runApp(const _PillApp());
}

class _PillApp extends StatelessWidget {
  const _PillApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const Scaffold(
        backgroundColor: Colors.transparent,
        body: _PillScene(),
      ),
    );
  }
}

class _PillScene extends StatefulWidget {
  const _PillScene();

  @override
  State<_PillScene> createState() => _PillSceneState();
}

class _PillSceneState extends State<_PillScene> with TickerProviderStateMixin {
  final FocusNode _focusNode = FocusNode();
  final SmartInputNotifier _notifier = SmartInputNotifier();
  final SlateCore _core = SlateCore(); // parse only — no engine/DB in this isolate
  late final AnimationController _enter;
  late final AnimationController _exit;
  late final AnimationController _warm;
  bool _leaving = false;

  // ── The rapid-dump lesson, owned here ─────────────────────────────────────
  // This engine has no prefs and no DB by design (that isolation is what killed
  // the whole rounds 1-8 bug class), so the lesson is session-scoped rather than
  // reaching across the isolate boundary for state that doesn't exist here.
  // Retires the moment the chord is used; gives up after a few summons so it
  // can never nag.
  static const _rapidHintSummons = 4;
  int _summons = 0;
  bool _shiftEnterUsed = false;

  bool get _showRapidHint => !_shiftEnterUsed && _summons <= _rapidHintSummons;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(vsync: this, lowerBound: 0.0, upperBound: 1.2);
    _exit = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 170));
    _warm = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 300));
    _channel.setMethodCallHandler(_onNative);
    HardwareKeyboard.instance.addHandler(_keyHandler);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    _enter.dispose();
    _exit.dispose();
    _warm.dispose();
    _focusNode.dispose();
    _notifier.dispose();
    super.dispose();
  }

  Future<dynamic> _onNative(MethodCall call) async {
    if (call.method == 'reveal') await _reveal();
    if (call.method == 'warmup') _warmup();
    return null;
  }

  /// The display changed size while this window sat hidden, so the runner is
  /// about to resize it — but a resize is only picked up by an engine that is
  /// PRESENTING. Between summons nothing animates here, so the engine is idle
  /// and would keep its old viewport: that is the pill-stretched-in-a-corner
  /// bug. Ticking this controller keeps frames flowing while every pixel stays
  /// transparent, so the resize lands and the user sees nothing at all.
  void _warmup() {
    _leaving = false;
    _exit.value = 0.0;
    _enter.value = 0.0;
    _warm.forward(from: 0.0);
  }

  /// Window was just shown by the runner: reset to a clean pill and play the
  /// entrance spring from zero, on screen.
  ///
  /// The REPLY to this call is what uncloaks the window (pill_window.cpp), so
  /// it must not come back before there are pixels: two frames — one builds the
  /// entrance, the second is proof the first reached the compositor.
  Future<void> _reveal() async {
    _leaving = false;
    // The summon sound. This runs BEFORE the reply that uncloaks the window, so
    // the rise leads the pixels by about two frames — which is what you want:
    // hearing is slower than seeing, and a sound that leads by a hair reads as
    // simultaneous, while one that trails reads as lag. Nudge it with the HUD's
    // delay slider if the ear disagrees.
    Sfx.pillAppear();
    // setState, not a bare ++: the pill widget reads _showRapidHint from THIS
    // build, so the counter has to reach it before the user starts typing.
    if (mounted) setState(() => _summons++);
    _notifier.clear();
    _exit.value = 0.0;
    _enter.value = 0.0;
    _enter.animateWith(SpringSimulation(
      SpringDescription(
          mass: 1.0,
          stiffness: 420.0,
          damping: 2 * 0.86 * math.sqrt(420.0)),
      0.0,
      1.0,
      0.0,
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
    await SchedulerBinding.instance.endOfFrame;
    await SchedulerBinding.instance.endOfFrame;
  }

  bool _keyHandler(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _dismiss();
      return true;
    }
    return false;
  }

  void _onSubmit(String cleanTitle, ParseResult result) {
    // The DB write lives in the MAIN isolate (one engine, one DB). Ship the
    // parsed fields; main reconstructs ParseResult and creates + refreshes.
    _channel.invokeMethod('capture', <String, dynamic>{
      'cleanTitle': cleanTitle,
      'startTime': result.startTime,
      'endTime': result.endTime,
      'priority': result.priority,
      'tags': result.tags,
      'dateKind': result.dateKind,
      'dateA': result.dateA,
      'dateB': result.dateB,
      'dateC': result.dateC,
    });
    // Shift+Enter keeps the pill for a rapid dump; the widget already cleared
    // + refocused. Plain Enter: let the submit pulse read, then dissolve.
    if (HardwareKeyboard.instance.isShiftPressed) {
      if (!_shiftEnterUsed) setState(() => _shiftEnterUsed = true); // learned
      return;
    }
    Future.delayed(const Duration(milliseconds: 140), _dismiss);
  }

  Future<void> _dismiss() async {
    if (_leaving) return;
    _leaving = true;
    _enter.stop();
    await _exit.animateTo(1.0, curve: Curves.easeInCubic);
    await _channel.invokeMethod('dismiss'); // runner hides the window
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _dismiss,
      child: Stack(
        children: [
          // Paints nothing anyone can see; it exists so the engine keeps
          // presenting frames during _warmup (see above).
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _warm,
              builder: (context, _) => ColoredBox(
                color: Colors.black.withValues(alpha: 0.002 * _warm.value),
              ),
            ),
          ),
          // Whisper scrim over the desktop — focuses the eye on the pill, fades
          // with the entrance/exit. Same weight as before.
          Positioned.fill(
            child: AnimatedBuilder(
              animation: Listenable.merge([_enter, _exit]),
              builder: (context, _) {
                final tc = _enter.value.clamp(0.0, 1.0);
                return ColoredBox(
                  color: Colors.black
                      .withValues(alpha: 0.10 * tc * (1.0 - _exit.value)),
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
                          filterQuality: moving ? FilterQuality.low : null,
                          child: child,
                        );
                        return Transform.translate(
                          offset: Offset(0, (1 - tc) * 10 + ex * 6),
                          child: Opacity(
                            opacity: ((tc / 0.35).clamp(0.0, 1.0) * (1.0 - ex))
                                .clamp(0.0, 1.0),
                            child: scaled,
                          ),
                        );
                      },
                      child: SmartDayInputWidget(
                        core: _core,
                        focusNode: _focusNode,
                        notifier: _notifier,
                        floating: true,
                        opaqueBackdrop: true,
                        showRapidHint: _showRapidHint,
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
    );
  }
}
