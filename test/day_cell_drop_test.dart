import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/slate_core_bridge.dart';
import 'package:slate/core/interaction/drag_session.dart';
import 'package:slate/core/state/task_state.dart';
import 'package:slate/ui/widgets/day_cell_drop_target.dart';

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
    expect(DragSession.instance.hover.value?.badgeText, 'Already here');

    DragSession.instance.drop();
    await tester.pump();

    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, 570, reason: 'nothing moved');
  });

  testWidgets('the badge names the outcome, not the mechanic', (tester) async {
    final t = await makeTask('badge me', tue, startMin: 570);
    await tester.pumpWidget(cellHarness(date: thu, dividerAt: 300));
    await tester.pump();

    final p = payloadFor(t, tue);
    DragSession.instance.begin(p, const Offset(10, 10));

    expect(modeAt(p, cellTop + 200), 'keep');
    expect(DragSession.instance.hover.value?.badgeText, '09:30');

    expect(modeAt(p, cellTop + 400), 'clear');
    expect(DragSession.instance.hover.value?.badgeText, 'No time');
  });

  testWidgets(
      'REGRESSION: with no divider, the line you see IS the line that decides',
      (tester) async {
    final t = await makeTask('split truth', tue, startMin: 570);
    // dividerAt: null — the cell has one group, so the wash stands a line in.
    await tester.pumpWidget(cellHarness(date: thu, dividerAt: null));
    await tester.pump();

    final p = payloadFor(t, tue);
    DragSession.instance.begin(p, Offset(cellLeft + cellW / 2, cellTop + 200));
    await tester.pump();

    final line = find.byKey(DayCellDropTarget.splitLineKey);
    expect(line, findsOneWidget, reason: 'no divider → the wash draws one');
    final lineY = tester.getCenter(line).dy;

    // The property that was broken: the drawn line and the hit boundary were
    // computed apart (settleTopOffset-based vs a flat 50% of the padded box).
    expect(modeAt(p, lineY - 4), 'keep',
        reason: 'just above the visible line = keep the time');
    expect(modeAt(p, lineY + 4), 'clear',
        reason: 'just below the visible line = drop the time');

    // And it is where the fallback formula says, not at a flat 50%.
    const expected = cellTop + settleTop + (cellH - settleTop) * 0.5;
    expect(lineY, closeTo(expected, 1.0));
    expect(lineY, isNot(closeTo(cellTop + cellH * 0.5, 1.0)),
        reason: 'the flat-50% line was the lie');
  });
}
