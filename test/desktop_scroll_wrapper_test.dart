import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/ui/widgets/desktop_scroll_wrapper.dart';

/// The `paused` gate. A wheel tick pages the PageView — unless a modal layer
/// (the month's opened day) has frozen it. The gate lives in the wrapper because
/// it handles the signal synchronously and a descendant cannot intercept it.

Widget harness(PageController pc, ValueListenable<bool> paused) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 400,
          child: DesktopScrollWrapper(
            pageController: pc,
            paused: paused,
            child: PageView.builder(
              controller: pc,
              scrollDirection: Axis.vertical,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: 20,
              itemBuilder: (_, i) => Center(child: Text('page-$i')),
            ),
          ),
        ),
      ),
    );

Future<void> wheelDown(WidgetTester tester) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  final center = tester.getCenter(find.byType(PageView));
  await tester.sendEventToBinding(pointer.hover(center));
  await tester.sendEventToBinding(pointer.scroll(const Offset(0, 120)));
  await tester.pumpAndSettle();
}

/// The day ribbon: a horizontal list of 100px hour columns, wheel-snapped to
/// whole columns so the leading hour label is never sliced in half.
const double kCol = 100;

Widget ribbonHarness(ScrollController sc) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 200,
          child: DesktopScrollWrapper(
            scrollController: sc,
            snapExtent: kCol,
            child: ListView.builder(
              controller: sc,
              scrollDirection: Axis.horizontal,
              itemExtent: kCol,
              itemCount: 200,
              itemBuilder: (_, i) => Center(child: Text('h-$i')),
            ),
          ),
        ),
      ),
    );

Future<void> ribbonWheel(WidgetTester tester, double dy,
    {bool settle = true}) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  final center = tester.getCenter(find.byType(ListView));
  await tester.sendEventToBinding(pointer.hover(center));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  if (settle) await tester.pumpAndSettle();
}

void main() {
  testWidgets('a wheel tick pages when not paused', (tester) async {
    final pc = PageController(initialPage: 5);
    addTearDown(pc.dispose);
    final paused = ValueNotifier(false);
    addTearDown(paused.dispose);

    await tester.pumpWidget(harness(pc, paused));
    await tester.pumpAndSettle();

    await wheelDown(tester);
    expect(pc.page!.round(), 6, reason: 'one tick, one page down');
  });

  testWidgets('the wheel is inert while paused', (tester) async {
    final pc = PageController(initialPage: 5);
    addTearDown(pc.dispose);
    final paused = ValueNotifier(true);
    addTearDown(paused.dispose);

    await tester.pumpWidget(harness(pc, paused));
    await tester.pumpAndSettle();

    await wheelDown(tester);
    expect(pc.page!.round(), 5,
        reason: 'the opened day owns the wheel — the month must not page');

    // Lifting the freeze hands paging back.
    paused.value = false;
    await wheelDown(tester);
    expect(pc.page!.round(), 6);
  });

  group('snapExtent — the ribbon ticks in whole hours', () {
    testWidgets('one notch moves exactly one column, and lands ON the line',
        (tester) async {
      final sc = ScrollController(initialScrollOffset: 5 * kCol);
      addTearDown(sc.dispose);
      await tester.pumpWidget(ribbonHarness(sc));
      await tester.pumpAndSettle();

      await ribbonWheel(tester, 120);
      expect(sc.offset, 6 * kCol);

      await ribbonWheel(tester, -120);
      expect(sc.offset, 5 * kCol);
    });

    testWidgets('rapid notches accumulate instead of restarting', (tester) async {
      final sc = ScrollController(initialScrollOffset: 5 * kCol);
      addTearDown(sc.dispose);
      await tester.pumpWidget(ribbonHarness(sc));
      await tester.pumpAndSettle();

      // Three notches before the glide finishes → three hours, not one.
      await ribbonWheel(tester, 120, settle: false);
      await tester.pump(const Duration(milliseconds: 20));
      await ribbonWheel(tester, 120, settle: false);
      await tester.pump(const Duration(milliseconds: 20));
      await ribbonWheel(tester, 120);
      expect(sc.offset, 8 * kCol);
    });

    testWidgets('an off-grid start is pulled back onto the hour line',
        (tester) async {
      // An edge-pan during a drag can leave the ribbon mid-column; the next
      // notch must land whole, not carry the bad phase forward forever.
      final sc = ScrollController(initialScrollOffset: 5 * kCol + 37);
      addTearDown(sc.dispose);
      await tester.pumpWidget(ribbonHarness(sc));
      await tester.pumpAndSettle();

      await ribbonWheel(tester, 120);
      expect(sc.offset % kCol, 0);
      expect(sc.offset, 6 * kCol);
    });

    testWidgets('it will not scroll past the start of the ribbon',
        (tester) async {
      final sc = ScrollController();
      addTearDown(sc.dispose);
      await tester.pumpWidget(ribbonHarness(sc));
      await tester.pumpAndSettle();

      await ribbonWheel(tester, -120);
      expect(sc.offset, 0);
    });
  });
}
