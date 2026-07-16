import 'package:flutter/material.dart';

/// Bundled-font helpers — drop-in replacements for the `google_fonts` API surface
/// we used (same named params). The fonts ship inside the binary (declared in
/// pubspec `fonts:`), so glyph metrics are correct from the FIRST painted frame:
/// no runtime network fetch, no text-reflow on entrance, fully offline. The
/// `wght` axis of each variable font is driven by [TextStyle.fontWeight].
class AppFonts {
  static TextStyle _style(
    String family, {
    TextStyle? textStyle,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? wordSpacing,
    double? height,
    TextDecoration? decoration,
    Color? decorationColor,
    TextDecorationStyle? decorationStyle,
    double? decorationThickness,
  }) {
    final base = textStyle ?? const TextStyle();
    return base.copyWith(
      fontFamily: family,
      color: color,
      backgroundColor: backgroundColor,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontStyle: fontStyle,
      letterSpacing: letterSpacing,
      wordSpacing: wordSpacing,
      height: height,
      decoration: decoration,
      decorationColor: decorationColor,
      decorationStyle: decorationStyle,
      decorationThickness: decorationThickness,
    );
  }

  static TextStyle inter({
    TextStyle? textStyle,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? wordSpacing,
    double? height,
    TextDecoration? decoration,
    Color? decorationColor,
    TextDecorationStyle? decorationStyle,
    double? decorationThickness,
  }) =>
      _style('Inter',
          textStyle: textStyle,
          color: color,
          backgroundColor: backgroundColor,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          letterSpacing: letterSpacing,
          wordSpacing: wordSpacing,
          height: height,
          decoration: decoration,
          decorationColor: decorationColor,
          decorationStyle: decorationStyle,
          decorationThickness: decorationThickness);

  static TextStyle interTight({
    TextStyle? textStyle,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? wordSpacing,
    double? height,
    TextDecoration? decoration,
    Color? decorationColor,
    TextDecorationStyle? decorationStyle,
    double? decorationThickness,
  }) =>
      _style('InterTight',
          textStyle: textStyle,
          color: color,
          backgroundColor: backgroundColor,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          letterSpacing: letterSpacing,
          wordSpacing: wordSpacing,
          height: height,
          decoration: decoration,
          decorationColor: decorationColor,
          decorationStyle: decorationStyle,
          decorationThickness: decorationThickness);

  static TextStyle robotoMono({
    TextStyle? textStyle,
    Color? color,
    Color? backgroundColor,
    double? fontSize,
    FontWeight? fontWeight,
    FontStyle? fontStyle,
    double? letterSpacing,
    double? wordSpacing,
    double? height,
    TextDecoration? decoration,
    Color? decorationColor,
    TextDecorationStyle? decorationStyle,
    double? decorationThickness,
  }) =>
      _style('RobotoMono',
          textStyle: textStyle,
          color: color,
          backgroundColor: backgroundColor,
          fontSize: fontSize,
          fontWeight: fontWeight,
          fontStyle: fontStyle,
          letterSpacing: letterSpacing,
          wordSpacing: wordSpacing,
          height: height,
          decoration: decoration,
          decorationColor: decorationColor,
          decorationStyle: decorationStyle,
          decorationThickness: decorationThickness);
}

/// Slate Design System — v2.1 Warm Graphite
/// Background: #15110D (deep WARM graphite — a reading lamp, not a morgue)
/// Surface:    #1C1813 (elevated warm matte)
/// No pure black (#000000) anywhere in this file — banned.
///
/// v2.1 note: the neutral ramp was shifted from blue-cold (#131316, B-dominant)
/// to warm-graphite (R≥G≥B). The shift is deliberately subtle at near-black —
/// the *felt* warmth comes from this base PLUS the honey accent, the serif
/// welcome face, and the paper-grain texture, not from a brown/sepia tint.

class AppTheme {
  // ── Core Palette (warm graphite ramp) ────────────────────────────────────────
  static const Color background    = Color(0xFF15110D); // Deep warm graphite
  static const Color backgroundAlt = Color(0xFF18140F); // Alternate bg (window chrome)
  static const Color surface       = Color(0xFF1C1813); // Elevated warm matte
  static const Color surfaceLight  = Color(0xFF27211A); // Cards / containers / panels

  // ── Borders ─────────────────────────────────────────────────────────────────
  static const Color border      = Color.fromRGBO(255, 255, 255, 0.07);
  static const Color borderLight = Color.fromRGBO(255, 255, 255, 0.11);
  static const Color borderFocus = Color.fromRGBO(255, 255, 255, 0.22);

