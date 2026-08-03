import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/slate_core_bridge.dart';
import 'package:slate/core/interaction/drag_session.dart';
import 'package:slate/core/interaction/timeline_math.dart';
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

  group('the ribbon opens on a whole hour, the same way every time', () {
    /// The ribbon's live scroll offset — the number the whole complaint is
    /// about. Hour columns are 100px, so a hour-aligned view is offset % 100 == 0
    /// and anything else slices the leading hour label through its digits.
    double ribbonOffset(WidgetTester tester) {
      for (final e in find.byType(Scrollable).evaluate()) {
        final st = (e as StatefulElement).state as ScrollableState;
        if (st.position.axis == Axis.horizontal) return st.position.pixels;
      }
      fail('the ribbon has no horizontal scrollable');
    }

    /// Offset that puts the column holding [minuteOfDay] flush at the left edge.
    double columnAt(int minuteOfDay) =>
        (TimelineMath.hourCenter + minuteOfDay ~/ 60) * TimelineMath.colWidth;

    testWidgets('a day with tasks opens on the earliest hour, minus lead-in',
        (tester) async {
      for (final t in List.of(ts.tasks)) {
        ts.deleteTask(t);
      }
      await ts.createTask('anchor', day.millisecondsSinceEpoch);
      ts.updateTask(
          taskByTitle('anchor').copyWith(startTime: 495, endTime: 540)); // 08:15
      await ts.createTask('later', day.millisecondsSinceEpoch);
      ts.updateTask(
          taskByTitle('later').copyWith(startTime: 1140, endTime: 1200));

      await pumpHarness(tester);
      // 08:15 → the 08:00 column, one hour of lead-in → 07:00 at the left edge.
      expect(ribbonOffset(tester), columnAt(7 * 60));
      expect(ribbonOffset(tester) % TimelineMath.colWidth, 0);

      // Re-enter: identical framing. The rule reads the earliest task and
      // nothing else.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 50));
      await pumpHarness(tester);
      expect(ribbonOffset(tester), columnAt(7 * 60));

      // A task added ELSEWHERE in the day must not re-aim the morning — the old
      // "densest viewport window" search moved the whole view for this.
      await ts.createTask('noise', day.millisecondsSinceEpoch);
      ts.updateTask(
          taskByTitle('noise').copyWith(startTime: 1320, endTime: 1380));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 50));
      await pumpHarness(tester);
      expect(ribbonOffset(tester), columnAt(7 * 60),
          reason: 'a task at 22:00 has no business re-aiming the morning');

      await teardownHarness(tester);
    });

    testWidgets('an empty day opens at 08:00', (tester) async {
      for (final t in List.of(ts.tasks)) {
        ts.deleteTask(t);
      }
      await pumpHarness(tester);
      expect(ribbonOffset(tester), columnAt(8 * 60),
          reason: 'an empty day looks the same wherever you meet it');
      await teardownHarness(tester);
    });
  });

  testWidgets(
      'the ghost lands where it promised, on a layout the packer made sticky',
      (tester) async {
    // THE regression, end to end.
    //
    // Setup builds a perfectly ordinary — and mirrored — layout: a short block
    // exists first and takes row 0; the long block added around it is pushed to
    // row 1. A pref-less repack of the same two spans would come out the other
    // way round (long→0, short→1), and that is precisely what the ghost used to
    // compute. It then measured room on the wrong row, drew itself over the long
    // block, and the drop landed a row away from where the preview had flown.
    for (final t in List.of(ts.tasks)) {
      ts.deleteTask(t);
    }
    await ts.createTask('short one', day.millisecondsSinceEpoch);
    ts.updateTask(
        taskByTitle('short one').copyWith(startTime: 600, endTime: 660));
    await pumpHarness(tester); // packed alone → row 0, and it STAYS there

    await ts.createTask('long one', day.millisecondsSinceEpoch);
    ts.updateTask(
        taskByTitle('long one').copyWith(startTime: 480, endTime: 720));
    await ts.createTask('incoming', day.millisecondsSinceEpoch); // untimed
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }

    final shortRect = tester.getRect(blockFor('short one'));
    final longRect = tester.getRect(blockFor('long one'));
    expect(longRect.top, greaterThan(shortRect.top),
        reason: 'setup must produce the mirrored layout, or this proves nothing');

    // Row 0's top in global coordinates, read off the block that holds it.
    final ribbonTop = shortRect.top - TimelineMath.topPad;

    // Drag the untimed card out of the pane onto 11:30, pointing at ROW 0 —
    // which is free there (the short block ends at 11:00) but which the old
    // ghost believed the long block occupied.
    final card = find.widgetWithText(HoverTaskCard, 'incoming');
    expect(card, findsOneWidget);
    final from = tester.getCenter(card);
    // x(minute) derived from a block whose minute is known: 08:00 at longRect.left.
    final targetX =
        longRect.left + (690 - 480) / 60.0 * TimelineMath.colWidth;
    final targetY = ribbonTop + TimelineMath.topPad + TimelineMath.blockH / 2;

    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: from);
    await g.down(from);
    await tester.pump();
    await g.moveBy(const Offset(0, 8)); // lift
    await tester.pump();
    await g.moveTo(Offset(targetX, targetY));
    await tester.pump(const Duration(milliseconds: 50));

    final hover = DragSession.instance.hover.value;
    expect(hover?.zoneId, 'ribbon');
    final promisedTop = ribbonTop + hover!.ghostTop!;

    await g.up();
    await tester.pump(const Duration(milliseconds: 250)); // settle
    await tester.pump(const Duration(milliseconds: 250)); // fade
    await tester.pump(const Duration(milliseconds: 250));

    final landed = tester.getRect(blockFor('incoming'));
    expect(landed.top, closeTo(promisedTop, 0.5),
        reason: 'the block must appear exactly where the ghost stood — '
            'off by ${(landed.top - promisedTop).abs().toStringAsFixed(1)}px');

    // And it took a free row rather than shoving anyone off theirs.
    expect(tester.getRect(blockFor('short one')).top, closeTo(shortRect.top, 0.5),
        reason: 'a drop asks for a row, it does not evict one');
    expect(tester.getRect(blockFor('long one')).top, closeTo(longRect.top, 0.5),
        reason: 'a drop asks for a row, it does not evict one');

    await teardownHarness(tester);
  });
}
