import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/engine/quick_capture_controller.dart';
import '../../core/engine/spatial_zoom_engine.dart';
import '../../core/state/first_run.dart';
import '../../core/theme/app_theme.dart';
import '../widgets/graphite_stroke.dart';
import '../widgets/paper_grain.dart';

/// First-run welcome — one choreographed timeline, not a stack of delays.
/// A single master controller staggers title (rise + tracking-in), stroke,
/// subtitle, keycaps (assemble with a soft overshoot) and the press-demo loop
/// that "plays" the real chord every few seconds. The user's first capture
/// flips the scene into the confirm moment; Esc/click hides it for the
/// session. Teaches ONE thing: the hotkey.
class WelcomeOverlay extends StatefulWidget {
  final VoidCallback onGone;
  const WelcomeOverlay({super.key, required this.onGone});

  @override
  State<WelcomeOverlay> createState() => _WelcomeOverlayState();
}

class _WelcomeOverlayState extends State<WelcomeOverlay>
    with TickerProviderStateMixin {
  /// Master timeline, forward once. All greeting stages are Intervals on it.
  static const _timelineMs = 3400;
  late final AnimationController _master;

  /// Chord-press demo: loops while the greeting is up.
  late final AnimationController _press;

  /// Scene exit: fade + a barely-there scale-up — "the camera lifts".
  late final AnimationController _exit;

  bool _confirming = false;
  bool _leaving = false;
  Timer? _confirmTimer;
  Timer? _pressStart;

  @override
  void initState() {
    super.initState();
    StaircaseState.isWelcoming = true;
    _master = AnimationController(
        vsync: this, duration: const Duration(milliseconds: _timelineMs))
      ..forward();
    _press = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 3500));
    // The press demo enters only after the caps have assembled.
    _pressStart = Timer(const Duration(milliseconds: 2400), () {
      if (mounted && !_leaving) _press.repeat();
    });
    _exit = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 450));
    FirstRunController.instance.firstLanding.addListener(_onFirstCapture);
    HardwareKeyboard.instance.addHandler(_keyHandler);
  }

  @override
  void dispose() {
    _confirmTimer?.cancel();
    _pressStart?.cancel();
    FirstRunController.instance.firstLanding.removeListener(_onFirstCapture);
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    StaircaseState.isWelcoming = false;
    _master.dispose();
    _press.dispose();
    _exit.dispose();
    super.dispose();
  }

  void _onFirstCapture() {
    if (!mounted || _leaving) return;
    _press.stop();
    setState(() => _confirming = true);
    _confirmTimer = Timer(const Duration(milliseconds: 3000), _dismiss);
  }

  /// Esc only. Any-key would eat the Alt of the very chord we're teaching,
  /// and the capture scene claims Esc globally while IT is up — no conflict.
  bool _keyHandler(KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      _dismiss();
      return true;
    }
    return false;
  }

  void _dismiss() {
    if (_leaving || !mounted) return;
    setState(() => _leaving = true);
    // Handlers off NOW — the fade-out must not swallow keys or clicks.
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    StaircaseState.isWelcoming = false;
    _pressStart?.cancel();
    _press.stop();
    _exit.forward().whenComplete(() {
      if (mounted) widget.onGone();
    });
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: _leaving,
      child: AnimatedBuilder(
        animation: _exit,
        builder: (context, child) {
          final ex = Curves.easeInOutCubic.transform(_exit.value);
          return Opacity(
            opacity: 1.0 - ex,
            child: Transform.scale(
              scale: 1.0 + 0.015 * ex,
              filterQuality: _exit.isAnimating ? FilterQuality.low : null,
              child: child,
            ),
          );
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _dismiss, // a click is explicit intent — never trap the user
          child: Container(
            color: AppTheme.background.withValues(alpha: 0.955),
            child: PaperGrain(
              child: Stack(
                children: [
                  Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 340),
                      switchInCurve: Curves.easeOut,
                      switchOutCurve: Curves.easeIn,
                      child: _confirming
                          ? _ConfirmMoment(
                              key: const ValueKey('confirm'),
                              label: FirstRunController
                                      .instance.firstLanding.value ??
                                  'its place',
                            )
                          : _GreetingMoment(
                              key: const ValueKey('greeting'),
                              master: _master,
                              press: _press,
                            ),
                    ),
                  ),
                  if (!_confirming)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 26,
                      child: _Staged(
                        master: _master,
                        startMs: 3100,
                        endMs: 3400,
                        rise: 6,
                        child: Text(
                          'Esc — look around first',
                          textAlign: TextAlign.center,
                          style: AppFonts.inter(
                            fontSize: 11,
                            color: Colors.white.withValues(alpha: 0.20),
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GREETING — the choreographed page
// ─────────────────────────────────────────────────────────────────────────────
class _GreetingMoment extends StatelessWidget {
  final AnimationController master;
  final AnimationController press;
  const _GreetingMoment({super.key, required this.master, required this.press});

  @override
  Widget build(BuildContext context) {
    // Every chord taken by other apps → teach the one key that DOES work
    // instead of a chord that does nothing. Honest beats aspirational.
    final active = QuickCaptureController.instance.hotkeyActive;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Title: rise + fade + TRACKING-IN (letter-spacing settles wide→tight,
        // the After-Effects signature that makes type feel set, not shown).
        AnimatedBuilder(
          animation: master,
          builder: (context, _) {
            final t = _seg(master.value, 100, 800);
            final track = _seg(master.value, 100, 900);
            return Opacity(
              opacity: Curves.easeOutCubic.transform(t),
              child: Transform.translate(
                offset: Offset(
                    0, 18 * (1 - Curves.easeOutQuint.transform(t))),
                child: Text(
                  'Welcome to Slate.',
                  style: AppTheme.welcomeSerif.copyWith(
                    letterSpacing:
                        1.2 - 1.6 * Curves.easeOutQuint.transform(track),
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        _Staged(
          master: master,
          startMs: 900,
          endMs: 1500,
          rise: 8,
          child: Text(
            'The place to breathe out whatever’s on your mind.',
            style: AppTheme.welcomeSerifSub,
          ),
        ),
        const SizedBox(height: 16),
        GraphiteStroke(
          width: 280,
          height: 18,
          seed: 7,
          delay: const Duration(milliseconds: 500),
        ),
        const SizedBox(height: 54),
        if (!active)
          _Staged(
            master: master,
            startMs: 1500,
            endMs: 2100,
            rise: 8,
            child: Text(
              'The global capture chord is held by another app right now.',
              style: AppFonts.inter(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.32),
              ),
            ),
          ),
        if (!active) const SizedBox(height: 18),
        _HotkeyRow(
          label: active ? QuickCaptureController.instance.hotkeyLabel : 'C',
          master: master,
          press: press,
        ),
        const SizedBox(height: 18),
        _Staged(
          master: master,
          startMs: 2300,
          endMs: 2900,
          rise: 8,
          child: Text(
            active
                ? 'Press it — anywhere, anytime. Even over other apps.'
                : 'Press C inside Slate — capture works all the same.',
            style: AppTheme.bodyLarge.copyWith(
              color: AppTheme.textSecondary,
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }
}

/// Progress of a [startMs, endMs] stage on the master timeline, 0..1.
double _seg(double master, int startMs, int endMs) {
  const total = _WelcomeOverlayState._timelineMs;
  final s = startMs / total, e = endMs / total;
  return ((master - s) / (e - s)).clamp(0.0, 1.0);
}

/// Fade + rise stage bound to the master timeline.
class _Staged extends StatelessWidget {
  final AnimationController master;
  final int startMs;
  final int endMs;
  final double rise;
  final Widget child;
  const _Staged(
      {required this.master,
      required this.startMs,
      required this.endMs,
      this.rise = 8,
      required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: master,
      child: child,
      builder: (context, c) {
        final t = _seg(master.value, startMs, endMs);
        return Opacity(
          opacity: Curves.easeOut.transform(t),
          child: Transform.translate(
            offset: Offset(0, rise * (1 - Curves.easeOutQuint.transform(t))),
            child: c,
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CONFIRM — the first capture landed
// ─────────────────────────────────────────────────────────────────────────────
class _ConfirmMoment extends StatefulWidget {
  final String label;
  const _ConfirmMoment({super.key, required this.label});

  @override
  State<_ConfirmMoment> createState() => _ConfirmMomentState();
}

class _ConfirmMomentState extends State<_ConfirmMoment>
    with SingleTickerProviderStateMixin {
  late final AnimationController _in;

  @override
  void initState() {
    super.initState();
    _in = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..forward();
  }

  @override
  void dispose() {
    _in.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const GraphiteStroke(
          width: 44,
          height: 44,
          mode: GraphiteStrokeMode.check,
          strokeWidth: 2.8,
          color: AppTheme.honey,
          delay: Duration(milliseconds: 150),
        ),
        const SizedBox(height: 22),
        AnimatedBuilder(
          animation: _in,
          builder: (context, _) {
            final t = Curves.easeOutQuint.transform(
                ((_in.value - 0.15) / 0.65).clamp(0.0, 1.0));
            return Opacity(
              opacity: t,
              child: Transform.translate(
                offset: Offset(0, 12 * (1 - t)),
                child: Text(
                  'There — tucked into ${widget.label}.',
                  style: AppTheme.welcomeSerif.copyWith(
                    fontSize: 26,
                    letterSpacing: 0.8 - 1.2 * t,
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 10),
        AnimatedBuilder(
          animation: _in,
          builder: (context, _) => Opacity(
            opacity: ((_in.value - 0.55) / 0.45).clamp(0.0, 1.0),
            child: Text(
              'That’s the whole move. Slate keeps it from here.',
              style: AppTheme.welcomeSerifSub,
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// KEYCAPS — assemble on the timeline, then "play" the chord in a gentle loop
// ─────────────────────────────────────────────────────────────────────────────
class _HotkeyRow extends StatelessWidget {
  final String label;
  final AnimationController master;
  final AnimationController press;
  const _HotkeyRow(
      {required this.label, required this.master, required this.press});

  /// 0..1 press depth of cap [i] within one demo loop: quick dip, short hold,
  /// springy release. Caps land 60ms apart — a hand pressing a chord.
  static double _pressDepth(double t, int i) {
    final start = 0.12 + i * 0.018;
    const down = 0.035, hold = 0.055, up = 0.10;
    final local = t - start;
    if (local <= 0 || local >= down + hold + up) return 0;
    if (local < down) return Curves.easeOutCubic.transform(local / down);
    if (local < down + hold) return 1;
    return 1 - Curves.easeOutBack.transform((local - down - hold) / up);
  }

  @override
  Widget build(BuildContext context) {
    final keys = label.split('+');
    return AnimatedBuilder(
      animation: Listenable.merge([master, press]),
      builder: (context, _) {
        var maxDepth = 0.0;
        final caps = <Widget>[];
        for (var i = 0; i < keys.length; i++) {
          final enter = Curves.easeOut
              .transform(_seg(master.value, 1600 + 90 * i, 2200 + 90 * i));
          final depth =
              press.isAnimating ? _pressDepth(press.value, i) : 0.0;
          if (depth > maxDepth) maxDepth = depth;
          if (i > 0) {
            caps.add(Padding(
              padding: const EdgeInsets.symmetric(horizontal: 9),
              child: Opacity(
                opacity: enter * 0.25,
                child: Text('+',
                    style: AppFonts.inter(fontSize: 15, color: Colors.white)),
              ),
            ));
          }
          caps.add(Opacity(
            opacity: enter,
            child: Transform.translate(
              offset: Offset(0, 1.5 * depth),
              child: Transform.scale(
                // Assemble with a soft overshoot; the press dips it back down.
                scale: (0.90 + 0.10 * Curves.easeOutBack.transform(enter)) *
                    (1.0 - 0.06 * depth),
                filterQuality: (enter < 1.0 || depth > 0.0)
                    ? FilterQuality.low
                    : null,
                child: _KeyCap(text: keys[i], pressDepth: depth),
              ),
            ),
          ));
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            // The honey bloom under the chord while it "plays".
            boxShadow: maxDepth > 0
                ? [
                    BoxShadow(
                      color:
                          AppTheme.honey.withValues(alpha: 0.14 * maxDepth),
                      blurRadius: 34,
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: caps),
        );
      },
    );
  }
}

class _KeyCap extends StatelessWidget {
  final String text;
  final double pressDepth;
  const _KeyCap({required this.text, this.pressDepth = 0});

  @override
  Widget build(BuildContext context) {
    final d = pressDepth;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: Color.lerp(
          Colors.white.withValues(alpha: 0.055),
          AppTheme.honey.withValues(alpha: 0.12),
          d,
        ),
        border: Border.all(
          color: Color.lerp(
            Colors.white.withValues(alpha: 0.14),
            AppTheme.honey.withValues(alpha: 0.45),
            d,
          )!,
          width: 0.5,
        ),
        boxShadow: [
          // The cap sits on the page; pressing it flattens the shadow.
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35 * (1 - 0.5 * d)),
            blurRadius: 10 - 4 * d,
            offset: Offset(0, 4 - 2 * d),
          ),
        ],
      ),
      child: Text(
        text,
        style: AppFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Color.lerp(
            Colors.white.withValues(alpha: 0.82),
            AppTheme.honey.withValues(alpha: 0.95),
            d * 0.6,
          ),
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
