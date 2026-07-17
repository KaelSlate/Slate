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
/// The cell splits at its timed/untimed divider: above = keep the time, below =
/// drop it. An untimed task has one destination, so it gets no split at all.
/// This zone carried the whole cross-day reschedule rule and had no tests.
late TaskState ts;
late DateTime tue;
late DateTime thu;

/// Cell geometry — deliberately fixed so split maths is checkable by hand.
const double cellTop = 100;
const double cellLeft = 50;
const double cellW = 200;
const double cellH = 600;
const double settleTop = 96;

/// [dividerAt] null → the cell draws no divider (only one group present), which
/// is the path that forces the geometric fallback.
Widget cellHarness({required DateTime date, double? dividerAt}) {
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

Future<RustTask> makeTask(String title, DateTime day, {int? startMin}) async {
  await ts.createTask(title, DateTime(day.year, day.month, day.day)
      .millisecondsSinceEpoch);
  var t = ts.tasks.firstWhere((t) => t.title == title);
  if (startMin != null) {
    ts.scheduleAt(t, day, startMin, startMin + 60);
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
    // A fixed Tue/Thu pair well clear of today, so nothing else shares the day.
    tue = DateTime(2026, 8, 4);
    thu = DateTime(2026, 8, 6);
  });

  tearDown(() => DragSession.instance.debugReset());

  testWidgets('cross-day drop above the split keeps the time', (tester) async {
    final t = await makeTask('keep me', tue, startMin: 570); // 09:30
    await tester.pumpWidget(cellHarness(date: thu, dividerAt: 300));
    await tester.pump();

    await dragTo(tester, payloadFor(t, tue), cellTop + 200); // above 300
    final after = ts.tasks.firstWhere((x) => x.id == t.id);

    expect(after.startTime, 570, reason: 'keep holds the time verbatim');
    expect(after.endTime, 630);
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, thu.day,
        reason: 'and still moves to the target day');
    expect(after.isInbox, isFalse);
  });

  testWidgets('cross-day drop below the split drops the time', (tester) async {
    final t = await makeTask('clear me', tue, startMin: 570);
    await tester.pumpWidget(cellHarness(date: thu, dividerAt: 300));
    await tester.pump();

    await dragTo(tester, payloadFor(t, tue), cellTop + 400); // below 300
    final after = ts.tasks.firstWhere((x) => x.id == t.id);

    expect(after.startTime, isNull);
    expect(after.endTime, isNull);
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, thu.day);
  });

  testWidgets('an untimed task is whole — one destination at any height',
      (tester) async {
    final t = await makeTask('no time to start with', tue);
    await tester.pumpWidget(cellHarness(date: thu, dividerAt: 300));
    await tester.pump();

    final p = payloadFor(t, tue);
    DragSession.instance.begin(p, const Offset(10, 10));
    expect(modeAt(p, cellTop + 120), 'whole', reason: 'top half: no split');
    expect(modeAt(p, cellTop + 500), 'whole', reason: 'bottom half: same');
    expect(DragSession.instance.hover.value?.badgeText, isNull,
        reason: 'no choice to explain — narrating it would be noise');

    DragSession.instance.update(Offset(cellLeft + cellW / 2, cellTop + 400));
    await tester.pump();
    DragSession.instance.drop();
    await tester.pump();

    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, isNull, reason: 'it never had one');
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, thu.day);
  });

  testWidgets('same-day keep is a no-op, and says so instead of going dead',
      (tester) async {
    final t = await makeTask('already here', thu, startMin: 570);
    await tester.pumpWidget(cellHarness(date: thu, dividerAt: 300));
    await tester.pump();

    final p = payloadFor(t, thu);
    DragSession.instance.begin(p, const Offset(10, 10));
    expect(modeAt(p, cellTop + 200), 'reject');

    DragSession.instance.drop();
    await tester.pump();

    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, 570, reason: 'nothing moved');
  });

  testWidgets('the preview SHOWS the future — card with time, or without',
      (tester) async {
    final t = await makeTask('show me', tue, startMin: 570);
    await tester.pumpWidget(cellHarness(date: thu, dividerAt: 300));
    await tester.pump();

    final p = payloadFor(t, tue);
    DragSession.instance.begin(p, const Offset(10, 10));

    // Above the divider → keep: the projected card carries its time.
    expect(modeAt(p, cellTop + 200), 'keep');
    final keep = DropFuture.forDate(thu)!;
    expect(keep.keepsTime, isTrue);
    expect(keep.projected.startTime, 570, reason: 'the card lands WITH 09:30');

    // Below → clear: the projected card has no time, and no badge says so —
    // the absence of the time on the card IS the message.
    expect(modeAt(p, cellTop + 400), 'clear');
    final clear = DropFuture.forDate(thu)!;
    expect(clear.keepsTime, isFalse);
    expect(clear.projected.startTime, isNull);
  });

  testWidgets('the keep/clear split is a STABLE fraction, not the divider',
      (tester) async {
    // The anti-flicker guarantee: reading the live divider made the boundary
    // move when the preview inserted a group, which flipped the decision, which
    // moved the preview — a feedback loop. The split is now a fixed cell
    // fraction, identical whether or not a divider is present.
    final t = await makeTask('stable split', tue, startMin: 570);
    // Fixed split = cellTop + settleTop + (cellH - settleTop) * 0.5.
    const splitY = cellTop + settleTop + (cellH - settleTop) * 0.5;

    for (final dividerAt in [null, 120.0, 500.0]) {
      await tester.pumpWidget(cellHarness(date: thu, dividerAt: dividerAt));
      await tester.pump();
      final p = payloadFor(t, tue);
      DragSession.instance.begin(p, const Offset(10, 10));
      expect(modeAt(p, splitY - 6), 'keep',
          reason: 'above the fixed split (divider=$dividerAt)');
      expect(modeAt(p, splitY + 6), 'clear',
          reason: 'below the fixed split (divider=$dividerAt)');
      DragSession.instance.debugReset();
    }
  });

  test('EVIDENCE (bug 7): deleting refreshes the day notifier', () async {
    final day = DateTime(2026, 9, 10);
    final ms = day.millisecondsSinceEpoch;
    await ts.createTask('m-a', ms);
    await ts.createTask('m-b', ms);
    final notifier = ts.tasksForDateNotifier(ms);
    final mine = notifier.value.where((t) => t.title.startsWith('m-')).toList();
    expect(mine.length, 2, reason: 'both created on the day');

    final a = ts.tasks.firstWhere((t) => t.title == 'm-a');
    ts.deleteTask(a);
    // If this fails, bug 7 is a DATA/notifier bug. If it passes, the delete
    // reaches the notifier correctly and the staleness is in the render layer.
    expect(notifier.value.any((t) => t.title == 'm-a'), isFalse,
        reason: 'the deleted one is gone from the notifier');
    expect(notifier.value.any((t) => t.title == 'm-b'), isTrue,
        reason: 'the OTHER one survives (bug 7: it wrongly vanished)');
  });

  testWidgets('the preview card RENDERS the future — time shown, or gone',
      (tester) async {
    final t = await makeTask('render me', tue, startMin: 570); // 09:30
    final p = payloadFor(t, tue);
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
