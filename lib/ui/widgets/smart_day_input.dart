import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/engine/slate_core_bridge.dart';
import '../../core/sfx/sfx.dart';
import '../../core/theme/app_theme.dart';

// ═══════════════════════════════════════════════════════════════════════════
// SMART INPUT NOTIFIER
// ═══════════════════════════════════════════════════════════════════════════

class SmartInputNotifier extends ChangeNotifier {
  ParseResult _result = const ParseResult();
  ParseResult get result => _result;

  /// How many times this input was reset for a fresh capture — drives the
  /// teaching-placeholder rotation (see [captureHints]).
  int reveals = 0;

  void update(ParseResult r) {
    _result = r;
    notifyListeners();
  }

  void clear() {
    _result = const ParseResult();
    reveals++;
    notifyListeners();
  }
}

/// The placeholder is the syntax teacher. Nothing in the UI ever explains
/// that «gym at 6pm #health !!» just works — a tooltip would be noise and a
/// tour would be worse. So the ghost text you are about to type over IS the
/// lesson: each reveal shows one real capture the parser fully understands.
/// Index 0 stays the calm classic for the very first contact.
/// Every example here MUST parse completely — an unparseable hint is a lie.
const captureHints = [
  'Type a task…',
  'Call mom tomorrow 15:00',
  'Gym at 6pm #health',
  'Ship the draft fri !!',
  'Plan the week 9-10am',
];

String captureHintFor(int reveals) {
  if (reveals <= 0) return captureHints[0];
  final teach = captureHints.length - 1;
  return captureHints[1 + (reveals - 1) % teach];
}

// ═══════════════════════════════════════════════════════════════════════════
// CUSTOM CONTROLLER FOR INLINE CHIPS
// ═══════════════════════════════════════════════════════════════════════════

class SmartInputController extends TextEditingController {
  ParseResult _result = const ParseResult();
  
  void updateResult(ParseResult result) {
    if (_result == result) return;
    _result = result;
    notifyListeners();
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final base = style ?? const TextStyle();
    if (text.isEmpty) return TextSpan(text: text, style: base);

    // SUBTLE INLINE SYNTAX HIGHLIGHTING ONLY.
    // Recognized tokens (time phrase / priority "!"/"!!" / "#tag") are TINTED in
    // place — no chips, no boxes, no widget spans, no duplicated/zero-width text.
    // Every character of `text` is rendered exactly once with its natural advance,
    // so the caret and text selection behave like a perfectly ordinary field
    // (the old WidgetSpan chips broke both, and looked like "ugly squares").
    final cleanWords = _result.cleanTitle.toLowerCase().split(RegExp(r'\s+'));
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'(\s+)');
    final parts = text.split(pattern);              // word pieces (spaces dropped)
    final spaces = pattern.allMatches(text).toList(); // the whitespace runs