  // ── Priority Palette — calm, NO alarm-red/orange ──────────────────────────
  // Recalibrated 2026-07-02: the all-cool ramp was indistinguishable at a glance
  // ("priority doesn't exist"). `!!` now carries the brand's single warm note —
  // muted honey, warm-on-cool, unmistakable yet serene. `!` keeps the calm indigo.
  // Used for inline token tint, the pill spill glow, and task-block accents alike.
  static const Color priorityCritical = honey;             // honey (!!, most important)
  static const Color priorityHigh     = Color(0xFF8E83D6); // calm indigo (!)
  static const Color priorityNormal   = Color(0xFF8AA7D6); // soft slate blue (normal)

  // ── Alias for tags (same calm blue as priorityNormal) ────────────────────────
  static const Color tagColor = Color(0xFF8AA7D6);

  // ── Panel separator ─────────────────────────────────────────────────────────
  static const Color panelDivider = Color(0x14FFFFFF); // white 8%

  // ── Warm brand accent — "honey" (first-run, welcome, signature stroke) ────────
  // Earthy, muted, ours. NOT the alarm-orange ghostOrange, NOT Claude terracotta.
  // This is the single warm note that carries the gentleman/reading-lamp feeling.
  static const Color honey      = Color(0xFFD9A66C); // muted honey/wheat
  static const Color honeyGlow  = Color(0x33D9A66C); // soft bloom (20%)
  static const Color honeyDeep  = Color(0xFFB8895A); // deeper honey (pressed/ink)

  // ── Graphite ink — the hand-drawn pencil stroke color ────────────────────────
  // Warm parchment-white so a "pencil" line reads on the dark warm ground.
  static const Color graphiteInk    = Color(0xFFE8DFD2); // warm pencil stroke
  static const Color graphiteInkSub = Color(0xFFB7AD9E); // dimmer pencil (texture pass)

  // ── Paper grain — faint texture so the canvas feels like a page, not a void ───
  static const double paperGrainOpacity = 0.022; // ~2.2% white-noise overlay

  // ── Accent Colors ───────────────────────────────────────────────────────────
  static const Color ghostOrange     = Color(0xFFFF9500);
  static const Color ghostOrangeGlow = Color(0x40FF9500);
  static const Color electricBlue    = Color(0xFF3B82F6);
  static const Color electricBlueGlow= Color(0x403B82F6);
  static const Color accent          = Colors.white;
  static const Color heatmapLow      = Color(0x1AFF9500);
  static const Color heatmapMid      = Color(0x66FF9500);
  static const Color heatmapHigh     = Color(0xCCFF9500);

  // ── Text Colors ─────────────────────────────────────────────────────────────
  static const Color textPrimary   = Color(0xCCFFFFFF); // 80%
  static const Color textSecondary = Color(0x80FFFFFF); // 50%
  static const Color textTertiary  = Color(0x66FFFFFF); // 40%
  static const Color textMuted     = Color(0x33FFFFFF); // 20%

  // ── Spacing System (8px grid) ───────────────────────────────────────────────
  static const double spacing4  = 4;
  static const double spacing8  = 8;
  static const double spacing12 = 12;
  static const double spacing16 = 16;
  static const double spacing24 = 24;
  static const double spacing32 = 32;
  static const double spacing40 = 40;
  static const double spacing48 = 48;

  // ── Border Radius ───────────────────────────────────────────────────────────
  static const double radiusSmall  = 4;
  static const double radiusMedium = 8;
  static const double radiusLarge  = 12;
  static const double radiusXLarge = 14;

  // ── Inbox Drawer ────────────────────────────────────────────────────────────
  static const double drawerWidth = 340;

  // ════════════════════════════════════════════════════════════════════════════
  // GLASS — the Command Pill, and nothing else.
  //
  // Two hosts, one recipe. Over Slate's own canvas the pill is a real lens:
  // BackdropFilter + saturation. Over FOREIGN windows (global capture) Flutter
  // cannot reach their pixels, so the lens becomes a body — [glassOpaqueBody] —
  // and everything else (rim, sheen, shadows, spring) stays identical.
  //
  // Windows / Skia constraint: ImageFilter.shader (GLSL) inside BackdropFilter
  // is Impeller-only, so edge refraction is simulated with a CustomPainter rim.
  // ════════════════════════════════════════════════════════════════════════════

