import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/theme/app_theme.dart';
import 'package:slate/ui/widgets/reminder_card.dart';

/// The goldens are for EYES. These are for the things eyes cannot settle:
/// whether a press actually fired, whether a silhouette is really where the
/// arithmetic says it is, whether a ticker stopped.
///
/// The press in particular earned this file. A 14 % dent on an 18 px ring is a
/// pixel and a half, and a golden of it looks identical to a golden of nothing
/// happening — the image cannot tell "no press animation" from "a press
/// animation too small to see".
void main() {
  /// The shell is WIDER than the card — it reserves `notifyDismissReach` on
  /// each side so the dismiss button can be touched — so anything hosting one
  /// has to hand it that much room or the card inside gets squeezed.
  Widget host(Widget child, {double width = AppTheme.notifyWidth}) =>
      MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Center(child: SizedBox(width: width, child: child)),
        ),
      );

  Widget ring({bool struck = false, VoidCallback? onTap}) =>
      host(DoneRing(struck: struck, onTap: onTap ?? () {}));

  double ringScale(WidgetTester tester) {
    final t = tester.widget<Transform>(
      find.descendant(
        of: find.byType(DoneRing),
        matching: find.byType(Transform),
      ),
    );
    return t.transform.storage[0];
  }

  group('the ring answers the gesture', () {
    testWidgets('rests at exactly 1.0', (tester) async {
      await tester.pumpWidget(ring());
      await tester.pumpAndSettle();
      expect(ringScale(tester), closeTo(1.0, 0.001));
    });

    testWidgets('grows under the pointer', (tester) async {
      await tester.pumpWidget(ring());
      await tester.pumpAndSettle();
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await gesture.moveTo(tester.getCenter(find.byType(DoneRing)));
      await tester.pumpAndSettle();
      expect(ringScale(tester),
          closeTo(AppTheme.notifyRingHoverScale, 0.01));
    });

    testWidgets('dents on pointer DOWN, not on release', (tester) async {
      await tester.pumpWidget(ring());
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(DoneRing)),
        kind: PointerDeviceKind.mouse,
      );
      // The first pump is the ticker's own zeroth tick and moves nothing; the
      // second is the one that carries time.
      //
      // The window here is deliberately SHORTER than the tap recogniser's
      // 100 ms press timeout. That is the whole point: with a `GestureDetector`
      // the dent waited for that deadline — or, on a click faster than it, for
      // the pointer to come back UP — so a quick press showed no feedback at
      // all. A `Listener` has no arena and no deadline.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(
        ringScale(tester),
        lessThan(0.93),
        reason: 'the dent must be well under way before any tap deadline',
      );
      await tester.pump(const Duration(milliseconds: 120));
      expect(
        ringScale(tester),
        closeTo(AppTheme.notifyRingPressScale, 0.01),
        reason: 'the ring must be pressed while the button is still held',
      );
      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('overshoots on release — the bounce a gesture earned',
        (tester) async {
      await tester.pumpWidget(ring());
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(DoneRing)),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      await gesture.up();

      // The pointer is still over the ring, so home is the hovered size.
      const home = AppTheme.notifyRingHoverScale;
      var peak = 0.0;
      for (var i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 16));
        peak = peak > ringScale(tester) ? peak : ringScale(tester);
      }
      expect(peak, greaterThan(home),
          reason: 'the release spring must carry it past its target');
      await tester.pumpAndSettle();
      expect(ringScale(tester), closeTo(home, 0.02));
    });

    testWidgets('a struck ring cannot be pressed again', (tester) async {
      var taps = 0;
      await tester.pumpWidget(ring(struck: true, onTap: () => taps++));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DoneRing));
      await tester.pumpAndSettle();
      expect(taps, 0);
    });
  });

  group('the way out can actually be hit', () {
    // Photographed on the live card: moving the pointer onto the dismiss button
    // made it VANISH, and clicks landed on the card behind it. These pin the
    // two halves of that — does the button take a click at all, and does
    // hovering it keep the card hovered rather than counting as a departure.

    Widget carded({required VoidCallback onTap, ValueChanged<bool>? hover}) =>
        host(
          ReminderCardShell(
            acrylic: false,
            onHoverChanged: hover,
            overlay: DismissButton(visible: true, onTap: onTap),
            // A real card's height, and a width that fills the shell: a child
            // with no width leaves the silhouette degenerate and the shape
            // maths clamps against a zero-sized rect.
            child: const SizedBox(width: double.infinity, height: 56),
          ),
          width: AppTheme.notifyWidth + AppTheme.notifyDismissReach * 2,
        );

    testWidgets('a tap on the button reaches it', (tester) async {
      var taps = 0;
      await tester.pumpWidget(carded(onTap: () => taps++));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DismissButton));
      await tester.pumpAndSettle();
      expect(taps, 1,
          reason: 'the button is painted by a CustomPaint, and a CustomPaint '
              'refuses hit tests unless its painter opts in — so the Listener '
              'above it has to be opaque or nothing ever reaches it');
    });

    testWidgets('every corner of the target answers, not just the middle',
        (tester) async {
      var taps = 0;
      await tester.pumpWidget(carded(onTap: () => taps++));
      await tester.pumpAndSettle();
      final box = tester.getRect(find.byType(DismissButton));
      // Inset by one logical pixel so the points are unambiguously inside.
      for (final p in [
        box.topLeft + const Offset(1, 1),
        box.topRight + const Offset(-1, 1),
        box.bottomLeft + const Offset(1, -1),
        box.bottomRight + const Offset(-1, -1),
        box.center,
      ]) {
        await tester.tapAt(p);
        await tester.pumpAndSettle();
      }
      expect(taps, 5, reason: 'a 30 px control must not have dead corners');
    });

    testWidgets('the button lies PAST the card, which is the whole point',
        (tester) async {
      await tester.pumpWidget(carded(onTap: () {}));
      await tester.pumpAndSettle();
      final shell = tester.getRect(find.byType(ReminderCardShell));
      final button = tester.getRect(find.byType(DismissButton));
      // The shell reserves room past the card so this can be touched at all.
      expect(button.left, greaterThanOrEqualTo(shell.left));
      expect(button.top, greaterThanOrEqualTo(shell.top));
      expect(button.left, lessThan(shell.left + AppTheme.notifyDismissReach),
          reason: 'it has to reach outside the CARD, or it is just a button '
              'sitting in a corner');
    });

    testWidgets('the button survives being moved onto, the way the scene wires it',
        (tester) async {
      // The previous test hardcodes `visible: true`, so it cannot see the
      // failure that was photographed on the real card: moving the pointer onto
      // the button made it VANISH. In the scene `visible` is driven by hover,
      // and hover comes from two places that have to be ORed — the card's
      // region and the button's own, because the button lies partly past the
      // card. This reproduces that wiring exactly.
      var hoverCard = false;
      var hoverButton = false;
      await tester.pumpWidget(
        StatefulBuilder(builder: (context, setState) {
          return host(
            ReminderCardShell(
              acrylic: false,
              onHoverChanged: (v) => setState(() => hoverCard = v),
              overlay: DismissButton(
                visible: hoverCard || hoverButton,
                onTap: () {},
                onHoverChanged: (v) => setState(() => hoverButton = v),
              ),
              child: const SizedBox(width: double.infinity, height: 56),
            ),
            width: AppTheme.notifyWidth + AppTheme.notifyDismissReach * 2,
          );
        }),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      final shellBox = tester.getRect(find.byType(ReminderCardShell));
      await gesture.moveTo(shellBox.center);
      await tester.pumpAndSettle();
      expect(hoverCard, isTrue, reason: 'the card is hovered');

      final buttonCentre = tester.getCenter(find.byType(DismissButton));
      await gesture.moveTo(buttonCentre);
      await tester.pumpAndSettle();
      expect(hoverCard || hoverButton, isTrue,
          reason: 'the pointer is ON the button — if neither flag is set the '
              'button unmounts from under it, which is what happened live');

      // ...and it is still there to be pressed.
      expect(find.byType(DismissButton), findsOneWidget);
      final still = tester.getRect(find.byType(DismissButton));
      expect(still.contains(buttonCentre), isTrue,
          reason: 'the button must not have moved out from under the pointer');
    });

    testWidgets('a card-exit arriving BEFORE the button-enter is survivable',
        (tester) async {
      // The failure the previous test cannot see, because it settles both
      // events in one pump. Live, leaving the card and arriving on the button
      // can land in separate mouse-tracker updates: for one frame neither flag
      // is set, the button unmounts, and the enter it was about to receive has
      // nowhere to go. It never came back.
      //
      // This drives the two halves apart on purpose and asserts the button is
      // still there when the second one lands.
      var hoverCard = true;
      var hoverButton = false;
      late StateSetter set;
      await tester.pumpWidget(
        StatefulBuilder(builder: (context, setState) {
          set = setState;
          return host(
            ReminderCardShell(
              acrylic: false,
              overlay: DismissButton(
                visible: hoverCard || hoverButton,
                onTap: () {},
              ),
              child: const SizedBox(width: double.infinity, height: 56),
            ),
            width: AppTheme.notifyWidth + AppTheme.notifyDismissReach * 2,
          );
        }),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DismissButton), findsOneWidget);

      // The card reports the pointer gone...
      set(() => hoverCard = false);
      await tester.pump();
      // ...and only THEN does the button report it arrived.
      set(() => hoverButton = true);
      await tester.pumpAndSettle();

      expect(find.byType(DismissButton), findsOneWidget,
          reason: 'the button must not have been torn down in the gap between '
              'the two reports — the scene bridges it with a zero-duration '
              'timer so a hand-off is not read as a departure');
    });

    testWidgets('hovering the button does not read as leaving the card',
        (tester) async {
      final seen = <bool>[];
      await tester.pumpWidget(
          carded(onTap: () {}, hover: (v) => seen.add(v)));
      await tester.pumpAndSettle();

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);

      await gesture.moveTo(tester.getCenter(find.byType(ReminderCardShell)));
      await tester.pumpAndSettle();
      expect(seen.last, isTrue, reason: 'the card is hovered');

      await gesture.moveTo(tester.getCenter(find.byType(DismissButton)));
      await tester.pumpAndSettle();
      expect(seen.last, isTrue,
          reason: 'moving onto the button must not report the card as left — '
              'that is what took the button out from under the pointer');
    });
  });

  group('the silhouette is where the arithmetic says', () {
    const size = Size(344, 72);

    test('starts as a true pill: radius is exactly half its height', () {
      const seed = ShellShape(widthT: 0, heightT: 0);
      final r = seed.rect(size);
      expect(r.width, AppTheme.notifySeedWidth);
      expect(r.height, AppTheme.notifySeedHeight);
      expect(seed.radius(size), closeTo(AppTheme.notifySeedHeight / 2, 0.001));
      // Grown from the bottom edge — it unfurls upward from where it landed.
      expect(r.bottom, closeTo(size.height, 0.001));
      expect(r.center.dx, closeTo(size.width / 2, 0.001));
    });

    test('settles at the full card', () {
      final r = ShellShape.settled.rect(size);
      expect(r, Offset.zero & size);
      expect(ShellShape.settled.radius(size), AppTheme.notifyRadius);
    });

    test('the radius never exceeds half the short side, even overshooting', () {
      for (final t in const [0.0, 0.2, 0.5, 0.8, 1.0, 1.1, 1.3]) {
        final s = ShellShape(widthT: t, heightT: t);
        final r = s.rect(size);
        expect(s.radius(size),
            lessThanOrEqualTo(r.shortestSide / 2 + 0.001),
            reason: 'a radius past half the short side breaks the silhouette');
      }
    });

    test('the contents stay invisible while the shell is still a pill', () {
      expect(const ShellShape(widthT: 0.5, heightT: 0.2).contentT, 0.0);
      // ...and they are fully present BEFORE the shell finishes, so the card
      // has one moment of arrival rather than a queue of them.
      expect(const ShellShape(widthT: 0.9, heightT: 0.85).contentT, 1.0);
      expect(const ShellShape(widthT: 1.0, heightT: 1.0).contentT, 1.0);
    });

    test('every property of the entrance lands inside the same window', () {
      // The defect this replaced: five arrival times spread over 267 ms, with
      // the two that define the silhouette landing last, and three rendered
      // frames covering the final 280 ms that were indistinguishable by eye.
      double settle(double damping) {
        final sim = SpringSimulation(
          SpringDescription(
            mass: 1.0,
            stiffness: AppTheme.notifyMorphStiffness,
            damping: damping,
          ),
          0.0,
          1.0,
          0.0,
        );
        for (var ms = 0; ms <= 1200; ms += 4) {
          if ((sim.x(ms / 1000.0) - 1.0).abs() < 0.004 &&
              sim.dx(ms / 1000.0).abs() < 0.05) {
            return ms / 1000.0;
          }
        }
        return 99.0;
      }

      final w = settle(AppTheme.notifyMorphWidthDamping);
      final h = settle(AppTheme.notifyMorphHeightDamping);
      expect(w, lessThan(0.42), reason: 'the width must not drift for half a second');
      expect(h, lessThan(0.42));
      expect((w - h).abs(), lessThan(0.12),
          reason: 'both axes have to arrive together, or nothing lands');
    });

    test('collapsing ends as a circle sitting on the ring', () {
      const centre = Offset(312, 36);
      const done = ShellShape(collapseT: 1.0, collapseCenter: centre);
      final r = done.rect(size);
      expect(r.center.dx, closeTo(centre.dx, 0.001));
      expect(r.center.dy, closeTo(centre.dy, 0.001));
      expect(r.width, closeTo(r.height, 0.001));
      // A circle, not a lozenge: the radius reaches half the short side.
      expect(done.radius(size), closeTo(r.shortestSide / 2, 0.001));
    });

    test('the collapse passes through a capsule, never a rounded rectangle', () {
      // This used to assert `radius > 16` at collapseT 0.5 and that assertion
      // was measuring the TIMING, not the shape. The clock midpoint is no
      // longer the shape midpoint: the geometry finishes at
      // `notifyCollapseShapeEnd` and the rest of the clock is the wink, so by
      // half the clock the shell is already about 80 % of the way in and is
      // therefore SMALL. A small radius is the right answer there — what has to
      // hold is that it is fully round.
      const half = ShellShape(collapseT: 0.5, collapseCenter: Offset(312, 36));
      final r = half.rect(size);
      expect(r.width, lessThan(size.width));
      expect(r.height, lessThan(size.height));
      expect(
        half.radius(size),
        closeTo(r.shortestSide / 2, 0.001),
        reason: 'mid-collapse the silhouette must sit at MAXIMUM curvature — a '
            'capsule. Anything less is a card being shrunk, not a card being '
            'drawn into the ring.',
      );

      // ...and early on, while it is still recognisably a card, the curvature
      // has already grown past the resting 16 rather than snapping at the end.
      const early =
          ShellShape(collapseT: 0.25, collapseCenter: Offset(312, 36));
      expect(early.radius(size), greaterThan(AppTheme.notifyRadius));
    });

    test('the shape finishes before the clock does, leaving room to wink', () {
      // The defect this guards: the fade used to get 12 % of a 320 ms collapse
      // — 38 ms, one frame at 30 Hz — because the shell was still becoming a
      // circle at the instant it was supposed to be fading out of one.
      const centre = Offset(312, 36);
      const atShapeEnd = ShellShape(
        collapseT: AppTheme.notifyCollapseShapeEnd,
        collapseCenter: centre,
      );
      final r = atShapeEnd.rect(size);
      expect(r.width, closeTo(r.height, 0.001),
          reason: 'the geometry must already be a circle here');
      expect(r.center.dx, closeTo(centre.dx, 0.001));

      // ...and it does not keep moving afterwards. The rest of the clock is
      // opacity and nothing else.
      const later = ShellShape(collapseT: 0.92, collapseCenter: centre);
      expect(later.rect(size), atShapeEnd.rect(size));

      final winkMs = AppTheme.notifyCollapseToRing.inMilliseconds *
          (1.0 - AppTheme.notifyCollapseShapeEnd);
      expect(winkMs, greaterThan(66.0),
          reason: 'two frames at 30 Hz is the floor for a fade to be seen');
    });
  });
}
