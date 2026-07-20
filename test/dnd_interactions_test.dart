import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/slate_core_bridge.dart';
import 'package:slate/core/interaction/drag_session.dart';
import 'package:slate/core/state/task_state.dart';
import 'package:slate/ui/overlays/drag_preview_layer.dart';
import 'package:slate/ui/views/day_flow_view.dart';
import 'package:slate/ui/widgets/hover_task_card.dart';

/// Headless interaction harness: drives the REAL day view with synthetic
/// mouse gestures — resize, block move, pane drops. Mirrors PulseLayer's
/// root-Listener routing + preview layer wiring.
late TaskState ts;
late DateTime day; // tomorrow — keeps today's stub/sample tasks out of frame

Finder blockFinder() =>
    find.byWidgetPredicate((w) => w.runtimeType.toString() == '_TaskBlock');

/// The timeline block for a specific task (titles also appear in the left
/// list — ancestor filtering keeps only the ribbon block).
Finder blockFor(String title) => find.ancestor(
      of: find.text(title),
      matching: blockFinder(),
    );

Widget harness() {
  return MaterialApp(
    home: Scaffold(
      body: Listener(
        onPointerMove: (e) {
          if (DragSession.instance.isActive) {
            DragSession.instance.update(e.position);
          }
        },
        onPointerUp: (e) {
          if (DragSession.instance.isActive) DragSession.instance.drop();
        },
        onPointerCancel: (e) {
          if (DragSession.instance.isActive) DragSession.instance.cancel();
        },
        child: Stack(
          children: [
            DayFlowView(
              selectedDate: day,
              core: ts.core,
              taskState: ts,
              onToggleTask: (_) {},
            ),
            const DragPreviewLayer(),
          ],
        ),
      ),
    ),
  );
}

RustTask taskByTitle(String title) =>
    ts.tasks.firstWhere((t) => t.title == title);