  // ── Blur ─────────────────────────────────────────────────────────────────────
  // Low sigma on purpose: live content (now-line, grid, task blocks) must stay
  // legible THROUGH the pill — a real transparent lens, not frost.
  static const double glassBlurL3See = 4.0;

  /// Body of the pill when there is nothing to blur (global capture over other
  /// apps). Deep warm graphite at 93% — deliberately near-opaque: unblurred
  /// foreign text behind it would otherwise read straight through as smudges.
  /// Tried lifting it toward the day pill's tone; user preferred this. Leave it.
  static final Color glassOpaqueBody = background.withValues(alpha: 0.93);

  // ── Saturation boost (ColorFilter.matrix applied over backdrop) ───────────────
  // Increases perceived chroma of blurred content — signature Apple look.
  // Matrix: identity with S=1.3 via luminance-preserving formula.
  static const double glassSaturationBoost = 1.3;
  static List<double> get glassSaturationMatrix {
    const s = glassSaturationBoost;
    const l = 1.0 - s;
    const lr = 0.2126 * l;
    const lg = 0.7152 * l;
    const lb = 0.0722 * l;
    return [
      lr + s, lg,     lb,     0, 0,
      lr,     lg + s, lb,     0, 0,
      lr,     lg,     lb + s, 0, 0,
      0,      0,      0,      1, 0,
    ];
  }

  // RIM LIGHT (rewritten 2026-06-19 — stable, even, no BlendMode.plus).
  // A faint hairline around the WHOLE perimeter so the glass edge reads
  // everywhere, a brighter highlight along the TOP edge (overhead light on the
  // curved top), and a soft caustic along the bottom (light exiting = thickness).
  // Plain srcOver white strokes — additive blend + mask-blur were re-composited
  // non-deterministically on Skia and made the rim FLICKER with the text cursor
  // (every blink forced a re-raster that re-lit the edge). Even + deterministic.
  static const double glassRimEvenOpacity   = 0.09;  // hairline all around
  static const double glassRimTopOpacity    = 0.42;  // bright top edge
  static const double glassRimBottomOpacity = 0.10;  // soft bottom caustic
  static const double glassSpecCoreWidth    = 1.2;   // px, rim stroke width

  // ── Inner shadow (glass concavity / depth) ────────────────────────────────────
  static const double glassInnerShadowOpacity   = 0.08;
  static const double glassInnerShadowBlurSigma = 6.0;
  static const Offset glassInnerShadowOffset    = Offset(0, 2);

  // ── Ambient shadow ("pillow" under floating element) ─────────────────────────
  static const double glassAmbientBlur    = 60.0;
  static const double glassAmbientOpacity = 0.40;
  static const Offset glassAmbientOffset  = Offset(0, 20);

  // ── Directional shadow (slight warm tilt) ────────────────────────────────────
  static const double glassDirectionalBlur    = 24.0;
  static const double glassDirectionalOpacity = 0.30;
  static const Offset glassDirectionalOffset  = Offset(0, 12);

  // ── Color spill glow (glass "absorbs" context color) ─────────────────────────
  // Driven by ParseResult: priority → warm, tag → blue, empty → neutral white.
  static const double glassSpillBlur           = 40.0;
  static const double glassSpillOpacityIdle    = 0.0;
  static const double glassSpillOpacityActive  = 0.12;

  // ── Geometry morph ────────────────────────────────────────────────────────────
  // Border radius and padding animate via spring when content state changes.
  static const double glassRadiusIdle   = 28.0;  // empty pill
  static const double glassRadiusActive = 20.0;  // text present

  // ── Spring physics — the ONE entrance, shared by every pill ───────────────────
  // The Alt+Space reveal: the pill unfurls from its own centre, mostly sideways.
  // Non-uniform on purpose — a uniform scale reads as "a thing zoomed in", the
  // wide-X/narrow-Y split reads as "a slot opened". ζ=0.86 → arrives without a
  // visible bounce; k=420 → it is there before you finish pressing the chord.
  //
  // Entrance is scale-ONLY. No Opacity may animate over it: an animating Opacity
  // pushes a saveLayer, the BackdropFilter beneath then samples that empty layer
  // for one frame, and the glass blinks. Fading is allowed ONLY where the body
  // is opaque (global capture over foreign windows) — see [glassOpaqueBody].
  static const double glassSpringAppearDamping    = 0.86;
  static const double glassSpringAppearStiffness  = 420.0;
  static const double glassSpringDismissDamping   = 0.85;
  static const double glassSpringDismissStiffness = 300.0;
  static const double glassSpringScaleFromX       = 0.55;  // unfurls sideways
  static const double glassSpringScaleFromY       = 0.90;  // barely in height
  static const double glassEnterRise              = 10.0;  // px slide-up on enter
  static const Duration glassMorphDuration    = Duration(milliseconds: 350);
  // The ONE exit, shared by every pill: a quick easeInCubic settle-down (matches
  // the global pill window's `_exit`). Applied by SmartDayInputWidget._dismiss.
  static const Duration glassDismissDuration  = Duration(milliseconds: 170);

