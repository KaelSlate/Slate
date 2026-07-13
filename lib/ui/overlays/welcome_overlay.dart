import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../../core/engine/quick_capture_controller.dart';
import '../../core/engine/spatial_zoom_engine.dart';
import '../../core/state/first_run.dart';
import '../../core/theme/app_theme.dart';
import '../widgets/graphite_stroke.dart';
import '../widgets/paper_grain.dart';

/// First-run welcome. Teaches ONE thing — the real capture hotkey — then gets
/// out of the way. The user's first capture (hotkey pill, day pill or inbox)
/// flips it into the confirm moment ("tucked into …") and it dissolves forever.
/// Esc / click just hides it for this session: it returns next launch until
/// that first capture actually happens.
class WelcomeOverlay extends StatefulWidget {
  final VoidCallback onGone;
  const WelcomeOverlay({super.key, required this.onGone});

  @override
  State<WelcomeOverlay> createState() => _WelcomeOverlayState();
}

class _WelcomeOverlayState extends State<WelcomeOverlay> {
  bool _confirming = false;
  bool _leaving = false;
  Timer? _confirmTimer;

  @override
  void initState() {
    super.initState();
    StaircaseState.isWelcoming = true;
    FirstRunController.instance.firstLanding.addListener(_onFirstCapture);
    HardwareKeyboard.instance.addHandler(_keyHandler);
  }

  @override
  void dispose() {
    _confirmTimer?.cancel();
    FirstRunController.instance.firstLanding.removeListener(_onFirstCapture);
    HardwareKeyboard.instance.removeHandler(_keyHandler);
    StaircaseState.isWelcoming = false;
    super.dispose();
  }

  void _onFirstCapture() {
    if (!mounted || _leaving) return;
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
    Future.delayed(const Duration(milliseconds: 340), () {
      if (mounted) widget.onGone();
    });
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: _leaving,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
        opacity: _leaving ? 0.0 : 1.0,
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
                          : const _GreetingMoment(key: ValueKey('greeting')),
                    ),
                  ),
                  if (!_confirming)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 26,
                      child: Text(
                        'Esc — look around first',
                        textAlign: TextAlign.center,
                        style: AppFonts.inter(
                          fontSize: 11,
                          color: Colors.white.withValues(alpha: 0.20),
                          letterSpacing: 0.3,
                        ),
                      )
                          .animate()
                          .fadeIn(delay: 2200.ms, duration: 700.ms),
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

class _GreetingMoment extends StatelessWidget {
  const _GreetingMoment({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Welcome to Slate.', style: AppTheme.welcomeSerif)
            .animate()
            .fadeIn(duration: 600.ms, curve: Curves.easeOut)
            .slideY(begin: 0.12, duration: 700.ms, curve: Curves.easeOutCubic),
        const SizedBox(height: 10),
        Text(
          'The place to breathe out whatever’s on your mind.',
          style: AppTheme.welcomeSerifSub,
        ).animate().fadeIn(delay: 600.ms, duration: 600.ms),
        const SizedBox(height: 16),
        GraphiteStroke(
          width: 280,
          height: 18,
          seed: 7,
          delay: const Duration(milliseconds: 1000),
        ),
        const SizedBox(height: 54),
        _HotkeyRow(label: QuickCaptureController.instance.hotkeyLabel)
            .animate()
            .fadeIn(delay: 1300.ms, duration: 600.ms)
            .slideY(begin: 0.10, delay: 1300.ms, duration: 600.ms,
                curve: Curves.easeOutCubic),
        const SizedBox(height: 18),
        Text(
          'Press it — anywhere, anytime. Even over other apps.',
          style: AppTheme.bodyLarge.copyWith(
            color: AppTheme.textSecondary,
            fontSize: 14,
          ),
        ).animate().fadeIn(delay: 1700.ms, duration: 600.ms),
      ],
    );
  }
}

class _ConfirmMoment extends StatelessWidget {
  final String label;
  const _ConfirmMoment({super.key, required this.label});

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
        Text('There — tucked into $label.',
            style: AppTheme.welcomeSerif.copyWith(fontSize: 26)),
        const SizedBox(height: 10),
        Text(
          'That’s the whole move. Slate keeps it from here.',
          style: AppTheme.welcomeSerifSub,
        ).animate().fadeIn(delay: 500.ms, duration: 600.ms),
      ],
    );
  }
}

/// The real registered chord as keycaps — never a hardcoded "Alt+Space".
class _HotkeyRow extends StatelessWidget {
  final String label;
  const _HotkeyRow({required this.label});

  @override
  Widget build(BuildContext context) {
    final keys = label.split('+');
    final children = <Widget>[];
    for (var i = 0; i < keys.length; i++) {
      if (i > 0) {
        children.add(Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: Text('+',
              style: AppFonts.inter(
                fontSize: 15,
                color: Colors.white.withValues(alpha: 0.25),
              )),
        ));
      }
      children.add(_KeyCap(text: keys[i]));
    }
    return Row(mainAxisSize: MainAxisSize.min, children: children);
  }
}

class _KeyCap extends StatelessWidget {
  final String text;
  const _KeyCap({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(9),
        color: Colors.white.withValues(alpha: 0.055),
        border: Border.all(
            color: Colors.white.withValues(alpha: 0.14), width: 0.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        text,
        style: AppFonts.inter(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: Colors.white.withValues(alpha: 0.82),
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}