Future<void> pumpHarness(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(harness());
  // ribbonReady post-frame + day-open jump + entrance animations
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

Future<void> teardownHarness(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 50));
  DragSession.instance.debugReset();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final temp = Directory.systemTemp.createTempSync('slate_test');
    Directory('${temp.path}\\slate_data').createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => temp.path,
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        if (call.method == 'read') return '0' * 64;
        if (call.method == 'readAll') return <String, String>{};
        return null;
      },
    );

    ts = TaskState();
    while (!ts.loaded) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }

    final now = DateTime.now();
    day = DateTime(now.year, now.month, now.day + 1);
  });

  testWidgets('resize: dragging the right edge extends endTime (15-min snap)',
      (tester) async {
    await ts.createTask('resize me', day.millisecondsSinceEpoch);
    ts.updateTask(
        taskByTitle('resize me').copyWith(startTime: 720, endTime: 780));

    await pumpHarness(tester);
    expect(blockFor('resize me'), findsOneWidget);
    final rect = tester.getRect(blockFor('resize me'));

    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset(rect.right - 4, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 200)); // hover → grip

    await g.down(Offset(rect.right - 4, rect.center.dy));
    await tester.pump();
    await g.moveBy(const Offset(50, 0)); // +30 min
    await tester.pump(const Duration(milliseconds: 50));
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));

    final t = taskByTitle('resize me');
    expect(t.startTime, 720);
    expect(t.endTime, 810);
    await teardownHarness(tester);
  });

  testWidgets('resize: left edge moves start, Esc cancels', (tester) async {
    await ts.createTask('resize esc', day.millisecondsSinceEpoch);
    ts.updateTask(
        taskByTitle('resize esc').copyWith(startTime: 600, endTime: 660));

    await pumpHarness(tester);
    final rect = tester.getRect(blockFor('resize esc'));

    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset(rect.left + 4, rect.center.dy));
    await tester.pump(const Duration(milliseconds: 100));
    await g.down(Offset(rect.left + 4, rect.center.dy));
    await tester.pump();
    await g.moveBy(const Offset(-50, 0)); // start −30 min (live preview)
    await tester.pump(const Duration(milliseconds: 50));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape); // cancel
    await g.up();
    await tester.pump(const Duration(milliseconds: 100));

    final t = taskByTitle('resize esc');
    expect(t.startTime, 600, reason: 'Esc must cancel the resize');
    expect(t.endTime, 660);
    await teardownHarness(tester);
  });

  testWidgets('block move: drag along ribbon shifts start, keeps duration',
      (tester) async {
    await ts.createTask('move me', day.millisecondsSinceEpoch);
    ts.updateTask(
        taskByTitle('move me').copyWith(startTime: 720, endTime: 780));

    await pumpHarness(tester);
    final rect = tester.getRect(blockFor('move me'));
    final start = rect.center;

    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: start);
    await tester.pump(const Duration(milliseconds: 50));
    await g.down(start);
    await tester.pump();
    await g.moveBy(const Offset(6, 0)); // cross the 5px lift threshold
    await tester.pump();
    expect(DragSession.instance.isActive, isTrue,
        reason: 'drag must lift after threshold');
    await g.moveBy(const Offset(94, 0)); // total +100px = +60 min
    await tester.pump(const Duration(milliseconds: 50));
    expect(DragSession.instance.hover.value?.zoneId, 'ribbon');
    await g.up();
    // settle (200ms) + corpse fade (130ms) + a spare frame
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 200));

    final t = taskByTitle('move me');
    expect(t.startTime, 780, reason: '+100px along the ribbon = +60 min');
    expect(t.endTime, 840, reason: 'duration preserved');
    expect(DragSession.instance.phase, DragPhase.idle);
    await teardownHarness(tester);
  });

  testWidgets('block → planning pane = unschedule', (tester) async {
    await ts.createTask('unschedule me', day.millisecondsSinceEpoch);
    ts.updateTask(
        taskByTitle('unschedule me').copyWith(startTime: 720, endTime: 780));

    await pumpHarness(tester);
    final rect = tester.getRect(blockFor('unschedule me'));

    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: rect.center);
    await g.down(rect.center);
    await tester.pump();
    await g.moveBy(const Offset(0, 6));
    await tester.pump();
    await g.moveTo(const Offset(200, 620)); // bottom half of the left pane = clear
    await tester.pump(const Duration(milliseconds: 50));
    await g.up();
    await tester.pump(const Duration(milliseconds: 350)); // settle 300
    await tester.pump(const Duration(milliseconds: 250)); // fade 130

    final t = taskByTitle('unschedule me');
    expect(t.startTime, isNull, reason: 'pane drop clears the slot');
    expect(t.endTime, isNull);
    await teardownHarness(tester);
  });

  testWidgets(
      'scheduled list card → pane = unschedule; unscheduled one springs back',
      (tester) async {
    await ts.createTask('cardpane', day.millisecondsSinceEpoch);
    ts.updateTask(
        taskByTitle('cardpane').copyWith(startTime: 540, endTime: 600));

    await pumpHarness(tester);
    final card = find.widgetWithText(HoverTaskCard, 'cardpane');
    expect(card, findsOneWidget);

    final c = tester.getCenter(card);
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: c);
    await g.down(c);
    await tester.pump();
    await g.moveBy(const Offset(0, 8));
    await tester.pump();
    // Drop anywhere in the pane = clear the time (it is one ANYTIME place).
    // The top half means "keep scheduled" (a no-op that springs back).
    await g.moveTo(Offset(c.dx, 620));
    await tester.pump(const Duration(milliseconds: 50));
    await g.up();
    await tester.pump(const Duration(milliseconds: 100)); // refine frame
    await tester.pump(const Duration(milliseconds: 350)); // settle 300
    await tester.pump(const Duration(milliseconds: 250)); // fade 130

    var t = taskByTitle('cardpane');
    expect(t.startTime, isNull, reason: 'scheduled card → TO-SCHEDULE clears time');
    expect(t.endTime, isNull);

    // Reverse direction is forbidden: an unscheduled card has nothing to
    // clear — the pane rejects it and the drag springs back.
    final c2 = tester.getCenter(find.widgetWithText(HoverTaskCard, 'cardpane'));
    await g.down(c2);
    await tester.pump();
    await g.moveBy(const Offset(0, 8));
    await tester.pump();
    await g.up();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));

    t = taskByTitle('cardpane');
    expect(t.startTime, isNull);
    expect(DragSession.instance.phase, DragPhase.idle);
    await teardownHarness(tester);
  });
}
