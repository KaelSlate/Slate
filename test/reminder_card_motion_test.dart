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
  Widget host(Widget child) => MaterialApp(
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Center(
            child: SizedBox(width: AppTheme.notifyWidth, child: child),
          ),
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

    test('halfway through the collapse it is a capsule, not a rectangle', () {
      const half = ShellShape(collapseT: 0.5, collapseCenter: Offset(312, 36));
      final r = half.rect(size);
      // Well past the resting 16: the curvature travels WITH the shape.
      expect(half.radius(size), greaterThan(AppTheme.notifyRadius));
      expect(r.width, lessThan(size.width));
      expect(r.height, lessThan(size.height));
    });
  });
}