  // ── Focus ring ───────────────────────────────────────────────────────────────
  // Thin white hairline that fades in (spring) when the TextField has focus.
  static const double glassFocusRingOpacity    = 0.15;
  static const double glassFocusRingWidth      = 0.5;
  static const Duration glassFocusRingDuration = Duration(milliseconds: 200);

  // ════════════════════════════════════════════════════════════════════════════
  // TYPOGRAPHY — Inter / SF Pro aesthetic
  // ════════════════════════════════════════════════════════════════════════════

  // ── Welcome serif (Fraunces) — used ONLY for the first-run greeting ───────────
  // The one hand-set, literary moment. Everything else stays Inter. This serif
  // is what makes "Good afternoon, Kozachok" feel like a book page, not a toast.
  static TextStyle get welcomeSerif => AppFonts.inter(
    fontSize: 34, fontWeight: FontWeight.w500,
    letterSpacing: -0.4, height: 1.1, color: textPrimary,
  );

  static TextStyle get welcomeSerifSub => AppFonts.inter(
    fontSize: 15, fontWeight: FontWeight.w400, fontStyle: FontStyle.italic,
    letterSpacing: 0.1, height: 1.3, color: textSecondary,
  );

  static TextStyle get displayLarge => AppFonts.inter(
    fontSize: 48, fontWeight: FontWeight.w100,
    letterSpacing: 4, color: textPrimary,
  );

  static TextStyle get displayMedium => AppFonts.inter(
    fontSize: 32, fontWeight: FontWeight.w300,
    letterSpacing: 0.5, color: textPrimary,
  );

  static TextStyle get headlineLarge => AppFonts.inter(
    fontSize: 24, fontWeight: FontWeight.w500,
    letterSpacing: 0.3, color: textPrimary,
  );

  static TextStyle get headlineMedium => AppFonts.inter(
    fontSize: 18, fontWeight: FontWeight.w500,
    letterSpacing: 0.2, color: textPrimary,
  );

  static TextStyle get bodyLarge => AppFonts.inter(
    fontSize: 15, fontWeight: FontWeight.w400,
    letterSpacing: 0.1, color: textPrimary,
  );

  static TextStyle get bodyMedium => AppFonts.inter(
    fontSize: 13, fontWeight: FontWeight.w400,
    letterSpacing: 0.1, color: textSecondary,
  );

  static TextStyle get bodyTitle => AppFonts.inter(
    fontSize: 13, fontWeight: FontWeight.w500,
    letterSpacing: 0.05, color: textPrimary,
  );

  static TextStyle get labelSmall => AppFonts.inter(
    fontSize: 10, fontWeight: FontWeight.w600,
    letterSpacing: 0.5, color: textTertiary,
  );

  static TextStyle get labelUppercase => AppFonts.inter(
    fontSize: 11, fontWeight: FontWeight.w600,
    letterSpacing: 1.1, color: textTertiary,
  );

  static TextStyle get mono => AppFonts.inter(
    fontSize: 12, fontWeight: FontWeight.w400,
    letterSpacing: 0.3, color: textTertiary,
  );

  /// Heatmap color ramp (0.0 – 1.0 density → opacity on ghostOrange)
  static Color getHeatmapColor(double density) {
    if (density <= 0.0) return Colors.transparent;
    if (density <= 0.25) return ghostOrange.withOpacity(0.15);
    if (density <= 0.5)  return ghostOrange.withOpacity(0.35);
    if (density <= 0.75) return ghostOrange.withOpacity(0.55);
    return ghostOrange.withOpacity(0.80);
  }

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: background,
      primaryColor: surface,
      textTheme: TextTheme(
        displayLarge:  displayLarge,
        displayMedium: displayMedium,
        headlineLarge: headlineLarge,
        headlineMedium:headlineMedium,
        bodyLarge:     bodyLarge,
        bodyMedium:    bodyMedium,
        labelSmall:    labelSmall,
      ),
      useMaterial3: true,
    );
  }
}
