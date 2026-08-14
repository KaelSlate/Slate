import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/theme/app_theme.dart';
import 'package:slate/ui/widgets/reminder_card.dart';

/// Renders the reminder card to PNG so it can be judged with EYES.
///
/// The project's own law: visual bugs are found by looking at pixels, not by a
/// green flag — the pill passed 12/12 while it was visibly broken. Launching
/// the app is off limits during a work session (one live instance, one global
/// mutex), so this is how the card gets looked at at all.
///
/// The morph frames are not hand-picked numbers: they evaluate the REAL spring
/// simulations at real timestamps, so the series shows the motion that ships,
/// including whether the height is genuinely still filling out after the width
/// has arrived.
///
/// These are not assertions about correctness. They are a way to SEE.

/// What sits behind the card. Only meaningful for the acrylic body, which is
/// what Windows 11 actually ships.
enum Ground { neutral, page, busy }

void main() {
  // Without this the renderer draws boxes instead of glyphs, and typography is
  // exactly what these images exist to judge. Same TTFs the app ships.
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    for (final f in const {
      'Inter': 'assets/fonts/Inter.ttf',
      'InterTight': 'assets/fonts/InterTight.ttf',
      'RobotoMono': 'assets/fonts/RobotoMono.ttf',
    }.entries) {
      final loader = FontLoader(f.key)
        ..addFont(File(f.value).readAsBytes().then(
              (b) => ByteData.view(Uint8List.fromList(b).buffer),
            ));
      await loader.load();
    }
  });

  final shot = GlobalKey();

  /// Asset images resolve asynchronously; pumpAndSettle alone captures the
  /// frame before the app mark has decoded, which is how the icon "vanished"
  /// from half the shots.
  Future<void> settleWithImages(WidgetTester tester) async {
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pumpAndSettle();
  }

  /// What the card is sitting ON.
  ///
  /// This matters more than it looks. On Windows 10 the body is opaque
  /// (`glassOpaqueBody`, 93 %) and the ground barely shows. On Windows 11 22H2+
  /// the compositor blurs the real desktop behind the window and the body drops
  /// to 58 % — so the ground comes THROUGH the card, and every legibility
  /// judgement made on the opaque variant is worthless for the machines most
  /// people are actually running.
  Widget ground(Ground g, Widget child) {
    switch (g) {
      case Ground.neutral:
        // A warm neutral, not black: black hides exactly the shadow and rim
        // work that the card is judged on.
        return ColoredBox(color: const Color(0xFF2A2521), child: child);
      case Ground.page:
        // The worst case for a dark translucent card: a white document.
        return ColoredBox(color: const Color(0xFFF2F2F0), child: child);
      case Ground.busy:
        // A blurred colourful desktop, which is what acrylic actually samples.
        return DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF2B6CB0),
                Color(0xFF9B5DE5),
                Color(0xFFE8A33D),
                Color(0xFF1D7A5F),
              ],
            ),
          ),
          child: child,
        );
    }
  }

  /// Padded, so the shadow is inside the frame — the shadow is half of what
  /// these images exist to judge.
  Widget frame(
    Widget card, {
    Ground on = Ground.neutral,
  }) =>
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: ground(
            on,
            Center(
              child: RepaintBoundary(
                key: shot,
                child: Padding(
                  padding: const EdgeInsets.all(58),
                  child: SizedBox(width: AppTheme.notifyWidth, child: card),
                ),
              ),
            ),
          ),
        ),
      );

  Widget row({
    required String title,
    String time = '18:00',
    String lede = 'in 5 minutes',
    int priority = 0,
    bool mark = true,
    bool divider = false,
    bool striking = false,
    GlobalKey? ringKey,
  }) =>
      ReminderRow(
        ringKey: ringKey,
        title: title,
        time: time,
        lede: lede,
        priority: priority,
        showMark: mark,
        isLastRow: true,
        showDivider: divider,
        striking: striking,
        onOpen: () {},
        onDone: () {},
        onCollapsed: () {},
        onPressedChanged: (_) {},
      );

  Widget shell(
    List<Widget> rows, {
    ShellShape shape = ShellShape.settled,
    ShellShape? shadowShape,
    bool acrylic = false,
    bool dismiss = false,
  }) =>
      ReminderCardShell(
        acrylic: acrylic,
        shape: shape,
        shadowShape: shadowShape,
        overlay: dismiss ? DismissButton(visible: true, onTap: () {}) : null,
        child: MaterialisingContent(
          t: shape.contentT,
          child: Column(mainAxisSize: MainAxisSize.min, children: rows),
        ),
      );

  Future<void> capture(WidgetTester tester, String name) =>
      expectLater(find.byKey(shot), matchesGoldenFile('goldens/$name.png'));

  // ── the settled card ───────────────────────────────────────────────────────

  testWidgets('plain card', (tester) async {
    await tester.pumpWidget(frame(shell([row(title: 'Dinner with Anna')])));
    await settleWithImages(tester);
    await capture(tester, 'notify_plain');
  });

  // ── the way out ────────────────────────────────────────────────────────────
  //
  // It straddles the top-left corner, so these shots are also the check that it
  // is NOT being sliced by the morph clip or by the Stack — the whole reason
  // ReminderCardShell grew an `overlay` slot.

  testWidgets('dismiss button offered on hover', (tester) async {
    await tester.pumpWidget(
        frame(shell([row(title: 'Dinner with Anna')], dismiss: true)));
    await settleWithImages(tester);
    await capture(tester, 'notify_dismiss');
  });

  testWidgets('dismiss button over a light document', (tester) async {
    await tester.pumpWidget(frame(
      shell([row(title: 'Dinner with Anna')], acrylic: true, dismiss: true),
      on: Ground.page,
    ));
    await settleWithImages(tester);
    await capture(tester, 'notify_dismiss_page');
  });

  testWidgets('important card', (tester) async {
    await tester.pumpWidget(frame(shell([
      row(title: 'Call the landlord back', priority: 1),
    ])));
    await settleWithImages(tester);
    await capture(tester, 'notify_important');
  });

  testWidgets('insistent card', (tester) async {
    await tester.pumpWidget(frame(shell([
      row(title: 'Sign the lease before six', priority: 2),
    ])));
    await settleWithImages(tester);
    await capture(tester, 'notify_insistent');
  });

  testWidgets('long title wraps instead of being cut off', (tester) async {
    await tester.pumpWidget(frame(shell([
      row(
        title:
            'Prepare the quarterly financial report for the board and send it',
      ),
    ])));
    await settleWithImages(tester);
    await capture(tester, 'notify_long_title');
  });

  testWidgets('stack of three', (tester) async {
    await tester.pumpWidget(frame(shell([
      row(title: 'Dinner with Anna'),
      row(title: 'Call the landlord', priority: 1, mark: false, divider: true),
      // A different time MUST read as a different sentence. The old hardcoded
      // string made this row claim "in five minutes" at 18:30.
      row(
          title: 'Ship the draft',
          time: '18:30',
          lede: 'in 35 minutes',
          priority: 2,
          mark: false,
          divider: true),
    ])));
    await settleWithImages(tester);
    await capture(tester, 'notify_stack');
  });

  // ── the variant that actually ships ────────────────────────────────────────
  //
  // Every shot above is the Windows 10 fallback: an opaque body, where the
  // ground cannot reach the text. Windows 11 22H2+ — most machines — gets the
  // compositor's real acrylic and a 58 % body, so the desktop comes THROUGH.
  // Judging legibility on the opaque variant alone was the same mistake as
  // judging the pill by its Win32 rect: green, and about the wrong thing.

  for (final g in Ground.values) {
    testWidgets('acrylic body over ${g.name}', (tester) async {
      await tester.pumpWidget(frame(
        shell([row(title: 'Dinner with Anna')], acrylic: true),
        on: g,
      ));
      await settleWithImages(tester);
      await capture(tester, 'notify_acrylic_${g.name}');
    });
  }

  testWidgets('acrylic stack over a busy desktop', (tester) async {
    await tester.pumpWidget(frame(
      shell([
        row(title: 'Dinner with Anna'),
        row(title: 'Call the landlord', priority: 1, mark: false, divider: true),
        row(
            title: 'Ship the draft',
            time: '18:30',
            priority: 2,
            mark: false,
            divider: true),
      ], acrylic: true),
      on: Ground.busy,
    ));
    await settleWithImages(tester);
    await capture(tester, 'notify_acrylic_stack');
  });

  // ── the morph, frame by frame ──────────────────────────────────────────────

  double springAt(double damping, double seconds) => SpringSimulation(
        SpringDescription(
          mass: 1.0,
          stiffness: AppTheme.notifyMorphStiffness,
          damping: damping,
        ),
        0.0,
        1.0,
        0.0,
      ).x(math.max(0.0, seconds));

  // Sampled where the motion actually lives now: the whole entrance is over
  // inside ~360 ms, so frames past that would be the same picture three times,
  // which is precisely the defect this series exists to catch.
  for (final ms in const [30, 70, 120, 190, 280, 380]) {
    testWidgets('morph at ${ms}ms', (tester) async {
      final s = ms / 1000.0;
      final w = springAt(AppTheme.notifyMorphWidthDamping, s);
      final h = springAt(AppTheme.notifyMorphHeightDamping, s);
      // The same curve as the width, started two frames late — a real lag, not
      // a divergent curve.
      final sh = springAt(AppTheme.notifyMorphWidthDamping,
          s - AppTheme.notifyShadowLag.inMilliseconds / 1000.0);
      await tester.pumpWidget(frame(shell(
        [row(title: 'Dinner with Anna')],
        shape: ShellShape(widthT: w, heightT: h),
        shadowShape: ShellShape(widthT: sh, heightT: sh),
      )));
      await settleWithImages(tester);
      await capture(tester, 'notify_morph_$ms');
    });
  }

  // ── hover ──────────────────────────────────────────────────────────────────
  //
  // Nothing here tracks the pointer any more: the card answers hover by leaning
  // and by lighting its whole rim, never by putting a highlight where the mouse
  // happens to be. These three used to differ; they should now be identical
  // except for the lean, and that is the point of keeping all three.

  Future<TestGesture> mouseAt(WidgetTester tester, Offset target) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await gesture.moveTo(target);
    await tester.pumpAndSettle();
    return gesture;
  }

  for (final spot in const {'left': 0.12, 'centre': 0.5, 'ring': 0.9}.entries) {
    testWidgets('hover with the light at ${spot.key}', (tester) async {
      await tester.pumpWidget(frame(shell([row(title: 'Dinner with Anna')])));
      await settleWithImages(tester);
      final box = tester.getRect(find.byType(ReminderCardShell));
      await mouseAt(
          tester, Offset(box.left + box.width * spot.value, box.center.dy));
      await capture(tester, 'notify_hover_${spot.key}');
    });
  }

  testWidgets('dismiss button under its own pointer', (tester) async {
    await tester.pumpWidget(
        frame(shell([row(title: 'Dinner with Anna')], dismiss: true)));
    await settleWithImages(tester);
    await mouseAt(tester, tester.getCenter(find.byType(DismissButton)));
    await capture(tester, 'notify_dismiss_hover');
  });

  // ── the ring: four states, and NO tick before the click ────────────────────

  testWidgets('ring at rest', (tester) async {
    await tester.pumpWidget(frame(shell([row(title: 'Dinner with Anna')])));
    await settleWithImages(tester);
    await capture(tester, 'notify_ring_rest');
  });

  testWidgets('ring under the pointer shows NO tick', (tester) async {
    await tester.pumpWidget(frame(shell([row(title: 'Dinner with Anna')])));
    await settleWithImages(tester);
    await mouseAt(tester, tester.getCenter(find.byType(DoneRing)));
    await capture(tester, 'notify_ring_hover');
  });

  testWidgets('ring pressed dents inward', (tester) async {
    await tester.pumpWidget(frame(shell([row(title: 'Dinner with Anna')])));
    await settleWithImages(tester);
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(DoneRing)),
      kind: PointerDeviceKind.mouse,
    );
    // The first pump is the ticker's zeroth tick and moves nothing; the second
    // is the one that carries time past the 90 ms press.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 220));
    await capture(tester, 'notify_ring_pressed');
    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('ring struck, tick fully drawn', (tester) async {
    await tester.pumpWidget(frame(shell([
      row(title: 'Dinner with Anna', striking: true),
    ])));
    await settleWithImages(tester);
    await capture(tester, 'notify_ring_struck');
  });

  // ── the answered exit: the card collapses into the ring ────────────────────

  for (final t in const [0.3, 0.6, 0.85]) {
    testWidgets('collapse into the ring at $t', (tester) async {
      final ringKey = GlobalKey();
      await tester.pumpWidget(frame(shell([
        row(title: 'Dinner with Anna', striking: true, ringKey: ringKey),
      ])));
      await settleWithImages(tester);

      final ring = ringKey.currentContext!.findRenderObject()! as RenderBox;
      final card = tester.renderObject<RenderBox>(
          find.byType(ReminderCardShell).first);
      final centre =
          ring.localToGlobal(ring.size.center(Offset.zero), ancestor: card);

      final collapsing = ShellShape(collapseT: t, collapseCenter: centre);
      await tester.pumpWidget(frame(ReminderCardShell(
        acrylic: false,
        shape: collapsing,
        // The same expression the scene uses, so this photograph cannot flatter
        // the real thing.
        child: MaterialisingContent(
          t: collapsing.contentOpacity,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            row(title: 'Dinner with Anna', striking: true),
          ]),
        ),
      )));
      await settleWithImages(tester);
      await capture(tester, 'notify_collapse_${(t * 100).round()}');
    });
  }
}
