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
/// Aiming at a group is retired. The BODY of the cell means "move it here, keep
/// the hour" — the calendar default, so nothing can surprise a new user. The
/// "Anytime" RAIL at the head of the task area, under the day's own head, means
/// "clear the time". The rail is a constant offset from the cell's TOP, so
/// unlike every boundary before it, the drop preview cannot move the line that
/// decides the preview.
late TaskState ts;

/// Cell geometry — deliberately fixed so the maths is checkable by hand.
const double cellTop = 100;
const double cellLeft = 50;
const double cellW = 200;
const double cellH = 600;
const double settleTop = 96;
const double railH = 22;

/// Global Y of the rail's top edge — the head of the task area, right under the
/// day's own head. One number, whatever the day holds.
double railTop([double h = railH]) => cellTop + settleTop;

/// A Y that is unambiguously the cell BODY (below the rail and its slop).
double bodyY([double h = railH]) => railTop(h) + h + 40;

/// Each test gets its OWN day so nothing depends on what another left behind.
DateTime day(int n) => DateTime(2026, 8, n);

Widget cellHarness({
  required DateTime date,
  double? dividerAt,
  double rail = railH,
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
              railHeight: rail,
              builder: (dividerKey, railInset) => Stack(
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

  testWidgets('the body keeps the time — the calendar default', (tester) async {
    final src = day(4), dst = day(6);
    final t = await makeTask('keep me', src, startMin: 570); // 09:30
    await tester.pumpWidget(cellHarness(date: dst));
    await tester.pump();

    await dragTo(tester, payloadFor(t, src), bodyY());
    final after = ts.tasks.firstWhere((x) => x.id == t.id);

    expect(after.startTime, 570, reason: 'the hour survives verbatim');
    expect(after.endTime, 630);
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, dst.day,
        reason: 'and it still moves to the target day');
    expect(after.isInbox, isFalse);
  });

  testWidgets('the Anytime rail clears the time', (tester) async {
    final src = day(4), dst = day(7);
    final t = await makeTask('clear me', src, startMin: 570);
    await tester.pumpWidget(cellHarness(date: dst));
    await tester.pump();

    await dragTo(tester, payloadFor(t, src), railTop() + 8);
    final after = ts.tasks.firstWhere((x) => x.id == t.id);

    expect(after.startTime, isNull);
    expect(after.endTime, isNull);
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, dst.day);
  });

  testWidgets('THE POINT: the rail is in the same place whatever the day holds',
      (tester) async {
    // Every previous boundary moved with the cell's contents, so the same
    // gesture meant different things on an empty day, a day of only-timed
    // tasks, and a full one. That is the bug class this retires.
    final src = day(4);
    final empty = day(14);
    final onlyTimed = day(15);
    final mixed = day(16);

    await makeTask('t A', onlyTimed, startMin: 540);
    await makeTask('t B', onlyTimed, startMin: 600);
    await makeTask('m A', mixed, startMin: 540);
    await makeTask('m B', mixed); // untimed
    final t = await makeTask('aim me', src, startMin: 570);

    for (final dst in [empty, onlyTimed, mixed]) {
      await tester.pumpWidget(cellHarness(date: dst));
      await tester.pump();
      final p = payloadFor(t, src);
      DragSession.instance.begin(p, const Offset(10, 10));
      expect(modeAt(p, bodyY()), 'keep', reason: 'body on ${dst.day}');
      expect(modeAt(p, railTop() + 8), 'clear', reason: 'rail on ${dst.day}');
      DragSession.instance.debugReset();
    }
  });

  testWidgets('an untimed task is whole — one destination at any height',
      (tester) async {
    final src = day(4), dst = day(8);
    final t = await makeTask('no time to start with', src);
    await tester.pumpWidget(cellHarness(date: dst));
    await tester.pump();

    final p = payloadFor(t, src);
    DragSession.instance.begin(p, const Offset(10, 10));
    expect(modeAt(p, bodyY()), 'whole', reason: 'body: no choice');
    expect(modeAt(p, railTop() + 8), 'whole',
        reason: 'and no rail either — there is nothing to choose');

    DragSession.instance.update(Offset(cellLeft + cellW / 2, railTop() + 8));
    await tester.pump();
    DragSession.instance.drop();
    await tester.pump();

    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, isNull, reason: 'it never had one');
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, dst.day);
  });

  testWidgets('same day: the body is a no-op, the rail still un-schedules',
      (tester) async {
    final d = day(9);
    final t = await makeTask('already here', d, startMin: 570);
    await tester.pumpWidget(cellHarness(date: d));
    await tester.pump();

    final p = payloadFor(t, d);
    DragSession.instance.begin(p, const Offset(10, 10));
    expect(modeAt(p, bodyY()), 'reject', reason: 'nothing would change');
    expect(modeAt(p, railTop() + 8), 'clear',
        reason: 're-filing INTO the pool on the same day is the whole point');

    DragSession.instance.drop();
    await tester.pump();
    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, isNull, reason: 'released on the rail');
  });

  testWidgets('the preview SHOWS the future — card with time, or without',
      (tester) async {
    final src = day(4), dst = day(10);
    final t = await makeTask('show me', src, startMin: 570);
    await tester.pumpWidget(cellHarness(date: dst));
    await tester.pump();

    final p = payloadFor(t, src);
    DragSession.instance.begin(p, const Offset(10, 10));

    expect(modeAt(p, bodyY()), 'keep');
    final keep = DropFuture.forDate(dst)!;
    expect(keep.keepsTime, isTrue);
    expect(keep.projected.startTime, 570, reason: 'the card lands WITH 09:30');

    // On the rail → the projected card has no time, and no badge says so — the
    // absence of the time on the card IS the message.
    expect(modeAt(p, railTop() + 8), 'clear');
    final clear = DropFuture.forDate(dst)!;
    expect(clear.keepsTime, isFalse);
    expect(clear.projected.startTime, isNull);
  });

  testWidgets('the rail ignores the drawn divider (no feedback loop)',
      (tester) async {
    // Reading the live divider is what let the preview move the boundary, flip
    // the decision, and flicker. Wildly different divider positions → identical
    // decisions.
    final src = day(4), dst = day(12);
    final t = await makeTask('stable', src, startMin: 570);

    for (final dividerAt in [null, 120.0, 500.0]) {
      await tester.pumpWidget(cellHarness(date: dst, dividerAt: dividerAt));
      await tester.pump();
      final p = payloadFor(t, src);
      DragSession.instance.begin(p, const Offset(10, 10));
      expect(modeAt(p, bodyY()), 'keep', reason: 'divider=$dividerAt');
      expect(modeAt(p, railTop() + 8), 'clear', reason: 'divider=$dividerAt');
      DragSession.instance.debugReset();
    }
  });

  testWidgets('month: a shorter rail, identical rule', (tester) async {
    // Month is no longer a special case — it gets the same object, just 15px.
    final src = day(4), dst = day(13);
    final t = await makeTask('month drop', src, startMin: 570);
    await tester.pumpWidget(cellHarness(date: dst, rail: 15));
    await tester.pump();

    final p = payloadFor(t, src);
    DragSession.instance.begin(p, const Offset(10, 10));
    expect(modeAt(p, bodyY(15)), 'keep');
    expect(modeAt(p, railTop(15) + 5), 'clear');

    DragSession.instance.drop();
    await tester.pump();
    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, isNull, reason: 'released on the month rail');
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

    final keep = DropFuture(t, true);
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: keep.card())));
    await tester.pump();
    expect(find.text('render me'), findsOneWidget);
    expect(find.text('09:30'), findsOneWidget, reason: 'lands WITH its time');

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
