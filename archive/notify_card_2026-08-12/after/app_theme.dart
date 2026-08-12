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

  // ── Done ────────────────────────────────────────────────────────────────────
  /// The single green. Was written out eight times across three files; a
  /// constant that half the call sites ignore is worse than eight honest
  /// literals, because then there are two sources of truth.
  static const Color taskDone = Color(0xFF30D158);

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

  // ════════════════════════════════════════════════════════════════════════════
  // REMINDER CARD — it does not slide in, it GROWS
  //
  // The card is born a pill at the bottom centre — the same spot the capture
  // pill lives (`pill_window.dart`, bottom: 48, centred). One place: where you
  // speak, and where you are spoken to.
  //
  // What makes it read as expensive is that the SHELL ANIMATES REAL GEOMETRY —
  // an actual width and an actual height — while the contents sit at their
  // final size and are never transformed at all. That is Apple's own trick, and
  // the reason a Dynamic Island can deform hard without smearing a glyph.
  // Scaling the card WITH its text (what this file used to do) is an imitation
  // of a morph, and the eye catches it without being able to name it.
  //
  // The two axes ride SEPARATE springs. Width has the bigger job (204 px against
  // the height's 32) and leads; height lags and fills out behind it. That
  // desynchronisation is the whole liquid quality — one spring would just be a
  // box getting bigger.
  //
  // Apple's duration/bounce model converted to Flutter's mass/stiffness/damping:
  //   stiffness = (2π / response)²        damping = (1 − bounce) · 4π / response
  // Bounce 0.15 is barely felt, 0.30 is noticeably springy, past ~0.4 it is a
  // caricature (WWDC23, "Animate with springs").
  // ════════════════════════════════════════════════════════════════════════════

  static const double notifyWidth = 344.0;
  static const double notifyRadius = 16.0;

  /// PRIORITY, and the decision the deleted `notifyAccentWidth` was standing in
  /// for. No stripe. A full-height accent bar is Outlook grammar; it would
  /// collide with the mark column, and three of them down a stack turns a calm
  /// banner into a status board — the guilt mechanic the compass bans.
  ///
  /// A tinted halo was the other candidate and lost on the same test: it is
  /// still colour, so it does nothing for a colour-blind reader, and at the
  /// alpha it would need over an arbitrary desktop it reads as nothing at all.
  ///
  /// So: a dot before the time. PRESENCE is the channel — "is there a dot"
  /// is not a judgement about hue — with colour and weight layered on top for
  /// everyone else. Absence is the third state and it is load-bearing: a mark
  /// every card carries is a mark no card has.
  static const double notifyPriorityDot = 5.0;

  /// Body over real acrylic. 0.58 measured 3.8 : 1 for the title over a light
  /// document — under WCAG AA's 4.5 : 1, on the exact ground the goldens use.
  /// 0.72 gives 5.6 : 1. This is also the macOS 26 → 27 direction: more opacity
  /// for legibility, not less.
  static const double notifyAcrylicBody = 0.72;

  /// THE DARK EDGE — the one thing the rim did not have.
  ///
  /// Golden Gate's move is "darkened edge AND brighter specular", and the two
  /// are one idea. Brightening the top rim on its own only makes the card glow
  /// and dissolve into a light background. A dark boundary underneath turns the
  /// same highlight into a LIT EDGE OF A SOLID OBJECT: thickness is read from
  /// the contrast between them, not from the brightness of either.
  ///
  /// Even all round, on the OUTSET path. The object has thickness everywhere;
  /// only the light is directional. A stroke made thicker at the top would be a
  /// drawn border — Apple never draws a heavier line, it lights the same one.
  static const double notifyRimDarkOpacity = 0.28;
  static const double notifyRimDarkWidth = 1.0;

  /// The card's own even hairline, brighter than the pill's 0.09 now that the
  /// dark edge sits under it. `glassRimEvenOpacity` stays where it is — it
  /// belongs to the pill, which has no dark edge.
  static const double notifyRimEvenOpacity = 0.14;

  /// Top rim, at rest and at full hover. Raised with the dark edge, never
  /// without it.
  static const double notifyRimTopOpacity = 0.50;
  static const double notifyRimTopHoverOpacity = 0.72;

  // ── The morph ───────────────────────────────────────────────────────────────

  /// What it is born as. A true pill: at this height the radius IS h/2, so the
  /// silhouette starts as a lozenge and resolves into a card.
  ///
  /// The card measures 344 x ~55.5, not the ~62 the first pass assumed. From a
  /// 40 px seed the height only had 15.5 px to travel, which made its spring
  /// decorative — a documented bounce of 0.20 came to 0.237 px of overshoot, on
  /// no display ever manufactured. 26 px nearly doubles the journey and makes
  /// the seed read as an actual lozenge rather than a short brick.
  static const double notifySeedWidth = 120.0;
  static const double notifySeedHeight = 26.0;

  /// BOTH AXES SHARE A RESPONSE (0.28 s) so that they LAND TOGETHER.
  ///
  /// This is the correction that mattered most. The first pass gave them
  /// different responses — 0.42 and 0.50 — believing the lag would read as
  /// liquid. Measured, the peak divergence came to 2 % of the aspect ratio,
  /// invisible; what it actually bought was five different arrival times spread
  /// over 267 ms, with the two properties that DEFINE the silhouette landing
  /// last. Rendered frames at 280, 400 and 560 ms were indistinguishable by
  /// eye: a third of the entrance was motion nobody could see, which is the
  /// difference between an animation that finishes and one that is abandoned.
  ///
  /// Apple motion lands. There is a frame where every property stops together.
  ///
  /// The two axes still differ — in CHARACTER, not in arrival. Width carries
  /// the bounce (its journey is 224 px, so 3.2 % is a visible 7 px), height is
  /// nearly smooth. That contrast is legible; a difference in arrival was not.
  static const double notifyMorphStiffness = 503.6;

  /// bounce 0.26 → damping = (1 − 0.26) · 4π / 0.28.
  static const double notifyMorphWidthDamping = 33.2;

  /// bounce 0.10 → all but smooth. The calm axis.
  static const double notifyMorphHeightDamping = 40.4;

  /// The shadow is the SAME curve, started two frames late.
  ///
  /// It used to be a differently-damped spring, which is not a lag — it is a
  /// divergent curve. Measured mid-entrance the shadow sat 6 px INSIDE the body
  /// on every side while at rest it reaches 11 px outside it, so over a quarter
  /// second the shadow travelled from under the card to around it. A shadow
  /// that changes its relationship to the thing casting it is not mass.
  static const Duration notifyShadowLag = Duration(milliseconds: 33);

  /// The scene's own rise: ZERO, deliberately.
  ///
  /// There used to be 18 px of it. Because the shell grows from a PINNED BOTTOM
  /// EDGE the top edge was already rising on the height spring — so the rise
  /// put the bottom edge on one clock and the top edge on two, on one object,
  /// at opposite ends. And 92 % of it was spent before the content was even
  /// half materialised, i.e. entirely while the card was still a pill nobody
  /// had looked at. The morph already supplies every pixel of upward motion
  /// this card needs, from the right anchor.
  static const double notifyEnterRise = 0.0;

  /// The contents MATERIALISE rather than appear: blur and opacity move
  /// together (Apple's rule), and they finish INSIDE the shell's motion rather
  /// than after it — otherwise the content is one more late arrival.
  ///
  /// Sigma was 8.0, which on a 28 px app mark is not a soft focus but an orange
  /// stain with no shape.
  static const double notifyContentBlurSigma = 4.0;
  static const double notifyContentRise = 6.0;
  static const double notifyContentFadeStart = 0.35;
  static const double notifyContentFadeEnd = 0.80;

  /// How far off-screen a flicked card is carried, past its own width.
  static const double notifySlideOvershoot = 40.0;

  // ── Hover: depth and light, never a wash ────────────────────────────────────

  /// Was 1.8 px and invisible. Depth has to be legible to be depth. Spent in Z
  /// now rather than in Y — see `_tilt`.
  static const double notifyHoverLift = 4.0;

  /// The card LEANS AWAY FROM THE POINTER.
  ///
  /// A lift plus a highlight is how a flat interface says "you are here". A
  /// surface that changes its ORIENTATION is how a physical one does, and it is
  /// the direction Apple took visionOS and is carrying into 26 across the rest
  /// of the platforms: tilt the thing and its shadow moves, its specular moves,
  /// and the glass stops being a picture of glass.
  ///
  /// Small numbers on purpose. Past roughly three degrees a card this size
  /// stops reading as glass and starts reading as a playing card being flipped
  /// — which is what the web version of this effect always looks like.
  static const double notifyPerspective = 0.0013;

  /// Radians. Y is the louder axis because the card is six times wider than it
  /// is tall, so a lean about the VERTICAL axis is the one that shows.
  static const double notifyTiltX = 0.030;
  static const double notifyTiltY = 0.052;
  static const Duration notifyHoverDuration = Duration(milliseconds: 160);

  // NO POINTER-TRACKING LIGHT. Retired 2026-08-12 after two live looks.
  //
  // There were five constants here — a surface specular pool, a rim lens, their
  // vertical squash, and a counter-slide factor that made the pool travel
  // against the cursor as the reflection of a fixed lamp. Each pass was more
  // physically defensible than the last, and every one of them still read as a
  // web card: the second worst of all, because motion AGAINST the pointer draws
  // more attention to the fact that a decoration is moving.
  //
  // The reference is unambiguous. macOS notification banners do not respond to
  // pointer position at all — no travelling highlight, no glow. Hover reveals
  // an affordance; it does not light the glass. A specular that follows focus
  // is a visionOS and tvOS idiom, and those are focus-driven surfaces on
  // displays nobody points at. On a desktop banner it is landing-page grammar.
  //
  // What is left is ONE fixed overhead source, entirely on the rim, and a card
  // that answers the pointer with orientation instead: it leans, it lifts, its
  // shadow spreads. The lamp never moves, because lamps do not follow hands.
  //
  // Consequence worth keeping: neither the body nor the rim depends on pointer
  // position now, so `shouldRepaint` returns false while the mouse moves and
  // the whole card stops repainting on hover — only the tilt Transform changes,
  // which is a compositing operation.

  /// Per-frame easing of the TILT toward the pointer. At 0.16 it lags by
  /// roughly seven frames — the lean CHASES the cursor instead of being glued
  /// to it, and that lag is the entire difference between alive and sticky.
  static const double notifyLightEase = 0.16;

  /// Press feedback on the body. Scale on live text, so filterQuality is
  /// mandatory while it moves (section 7 of the manifest).
  ///
  /// 100 ms, Apple's published figure for press feedback. At 150 the dent read
  /// as a transition rather than an answer, and the ring beside it was already
  /// replying in 90.
  static const double notifyPressScale = 0.985;
  static const Duration notifyPressDuration = Duration(milliseconds: 100);

  /// Pointer over the card holds it; leaving restarts a shorter clock.
  static const Duration notifyHoverGrace = Duration(milliseconds: 2500);

  // ── The ring ────────────────────────────────────────────────────────────────

  static const double notifyRingHoverScale = 1.12;

  /// Pressed on POINTER-DOWN, instantly — Apple highlights on touch-down and
  /// commits on touch-up. A control that waits for the release has no answer
  /// for the moment your finger is actually on it.
  static const double notifyRingPressScale = 0.86;
  static const Duration notifyRingPressDuration = Duration(milliseconds: 90);

  /// Release spring: response 0.30 s. Hover bounce 0.30, release bounce 0.38 —
  /// the release is allowed to be springier because the bounce is EARNED by the
  /// gesture, which is Apple's original rule for when overshoot is legitimate.
  static const double notifyRingStiffness = 438.0;
  static const double notifyRingHoverDamping = 29.3;
  static const double notifyRingReleaseDamping = 26.0;

  /// The tick strokes itself.
  ///
  /// 160 ms was right on a 60 Hz display and wrong everywhere else. Measured on
  /// the owner's machine — a Parsec session, where DWM hands out vsync every
  /// two or three refreshes — the app renders each frame in 2.3 ms but only
  /// gets 25 to 30 of them a second. At that cadence 160 ms is FOUR FRAMES, and
  /// a stroke drawn in four frames does not read as drawing. It reads as a
  /// flash, which is exactly the word that came back.
  ///
  /// 260 ms is seven frames there and sixteen on a normal display: still far
  /// too short to wait for, long enough to be a gesture on both.
  static const Duration notifyTickDrawDuration = Duration(milliseconds: 260);

  // ── Leaving ─────────────────────────────────────────────────────────────────

  /// Unasked-for and unanswered: it simply recedes. Deliberately about half the
  /// entrance — what leaves must not ask for attention on the way out.
  static const Duration notifyDismissDuration = Duration(milliseconds: 190);

  /// Answered: the card collapses INTO the ring you just pressed and winks out.
  /// The pause first, so the tick is actually seen.
  static const Duration notifyDonePause = Duration(milliseconds: 140);
  static const Duration notifyCollapseToRing = Duration(milliseconds: 320);

  /// Half the ring's own 18 px. It was 11, which overshot the target by 2 px on
  /// every side — the card came to rest not quite on the thing it was aiming at.
  static const double notifyRingCollapseRadius = 9.0;

  /// The shell only starts dissolving once it is ALREADY a circle.
  ///
  /// It used to begin at 0.72, and the shape does not become circular until
  /// about 0.95 — so the circle existed for roughly one frame, at 18 % opacity.
  /// Everything a person actually saw was an anonymous capsule travelling.
  static const double notifyCollapseFadeStart = 0.88;

  /// How green the shell goes as it is drawn in. At 0.22 over a near-black body
  /// the terminal dot measured rgb(39, 66, 40) — dark olive — against a tick of
  /// rgb(47, 203, 86). The reward colour has to be the reward colour.
  static const double notifyCollapseTint = 0.85;

  /// One row of several going away: the row folds, the card stays.
  static const Duration notifyCollapseDuration = Duration(milliseconds: 260);

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
