import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/slate_core_bridge.dart';
import 'package:slate/core/interaction/drag_session.dart';
import 'package:slate/core/state/task_state.dart';
import 'package:slate/ui/widgets/day_cell_drop_target.dart';
import 'package:slate/ui/widgets/drop_future.dart';

/// The week/month day cell as a drop target, against the REAL engine DLL.
///
/// You AIM AT THE GROUP: above the scheduled group's end = keep the time, below
/// it = drop into the unscheduled pool. The boundary is measured from the REAL
/// tasks on the day (never the laid-out widgets), so inserting the drop preview
/// can't move it — that feedback loop was the flicker/teleport bug.
late TaskState ts;

/// Cell geometry — deliberately fixed so the split maths is checkable by hand.
const double cellTop = 100;
const double cellLeft = 50;
const double cellW = 200;
const double cellH = 600;
const double settleTop = 96;
const double rowH = 38;

/// Global Y of the boundary for a day holding [timedCount] timed tasks. An empty
/// scheduled group still reserves ONE row so "keep the time" stays aimable.
double splitFor(int timedCount) =>
    cellTop + settleTop + (timedCount == 0 ? 1 : timedCount) * rowH;

/// Each test gets its OWN day so the timed count — and therefore the boundary —
/// is exact and never depends on what another test left behind.
DateTime day(int n) => DateTime(2026, 8, n);