    for (int i = 0; i < parts.length; i++) {
      final part = parts[i];
      if (part.isNotEmpty) {
        final tint = _tokenTint(part, cleanWords);
        spans.add(TextSpan(
          text: part,
          style: tint == null
              ? base
              : base.copyWith(color: tint, fontWeight: FontWeight.w600),
        ));
      }
      if (i < spaces.length) {
        spans.add(TextSpan(text: spaces[i].group(0), style: base));
      }
    }
    return TextSpan(children: spans);
  }

  /// The calm tint color for a recognized token, or null for ordinary words.
  Color? _tokenTint(String part, List<String> cleanWords) {
    if ((part.startsWith('#') || part.startsWith('№')) &&
        _result.tags.contains(part.substring(1))) {
      return AppTheme.tagColor;
    }
    if ((part == '!' || part == '!!') && _result.hasPriority) {
      return _priorityColor(_result.priority);
    }
    if ((_result.hasTime || _result.hasDate) &&
        !cleanWords.contains(part.toLowerCase()) &&
        !part.startsWith('#') &&
        !part.startsWith('№') &&
        part != '!' &&
        part != '!!') {
      return AppTheme.priorityNormal; // calm blue for the parsed time/date phrase
    }
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SMART DAY INPUT WIDGET
// ═══════════════════════════════════════════════════════════════════════════

/// True only when the renderer supports `ImageFilter.shader` inside a
/// `BackdropFilter` — i.e. Impeller. On Skia/Windows (today) this is `false`,
/// so the glass uses directional specular instead of real backdrop refraction.
/// When Impeller-Windows ships this flips `true` automatically and the gated
/// branch in `_glassBackdropFilter()` activates real edge refraction (#5) +
/// chromatic aberration (#6). See `slate_vision` → "WHEN STABLE IMPELLER-WINDOWS".
final bool kGlassRefractionSupported = ImageFilter.isShaderFilterSupported;

class SmartDayInputWidget extends StatefulWidget {
  final SlateCore core;
  final FocusNode focusNode;
  final SmartInputNotifier notifier;
  final void Function(String cleanTitle, ParseResult result) onSubmit;
  final VoidCallback onDismiss;
  /// Global quick-capture mode: the overlay scene owns entrance/exit (the pill
  /// mounts settled), Shift+Enter dumps rapidly, destination label always shown.
  final bool floating;

  /// No backdrop worth sampling — paint [AppTheme.glassOpaqueBody] instead of a
  /// BackdropFilter. True ONLY when the pill floats over other apps' windows:
  /// Flutter cannot read their pixels, so a blur would sample emptiness.
  /// Orthogonal to [floating] — the in-app Alt+Space pill floats over Slate's
  /// OWN canvas, and there the lens is real.
  final bool opaqueBackdrop;

  /// Whisper the rapid-dump chord beside the destination chip. Owned by the
  /// caller: the pill window is its own Flutter engine with no prefs and no
  /// engine, so it tracks this itself rather than reading a first-run flag that
  /// only ever exists in the MAIN isolate. (It used to read exactly such a flag
  /// — which is why this whisper could never appear at all.)
  final bool showRapidHint;

  /// Resolved destination for the current parse («Inbox», «Tomorrow 09:00»).
  /// The chip is ALWAYS shown once there's text — it is the teacher of the one
  /// routing rule, so the user always sees where the task lands before Enter.
  final String Function(ParseResult result)? destinationLabel;

  /// Targeted mode: the pill is pinned to a specific day (day-view `C`/«+»,
  /// mouse-«+»). Parsing runs in targeted mode (a typed date stays as title
  /// text, never re-routes), and a faint whisper appears if a date is detected.
  final bool targeted;

  const SmartDayInputWidget({
    super.key,
    required this.core,
    required this.focusNode,
    required this.notifier,
    required this.onSubmit,
    required this.onDismiss,
    this.floating = false,
    this.opaqueBackdrop = false,
    this.showRapidHint = false,
    this.destinationLabel,
    this.targeted = false,
  });

  @override
  State<SmartDayInputWidget> createState() => _SmartDayInputWidgetState();
}

class _SmartDayInputWidgetState extends State<SmartDayInputWidget>
    with TickerProviderStateMixin {
  late final SmartInputController _controller;
  ParseResult _lastResult = const ParseResult();
  bool _isFocused = false;
  bool _isDismissing = false;
  /// Targeted pill only: a calendar date was typed but is being kept as text
  /// (the pinned day wins). Drives the faint "date stays here" whisper.
  bool _dateIgnored = false;

  late final AnimationController _appearController;
  late final AnimationController _submitAnim;
  late final AnimationController _focusController;

  /// Last [SmartInputNotifier.reveals] this field acted on — see _onNotifier.
  int _seenReveals = 0;


  @override
  void initState() {
    super.initState();
    _controller = SmartInputController();
    _controller.addListener(_onTextChanged);
    _seenReveals = widget.notifier.reveals;
    widget.notifier.addListener(_onNotifier);

    _appearController = AnimationController(
      vsync: this,
      lowerBound: 0.0,
      upperBound: 1.2, // headroom for the spring's overshoot
    );
    _submitAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _focusController = AnimationController(
      vsync: this,
      duration: AppTheme.glassFocusRingDuration,
    );

    widget.focusNode.addListener(_onFocusChange);

    if (widget.floating) {
      // The overlay scene owns the entrance — pill mounts settled.
      _appearController.value = 1.0;
      // Shift+Enter = rapid dump. Intercept ON the focus node, synchronously
      // with the key event: a single-line TextField doesn't reliably fire
      // onSubmitted for Shift+Enter, and checking the modifier later races
      // the Shift release. The overlay reads isShiftPressed inside onSubmit —
      // still true here because this call is synchronous.
      widget.focusNode.onKeyEvent = (node, event) {
        final isEnter = event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter;
        if (event is KeyDownEvent &&
            isEnter &&
            HardwareKeyboard.instance.isShiftPressed) {
          _submit();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      };
    } else {
      _appearController.animateWith(SpringSimulation(
        SpringDescription(
          mass: 1.0,
          stiffness: AppTheme.glassSpringAppearStiffness,
          damping: AppTheme.glassSpringAppearDamping *
              2 *
              math.sqrt(AppTheme.glassSpringAppearStiffness),
        ),
        0.0,
        1.0,
        0.0,
      ));
      // The in-app pills (day view, overview) are BUILT on each open, so the
      // entrance sound belongs with the entrance spring right here. The
      // floating one is a different story: it lives in the pill window and is
      // mounted once for the whole process, so its summon sound is played by
      // pill_window.dart's _reveal instead. Sfx.armed keeps the warmup pass —
      // which also mounts one of these under the veil — silent.
      Sfx.pillAppear();
    }

    // Acquire keyboard focus the instant the pill mounts so the caret blinks and
    // typing works immediately — no click, no alt+tab. (#7)
    WidgetsBinding.instance.addPostFrameCallback((_) => _acquireFocus());
  }

  /// Reliably grabs focus + opens the native text-input connection on open.
  /// We request once on the first post-frame (field is in the tree), then
  /// re-assert a frame later: on Windows the first request can land before the
  /// engine's input client is ready, which left the caret not blinking until the
  /// user alt+tabbed or clicked. The second request forces the connection open.
  void _acquireFocus() {
    if (!mounted) return;
    widget.focusNode.requestFocus();
    Future.delayed(const Duration(milliseconds: 60), () {
      if (mounted && !widget.focusNode.hasPrimaryFocus) {
        widget.focusNode.requestFocus();
      }
    });
  }

  /// The backdrop filter behind the glass. ONE gated insertion point for real
  /// refraction so the Impeller upgrade is a one-line flip, no rewrite.
  ImageFilter _glassBackdropFilter() {
    if (kGlassRefractionSupported) {
      // ── IMPELLER (future) ─────────────────────────────────────────────────
      // When Impeller-Windows ships, author shaders/liquid_refract.frag
      // (edge displacement #5 + chromatic aberration #6) and return:
      //   ImageFilter.compose(
      //     outer: ColorFilter.matrix(AppTheme.glassSaturationMatrix),
      //     inner: ImageFilter.shader(_refractShader),  // real lensing
      //   );
      // Shader not authored yet (can't run/test on Skia) — see slate_vision.
      // Until then we deliberately fall through to the calibrated blur path.
    }
    // ── SKIA (today): light blur + vibrancy. The 3D edge is the directional
    //    specular painted by LiquidGlassPainter, not a backdrop displacement.
    return ImageFilter.compose(
      outer: ColorFilter.matrix(AppTheme.glassSaturationMatrix),
      inner: ImageFilter.blur(
        sigmaX: AppTheme.glassBlurL3See,
        sigmaY: AppTheme.glassBlurL3See,
      ),
    );
  }

  void _onFocusChange() {
    final focused = widget.focusNode.hasFocus;
    if (_isFocused == focused) return;
    setState(() => _isFocused = focused);
    if (focused) {
      _focusController.animateTo(1.0,
          duration: AppTheme.glassFocusRingDuration, curve: Curves.easeOut);
    } else {
      _focusController.animateTo(0.0,
          duration: AppTheme.glassFocusRingDuration, curve: Curves.easeIn);
    }
  }

  void _onTextChanged() {
    final raw = _controller.text;

    if (raw.isEmpty) {
      final cleared = const ParseResult();
      if (_lastResult != cleared) {
        setState(() => _lastResult = cleared);
        _controller.updateResult(cleared);
        widget.notifier.update(cleared);
      }
      if (_dateIgnored) setState(() => _dateIgnored = false);
      return;
    }
    final result = widget.core.parseInput(raw, targeted: widget.targeted);
    // Targeted pill: a typed date is kept as text (pinned day wins). Detect it
    // via a plain parse so we can whisper that it stayed put — never silent.
    if (widget.targeted) {
      final wouldHaveDate = widget.core.parseInput(raw).dateKind != 0;
      if (wouldHaveDate != _dateIgnored) {
        setState(() => _dateIgnored = wouldHaveDate);
      }
    }
    if (result.cleanTitle != _lastResult.cleanTitle ||
        result.startTime != _lastResult.startTime ||
        result.endTime != _lastResult.endTime ||
        result.priority != _lastResult.priority ||
        // Compare tag CONTENTS, not just the count — typing more letters into a
        // tag keeps the count at 1 and the cleanTitle unchanged, so a length-only
        // check skipped the update and only the first letter ever highlighted (#8).
        !listEquals(result.tags, _lastResult.tags)) {
      setState(() => _lastResult = result);
      _controller.updateResult(result);
      widget.notifier.update(result);
    }
  }

  Future<void> _dismiss() async {
    if (_isDismissing) return;
    _isDismissing = true;
    if (widget.floating) {
      // Exit animation belongs to the overlay scene.
      widget.onDismiss();
      return;
    }
    // ONE exit for every pill: the same quick easeInCubic settle-down the global
    // pill window uses (pill_window `_exit`), so the day/overview pill closes
    // with the identical gesture — not the old dismiss spring.
    await _appearController.animateTo(
      0.0,
      duration: AppTheme.glassDismissDuration,
      curve: Curves.easeInCubic,
    );
    if (mounted) widget.onDismiss();
  }

  void _submit() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      _dismiss();
      return;
    }

    // Calm confirmation: a soft haptic + a gentle pill pulse (_submitAnim). The
    // real confirmation is the task itself flowing into place — it materializes in
    // the left list, or onto the timeline if it has a time. No glowing particle bar
    // shooting out of the pill anymore (#14).
    HapticFeedback.lightImpact();
    _submitAnim.forward(from: 0);

    final result = widget.core.parseInput(raw, targeted: widget.targeted);
    widget.onSubmit(
        result.cleanTitle.isEmpty ? raw : result.cleanTitle, result);

    _controller.clear();
    _dateIgnored = false;
    setState(() => _lastResult = const ParseResult());
    _controller.updateResult(const ParseResult());
    widget.notifier.clear();

    // Keep the field focused for rapid multi-entry — Enter (textInputAction.done)
    // drops focus, which stopped the caret blinking until a click (#2). Re-assert
    // on the next frame so it's ready for the next task immediately.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.focusNode.requestFocus();
    });
  }

  /// [SmartInputNotifier.clear] means "reset for a fresh capture", and the
  /// field has to obey it — otherwise text typed but never submitted survives
  /// the pill being dismissed and greets the user on the next summon, on top
  /// of the placeholder that is supposed to be teaching them the syntax.
  /// Submit already clears the text itself, so this is a no-op there.
  void _onNotifier() {
    if (widget.notifier.reveals == _seenReveals) return;
    _seenReveals = widget.notifier.reveals;
    if (_controller.text.isEmpty) return;
    _controller.clear();
    _controller.updateResult(const ParseResult());
    _dateIgnored = false;
    if (mounted) setState(() => _lastResult = const ParseResult());
  }

  @override
  void dispose() {
    if (widget.floating) widget.focusNode.onKeyEvent = null;
    widget.notifier.removeListener(_onNotifier);
    widget.focusNode.removeListener(_onFocusChange);
    _controller.dispose();
    _appearController.dispose();
    _submitAnim.dispose();
    _focusController.dispose();
    super.dispose();
  }

  Color get _spillColor {
    if (_lastResult.hasPriority) {
      return _lastResult.priority >= 2
          ? AppTheme.priorityCritical
          : AppTheme.priorityHigh;
    }
    if (_lastResult.hasTags) return AppTheme.tagColor;
    return Colors.white;
  }

  double get _spillOpacity {
    if (_lastResult.hasPriority || _lastResult.hasTags) {
      return AppTheme.glassSpillOpacityActive;
    }
    return AppTheme.glassSpillOpacityIdle;
  }

  double get _targetRadius =>
      _lastResult.cleanTitle.isEmpty
          ? AppTheme.glassRadiusIdle
          : AppTheme.glassRadiusActive;

  /// Everything inside the glass: rim light, sheen, input row. The
  /// RepaintBoundary is LOAD-BEARING — it isolates the cursor blink from the
  /// BackdropFilter / rim raster (see the flicker note at the call site).
  Widget _pillBody(double radius) {
    return RepaintBoundary(
      child: CustomPaint(
        foregroundPainter: LiquidGlassPainter(
          radius: radius,
          focusRingOpacity: _focusController.value,
        ),
        child: DecoratedBox(
          // NO center blob, NO dark tint (that murked the glass). Just a
          // whisper-faint top sheen for body + text legibility.
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.white.withOpacity(0.030),
                Colors.white.withOpacity(0.0),
              ],
              stops: const [0.0, 0.6],
            ),
          ),
          child: AnimatedContainer(
            duration: AppTheme.glassMorphDuration,
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: 24,
              vertical: _lastResult.cleanTitle.isEmpty ? 18 : 20,
            ),
            // Escape is handled globally (day_flow_view _globalKeyHandler /
            // quick_capture_overlay) so it works even if the field momentarily
            // loses focus. No inline KeyboardListener here — a fresh FocusNode
            // per build churned the focus tree and broke the cursor / typing.
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: widget.focusNode,
                    autofocus: true,
                    mouseCursor: SystemMouseCursors.text,
                    textInputAction: TextInputAction.done,
                    cursorColor: Colors.white,
                    cursorWidth: 1.5,
                    cursorRadius: const Radius.circular(2),
                    onSubmitted: (_) => _submit(),
                    style: AppFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      color: Colors.white,
                      letterSpacing: -0.3,
                      height: 1.3,
                    ),
                    decoration: InputDecoration(
                      hintText: captureHintFor(widget.notifier.reveals),
                      hintStyle: AppFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w400,
                        color: Colors.white.withOpacity(0.3),
                        letterSpacing: -0.3,
                      ),
                      isDense: true,
                      contentPadding: EdgeInsets.zero,
                      border: InputBorder.none,
                    ),
                  ),
                ),
                _destinationChip(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The calm right-side destination readout — ALWAYS shown once there is text.
  /// It is the teacher of the one routing rule: a leading arrow makes it read as
  /// a destination ("→ Inbox", "→ Wed · Jul 16", "→ Today 9:00"). A whisper
  /// rides alongside: the rapid-dump chord on the first-run floating pill, or
  /// "date stays here" when a targeted pill is keeping a typed date as text.
  Widget _destinationChip() {
    final show =
        widget.destinationLabel != null && _controller.text.trim().isNotEmpty;
    final label = show ? widget.destinationLabel!(_lastResult) : null;
    final String? whisper = !show
        ? null
        : (widget.targeted && _dateIgnored)
            ? 'date stays here'
            : (widget.floating && widget.showRapidHint)
                ? 'Shift+Enter — keep going'
                : null;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      child: label == null
          ? const SizedBox.shrink()
          : Padding(
              key: ValueKey('$label|$whisper'),
              padding: const EdgeInsets.only(left: 14),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Leading arrow — "this goes to →". Fainter than the label.
                  Text(
                    '→ ',
                    style: AppFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withOpacity(0.24),
                      letterSpacing: -0.1,
                    ),
                  ),
                  Text(
                    label,
                    style: AppFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withOpacity(0.42),
                      letterSpacing: -0.1,
                    ),
                  ),
                  if (whisper != null)
                    Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Text(
                        whisper,
                        style: AppFonts.inter(
                          fontSize: 10.5,
                          color: Colors.white.withOpacity(0.20),
                          letterSpacing: 0.1,
                        ),
                      ),
                    ),
                ],
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_appearController, _focusController]),
      builder: (context, _) {
        final appearVal = _appearController.value;

        // The one entrance: unfurl from the centre, wide in X, barely in Y —
        // same geometry the Alt+Space overlay uses, so both pills open alike.
        // Scale-ONLY, NO Opacity wrapper: an animating Opacity over a
        // BackdropFilter makes the filter sample an empty offscreen layer for one
        // frame — the "blink" on appear. Scaling keeps the glass opaque every
        // frame, so the blur is correct from frame one.
        final sx = AppTheme.glassSpringScaleFromX +
            (1.0 - AppTheme.glassSpringScaleFromX) * appearVal;
        final sy = AppTheme.glassSpringScaleFromY +
            (1.0 - AppTheme.glassSpringScaleFromY) * appearVal;
        final shadowFactor = appearVal.clamp(0.0, 1.0);
        // Slide-up on enter / down on exit — the SAME rise the global pill window
        // uses, so both pills share one gesture. Floating pins appearVal at 1.0,
        // so its rise is 0 here (the overlay scene owns its translate). Translate
        // is safe over the lens (only an animating Opacity blinks the backdrop).
        final rise = (1.0 - shadowFactor) * AppTheme.glassEnterRise;

        return Transform.translate(
          offset: Offset(0, rise),
          child: Transform(
            alignment: Alignment.center,
            transform: Matrix4.diagonal3Values(sx, sy, 1.0),
            // The text-hop rule wants filterQuality while a scale animates — but
            // it is the ONE place we must not obey it over a lens. filterQuality
            // makes RenderTransform push an ImageFilterLayer (a saveLayer); the
            // BackdropFilter below would then sample that empty layer for the
            // WHOLE entrance, not one frame, and the glass would come up hollow.
            // Only the opaque body (nothing to sample) may raster-stretch.
            filterQuality:
                widget.opaqueBackdrop && _appearController.isAnimating
                    ? FilterQuality.low
                    : null,
            child: ScaleTransition(
              scale: TweenSequence([
                TweenSequenceItem(
                  tween: Tween(begin: 1.0, end: 0.94)
                      .chain(CurveTween(curve: Curves.easeOutCubic)),
                  weight: 20,
                ),
                TweenSequenceItem(
                  tween: Tween(begin: 0.94, end: 1.0)
                      .chain(CurveTween(curve: Curves.elasticOut)),
                  weight: 80,
                ),
              ]).animate(_submitAnim),
              child: TweenAnimationBuilder<double>(
                tween: Tween<double>(
                  begin: AppTheme.glassRadiusIdle,
                  end: _targetRadius,
                ),
                duration: AppTheme.glassMorphDuration,
                curve: Curves.easeOutCubic,
                builder: (context, radius, _) {
                  return TweenAnimationBuilder<Color?>(
                    tween: ColorTween(
                      begin: Colors.transparent,
                      end: _spillColor.withOpacity(_spillOpacity),
                    ),
                    duration: const Duration(milliseconds: 400),
                    curve: Curves.easeOutCubic,
                    builder: (context, spillColor, _) {
                      return Stack(
                        clipBehavior: Clip.none,
                        alignment: Alignment.topCenter,
                        children: [
                          Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(radius),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.black.withOpacity(
                                      AppTheme.glassAmbientOpacity *
                                          shadowFactor),
                                  blurRadius: AppTheme.glassAmbientBlur,
                                  offset: AppTheme.glassAmbientOffset,
                                ),
                                BoxShadow(
                                  color: Colors.black.withOpacity(
                                      AppTheme.glassDirectionalOpacity *
                                          shadowFactor),
                                  blurRadius: AppTheme.glassDirectionalBlur,
                                  offset: AppTheme.glassDirectionalOffset,
                                ),
                                BoxShadow(
                                  color: spillColor ?? Colors.transparent,
                                  blurRadius: AppTheme.glassSpillBlur,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            // Clean spring entrance — no shader morph (it flashed a
                            // vertical line + shrank the blur for one frame on Skia,
                            // #6). The pill scales + fades in via _appearController.
                            child: ClipRRect(
                              // ── OUR OWN glass stack (no package) ──────────
                              // Native Skia: light backdrop blur + vibrancy
                              // (saturation) so the live timeline shows THROUGH
                              // the pill as a real lens, then a CustomPainter
                              // paints the even rim light. The RepaintBoundary is
                              // LOAD-BEARING: it isolates the text cursor's blink
                              // so it can't dirty the BackdropFilter / rim and
                              // force a re-raster every ~0.5s (that was the
                              // "edges re-light when the cursor blinks" flicker).
                              borderRadius: BorderRadius.circular(radius),
                              // Over FOREIGN windows there is nothing Flutter can
                              // blur, so the lens becomes a body. Over Slate's own
                              // canvas — day pill AND in-app Alt+Space — it is a
                              // real lens. Same rim, same sheen, same spring.
                              child: widget.opaqueBackdrop
                                  ? ColoredBox(
                                      color: AppTheme.glassOpaqueBody,
                                      child: _pillBody(radius),
                                    )
                                  : BackdropFilter(
                                      filter: _glassBackdropFilter(),
                                      child: _pillBody(radius),
                                    ),
                          ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS BORDER PAINTER
// ═══════════════════════════════════════════════════════════════════════════

class GlassBorderPainter extends CustomPainter {
  final double radius;
  final List<Color> colors;
  final List<double>? stops;
  final double strokeWidth;

  GlassBorderPainter({
    required this.radius,
    required this.colors,
    this.stops,
    this.strokeWidth = 1.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
        stops: stops,
      ).createShader(rect);

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(GlassBorderPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.colors != colors;
}

// ═══════════════════════════════════════════════════════════════════════════
// LIQUID GLASS PAINTER — Level 3 (Fresnel + Specular + Inner Shadow + Focus)
// ═══════════════════════════════════════════════════════════════════════════

class LiquidGlassPainter extends CustomPainter {
  final double radius;
  final double focusRingOpacity;

  LiquidGlassPainter({
    required this.radius,
    required this.focusRingOpacity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));

    // Depth first (inner shadow), then the rim light on top.
    _paintInnerShadow(canvas, size, rrect);
    _paintRimLight(canvas, rect, rrect);
    if (focusRingOpacity > 0.001) _paintFocusRing(canvas, rrect);
  }

  void _paintInnerShadow(Canvas canvas, Size size, RRect rrect) {
    final expand = AppTheme.glassInnerShadowBlurSigma * 4;
    final bigRect = Rect.fromLTWH(
      -expand, -expand,
      size.width + expand * 2, size.height + expand * 2,
    );
    canvas.save();
    canvas.clipRRect(rrect);
    final path = Path()
      ..addRect(bigRect)
      ..addRRect(rrect.shift(AppTheme.glassInnerShadowOffset))
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      path,
      Paint()
        ..color =
            Colors.black.withOpacity(AppTheme.glassInnerShadowOpacity)
        ..maskFilter = MaskFilter.blur(
            BlurStyle.normal, AppTheme.glassInnerShadowBlurSigma),
    );
    canvas.restore();
  }

  // ── Rim light ───────────────────────────────────────────────────────────────
  // The edge of the glass. On a 600px-wide bar a single corner highlight looks
  // lopsided; Apple lights the WHOLE top edge evenly (overhead light on the
  // curved top) plus a faint rim all around. Three plain srcOver strokes — NO
  // BlendMode.plus, NO MaskFilter.blur: those re-composite non-deterministically
  // on Skia and made the rim flicker every time the text cursor blinked.
  void _paintRimLight(Canvas canvas, Rect rect, RRect rrect) {
    // 1. Faint hairline around the full perimeter — the glass edge reads
    //    everywhere, evenly (no bright corner, no dark corner).
    canvas.drawRRect(
      rrect.deflate(0.4),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..color = Colors.white.withOpacity(AppTheme.glassRimEvenOpacity),
    );

    // 2. Bright TOP-edge highlight. A vertical gradient lights the top edge and
    //    the upper side-arcs, fading out by mid-height — even across the width,
    //    no left/right bias. This is the main specular.
    canvas.drawRRect(
      rrect.deflate(0.3),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppTheme.glassSpecCoreWidth
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withOpacity(AppTheme.glassRimTopOpacity),
            const Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.5],
        ).createShader(rect),
    );

    // 3. Soft BOTTOM-edge caustic — light exiting the underside = glass
    //    thickness. Faint, even across the width.
    canvas.drawRRect(
      rrect.deflate(0.3),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppTheme.glassSpecCoreWidth
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Colors.white.withOpacity(AppTheme.glassRimBottomOpacity),
            const Color(0x00FFFFFF),
          ],
          stops: const [0.0, 0.45],
        ).createShader(rect),
    );
  }

  void _paintFocusRing(Canvas canvas, RRect rrect) {
    canvas.drawRRect(
      rrect.deflate(AppTheme.glassFocusRingWidth * 0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = AppTheme.glassFocusRingWidth
        ..color = Colors.white.withOpacity(
            focusRingOpacity * AppTheme.glassFocusRingOpacity),
    );
  }

  @override
  bool shouldRepaint(LiquidGlassPainter old) =>
      old.radius != radius || old.focusRingOpacity != focusRingOpacity;
}

// ═══════════════════════════════════════════════════════════════════════════
// PRIORITY COLORS
// ═══════════════════════════════════════════════════════════════════════════

Color _priorityColor(int p) {
  switch (p) {
    case 2:  return AppTheme.priorityCritical;
    case 1:  return AppTheme.priorityHigh;
    default: return AppTheme.priorityNormal;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GHOST TASK BLOCK
// ═══════════════════════════════════════════════════════════════════════════

class GhostTaskBlock extends StatelessWidget {
  final double colWidth;
  final ParseResult result;
  final String rawTitle;

  const GhostTaskBlock({
    super.key,
    required this.colWidth,
    required this.result,
    required this.rawTitle,
  });

  @override
  Widget build(BuildContext context) {
    if (!result.hasTime) return const SizedBox.shrink();

    final start = result.startTime!;
    final end = result.endTime ?? (start + 60);
    final durationMins = (end - start).clamp(15, 480);
    final blockWidth = (durationMins / 60.0) * colWidth;
    final accent = _priorityColor(result.priority);
    final title = result.cleanTitle.isNotEmpty ? result.cleanTitle : rawTitle;
    final timeLabel = _formatTimeRange(result);

    return AnimatedContainer(
      alignment: Alignment.centerLeft,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      width: blockWidth,
      constraints: const BoxConstraints(minWidth: 32, maxHeight: 56),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            accent.withOpacity(0.12),
            accent.withOpacity(0.04),
          ],
        ),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(
          color: accent.withOpacity(0.35),
          width: 0.75,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withOpacity(0.12),
            blurRadius: 10,
            spreadRadius: -2,
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(7, 5, 7, 5),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              timeLabel,
              style: AppFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w700,
                color: accent.withOpacity(0.80),
                letterSpacing: 0.2,
              ),
            ),
            if (title.isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                title,
                style: AppFonts.inter(
                  fontSize: 10,
                  fontWeight: FontWeight.w400,
                  color: Colors.white.withOpacity(0.50),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ],
        ),
      ),
    )
        .animate()
        .fadeIn(duration: 200.ms)
        .scale(
          begin: const Offset(0.93, 0.93),
          duration: 250.ms,
          curve: Curves.easeOutBack,
        );
  }
}

String _formatTimeRange(ParseResult r) {
  if (!r.hasTime) return '';
  final start = r.startTimeFormatted ?? '';
  final end = r.endTimeFormatted;
  if (end != null) return '$start → $end';
  return start;
}
