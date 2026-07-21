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
}
