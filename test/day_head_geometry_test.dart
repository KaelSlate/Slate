import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/interaction/drag_session.dart';
import 'package:slate/core/state/task_state.dart';
import 'package:slate/ui/views/week_tactics_view.dart';
import 'package:slate/ui/widgets/anytime_rail.dart';
import 'package:slate/ui/widgets/day_cell_drop_target.dart';
import 'package:slate/ui/widgets/hover_task_card.dart';

/// The day head is a FIXED height — and the "Anytime" rail depends on it.
///
/// The rail hangs off a constant offset from the cell's top (`settleTopOffset`),
/// on purpose: a boundary that moved with the cell's contents is what caused the
/// old flicker/teleport class of bug. The constant carries one duty in return —
/// the head above it must not change size.
///
/// It did. Week hid its progress ring and month its completion dots on an EMPTY
/// day, so the head lost 17px / 7px and the task list rose under a rail that had
/// not moved. Result: drop the FIRST task into an empty day and the rail sits on
/// top of the card — exactly when there is only one card to sit on. Both heads
/// now reserve the slot.
late TaskState ts;

Future<void> pumpFrames(WidgetTester tester, [int n = 5]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

DateTime _mondayOfThisWeek() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day - (now.weekday - 1));
}

/// The cell whose head shows [dayOfMonth].
Finder cellFor(int dayOfMonth) => find.ancestor(
      of: find.text('$dayOfMonth'),
      matching: find.byType(DayCellDropTarget),
    );

/// The topmost card rendered inside [cell] — real or the honey drop preview.
Rect topCardRect(WidgetTester tester, Finder cell) {
  final cards = find.descendant(of: cell, matching: find.byType(HoverTaskCard));
  expect(cards, findsWidgets, reason: 'the cell should be showing a card');
  var top = double.infinity;
  late Rect best;
  for (final e in cards.evaluate()) {
    final r = tester.getRect(find.byWidget(e.widget));
    if (r.top < top) {
      top = r.top;
      best = r;
    }
  }
  return best;
}

Rect railRect(WidgetTester tester, Finder cell) => tester.getRect(
    find.descendant(of: cell, matching: find.byType(AnytimeRail)));

Widget weekHarness() => MaterialApp(
      home: Scaffold(
        body: WeekTacticsView(
          core: ts.core,
          taskState: ts,
          onDayTap: (_) {},
          onToggleTask: (_) {},
        ),
      ),
    );

Future<RustTaskRef> seed(String title, DateTime day, {int? startMin}) async {
  final d = DateTime(day.year, day.month, day.day);
  await ts.createTask(title, d.millisecondsSinceEpoch);
  var t = ts.tasks.firstWhere((x) => x.title == title);
  if (startMin != null) {
    ts.scheduleAt(t, d, startMin, startMin + 60);
    t = ts.tasks.firstWhere((x) => x.title == title);
  }
  return RustTaskRef(t.id, title);
}

/// Tasks are value objects that the store replaces on every edit; keep the id.
class RustTaskRef {
  final String id;
  final String title;
  RustTaskRef(this.id, this.title);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final temp = Directory.systemTemp.createTempSync('slate_day_head');
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
    for (final t in List.of(ts.tasks)) {
      ts.deleteTask(t);
    }
  });

  tearDown(() {
    DragSession.instance.debugReset();
    for (final t in List.of(ts.tasks)) {
      ts.deleteTask(t);
    }
  });

  testWidgets(
      'the Anytime rail never sits on the card it is offered next to — '
      'empty day or not', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final monday = _mondayOfThisWeek();
    final source = monday; // holds the card we drag
    final busy = monday.add(const Duration(days: 2)); // already has a task
    final empty = monday.add(const Duration(days: 3)); // holds nothing

    final dragged = await seed('drag me', source, startMin: 900); // 15:00
    await seed('already here', busy, startMin: 540); // 09:00

    await tester.pumpWidget(weekHarness());
    await pumpFrames(tester);

    final task = ts.tasks.firstWhere((t) => t.id == dragged.id);
    final payload = DragPayload(
      task: task,
      kind: DragSourceKind.dayCellCard,
      sourceGlobalRect: const Rect.fromLTWH(0, 0, 120, 34),
      grabOffset: Offset.zero,
      sourceDay: source,
    );

    final tops = <int, double>{};
    for (final target in [empty, busy]) {
      final cell = cellFor(target.day);
      expect(cell, findsOneWidget, reason: 'cell for ${target.day}');
      final cellRect = tester.getRect(cell);

      // Hover the cell BODY — that is when the rail appears and the list steps
      // aside to make room for it.
      final at = Offset(cellRect.center.dx, cellRect.top + 200);
      DragSession.instance.begin(payload, at);
      DragSession.instance.update(at);
      await pumpFrames(tester); // the 180ms step-aside has to finish

      final rail = railRect(tester, cellFor(target.day));
      final card = topCardRect(tester, cellFor(target.day));

      expect(rail.bottom, lessThanOrEqualTo(card.top),
          reason: 'day ${target.day}: the rail overlaps the first card by '
              '${(rail.bottom - card.top).toStringAsFixed(1)}px');
      tops[target.day] = card.top - cellRect.top;

      DragSession.instance.debugReset();
      await pumpFrames(tester);
    }

    // Same head everywhere: the empty day's list starts exactly where the busy
    // day's does. This is the invariant `settleTopOffset` is allowed to assume.
    expect(tops[empty.day], closeTo(tops[busy.day]!, 0.5),
        reason: 'the day head must be the same height whatever the day holds');
  });
}