Widget cellHarness({
  required DateTime date,
  double? dividerAt,
  bool splitTime = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          Positioned(
            left: cellLeft,
            top: cellTop,
            width: cellW,
            height: cellH,
            child: DayCellDropTarget(
              date: date,
              taskState: ts,
              settleTopOffset: settleTop,
              rowHeight: rowH,
              splitTime: splitTime,
              builder: (dividerKey) => Stack(
                children: [
                  const SizedBox.expand(),
                  if (dividerAt != null)
                    Positioned(
                      top: dividerAt,
                      left: 0,
                      right: 0,
                      child: SizedBox(key: dividerKey, height: 1),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

DragPayload payloadFor(RustTask t, DateTime sourceDay) => DragPayload(
      task: t,
      kind: DragSourceKind.dayCellCard,
      sourceGlobalRect: const Rect.fromLTWH(0, 0, 100, 30),
      grabOffset: Offset.zero,
      sourceDay: sourceDay,
    );

/// Drives the real session: lift, move to [y], release over the cell.
Future<void> dragTo(WidgetTester tester, DragPayload p, double y) async {
  DragSession.instance.begin(p, const Offset(10, 10));
  DragSession.instance.update(Offset(cellLeft + cellW / 2, y));
  await tester.pump();
  DragSession.instance.drop();
  await tester.pump();
}

String? modeAt(DragPayload p, double y) {
  DragSession.instance.update(Offset(cellLeft + cellW / 2, y));
  return DragSession.instance.hover.value?.cellMode;
}

Future<RustTask> makeTask(String title, DateTime d, {int? startMin}) async {
  await ts.createTask(
      title, DateTime(d.year, d.month, d.day).millisecondsSinceEpoch);
  var t = ts.tasks.firstWhere((t) => t.title == title);
  if (startMin != null) {
    ts.scheduleAt(t, d, startMin, startMin + 60);
    t = ts.tasks.firstWhere((t) => t.title == title);
  }
  return t;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final temp = Directory.systemTemp.createTempSync('slate_cell_drop');
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
  });

  tearDown(() => DragSession.instance.debugReset());

  testWidgets('cross-day drop above the boundary keeps the time', (tester) async {
    final src = day(4), dst = day(6); // dst holds nothing → boundary at +1 row
    final t = await makeTask('keep me', src, startMin: 570); // 09:30
    await tester.pumpWidget(cellHarness(date: dst));
    await tester.pump();

    await dragTo(tester, payloadFor(t, src), splitFor(0) - 10);
    final after = ts.tasks.firstWhere((x) => x.id == t.id);

    expect(after.startTime, 570, reason: 'keep holds the time verbatim');
    expect(after.endTime, 630);
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, dst.day,
        reason: 'and still moves to the target day');
    expect(after.isInbox, isFalse);
  });

  testWidgets('cross-day drop below the boundary drops the time', (tester) async {
    final src = day(4), dst = day(7);
    final t = await makeTask('clear me', src, startMin: 570);
    await tester.pumpWidget(cellHarness(date: dst));
    await tester.pump();

    await dragTo(tester, payloadFor(t, src), splitFor(0) + 40);
    final after = ts.tasks.firstWhere((x) => x.id == t.id);

    expect(after.startTime, isNull);
    expect(after.endTime, isNull);
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, dst.day);
  });

  testWidgets('an untimed task is whole — one destination at any height',
      (tester) async {
    final src = day(4), dst = day(8);
    final t = await makeTask('no time to start with', src);
    await tester.pumpWidget(cellHarness(date: dst));
    await tester.pump();

    final p = payloadFor(t, src);
    DragSession.instance.begin(p, const Offset(10, 10));
    expect(modeAt(p, splitFor(0) - 40), 'whole', reason: 'high: no split');
    expect(modeAt(p, splitFor(0) + 200), 'whole', reason: 'low: same');

    DragSession.instance.update(Offset(cellLeft + cellW / 2, splitFor(0) + 200));
    await tester.pump();
    DragSession.instance.drop();
    await tester.pump();

    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, isNull, reason: 'it never had one');
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, dst.day);
  });

  testWidgets('same-day keep is a no-op', (tester) async {
    final d = day(9);
    final t = await makeTask('already here', d, startMin: 570);
    await tester.pumpWidget(cellHarness(date: d));
    await tester.pump();

    // The day now holds 1 timed task → the boundary sits one row lower.
    final p = payloadFor(t, d);
    DragSession.instance.begin(p, const Offset(10, 10));
    expect(modeAt(p, splitFor(1) - 10), 'reject');

    DragSession.instance.drop();
    await tester.pump();

    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, 570, reason: 'nothing moved');
  });

  testWidgets('the preview SHOWS the future — card with time, or without',
      (tester) async {
    final src = day(4), dst = day(10);
    final t = await makeTask('show me', src, startMin: 570);
    await tester.pumpWidget(cellHarness(date: dst));
    await tester.pump();

    final p = payloadFor(t, src);
    DragSession.instance.begin(p, const Offset(10, 10));

    // Above the boundary → keep: the projected card carries its time.
    expect(modeAt(p, splitFor(0) - 10), 'keep');
    final keep = DropFuture.forDate(dst)!;
    expect(keep.keepsTime, isTrue);
    expect(keep.projected.startTime, 570, reason: 'the card lands WITH 09:30');

    // Below → clear: the projected card has no time, and no badge says so —
    // the absence of the time on the card IS the message.
    expect(modeAt(p, splitFor(0) + 40), 'clear');
    final clear = DropFuture.forDate(dst)!;
    expect(clear.keepsTime, isFalse);
    expect(clear.projected.startTime, isNull);
  });

  testWidgets('you aim AT THE GROUP: the boundary follows the real timed count',
      (tester) async {
    // The whole point: the boundary sits where the scheduled group actually
    // ends, so pointing at the unscheduled tasks means "unscheduled".
    final src = day(4), dst = day(11);
    await makeTask('dst timed A', dst, startMin: 540);
    await makeTask('dst timed B', dst, startMin: 600);
    final t = await makeTask('aim me', src, startMin: 570);

    await tester.pumpWidget(cellHarness(date: dst));
    await tester.pump();
    final p = payloadFor(t, src);
    DragSession.instance.begin(p, const Offset(10, 10));

    // 2 real timed rows → boundary two rows down, NOT one.
    expect(modeAt(p, splitFor(2) - 10), 'keep',
        reason: 'still inside the scheduled group');
    expect(modeAt(p, splitFor(2) + 10), 'clear',
        reason: 'past the scheduled group = the pool');
    // The one-row boundary of an empty day would have called this 'clear'.
    expect(modeAt(p, splitFor(1) + 10), 'keep',
        reason: 'the boundary MOVED with the real group, as the eye expects');
  });

  testWidgets('the boundary ignores the drawn divider (no feedback loop)',
      (tester) async {
    // Reading the live divider is what let the preview move the boundary, flip
    // the decision, and flicker. Same day, wildly different divider positions →
    // identical decisions.
    final src = day(4), dst = day(12);
    final t = await makeTask('stable', src, startMin: 570);

    for (final dividerAt in [null, 120.0, 500.0]) {
      await tester.pumpWidget(cellHarness(date: dst, dividerAt: dividerAt));
      await tester.pump();
      final p = payloadFor(t, src);
      DragSession.instance.begin(p, const Offset(10, 10));
      expect(modeAt(p, splitFor(0) - 10), 'keep', reason: 'divider=$dividerAt');
      expect(modeAt(p, splitFor(0) + 40), 'clear', reason: 'divider=$dividerAt');
      DragSession.instance.debugReset();
    }
  });

  testWidgets('month (splitTime off): a drop always keeps the time',
      (tester) async {
    // A month cell shows two rows — no honest room to aim at a group.
    final src = day(4), dst = day(13);
    final t = await makeTask('month drop', src, startMin: 570);
    await tester.pumpWidget(cellHarness(date: dst, splitTime: false));
    await tester.pump();

    final p = payloadFor(t, src);
    DragSession.instance.begin(p, const Offset(10, 10));
    expect(modeAt(p, splitFor(0) - 10), 'keep', reason: 'high in the cell');
    expect(modeAt(p, splitFor(0) + 300), 'keep',
        reason: 'and low too — there is no clear zone at all');

    DragSession.instance.drop();
    await tester.pump();
    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, 570, reason: 'the time survives a month drop');
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, dst.day);
  });

  test('EVIDENCE (bug 7): deleting refreshes the day notifier', () async {
    final d = DateTime(2026, 9, 10);
    final ms = d.millisecondsSinceEpoch;
    await ts.createTask('m-a', ms);
    await ts.createTask('m-b', ms);
    final notifier = ts.tasksForDateNotifier(ms);
    final mine = notifier.value.where((t) => t.title.startsWith('m-')).toList();
    expect(mine.length, 2, reason: 'both created on the day');

    final a = ts.tasks.firstWhere((t) => t.title == 'm-a');
    ts.deleteTask(a);
    expect(notifier.value.any((t) => t.title == 'm-a'), isFalse,
        reason: 'the deleted one is gone from the notifier');
    expect(notifier.value.any((t) => t.title == 'm-b'), isTrue,
        reason: 'the OTHER one survives (bug 7: it wrongly vanished)');
  });

  testWidgets('the preview card RENDERS the future — time shown, or gone',
      (tester) async {
    final t = await makeTask('render me', day(4), startMin: 570); // 09:30
    final p = payloadFor(t, day(4));
    DragSession.instance.begin(p, const Offset(10, 10));

    // Keep: the real card, carrying its time — the badge/grey wash is gone; the
    // time ON the card is the whole message.
    final keep = DropFuture(t, true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: keep.card())));
    await tester.pump();
    expect(find.text('render me'), findsOneWidget);
    expect(find.text('09:30'), findsOneWidget, reason: 'lands WITH its time');

    // Clear: the same card, no time — absence is the message, no "No time" badge.
    final cleared = RustTask(
      id: t.id, title: t.title, isCompleted: t.isCompleted,
      createdAt: t.createdAt, startTime: null, endTime: null,
      priority: t.priority, tags: t.tags,
    );
    await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: DropFuture(cleared, false).card())));
    await tester.pump();
    expect(find.text('render me'), findsOneWidget);
    expect(find.text('09:30'), findsNothing, reason: 'the time is gone');
  });
}
