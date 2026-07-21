import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/state/task_state.dart';
import 'package:slate/ui/views/month_grid_view.dart';
import 'package:slate/ui/widgets/day_cell_drop_target.dart';

/// Reaching a task the month cell hides behind «+N more».
///
/// A month cell shows two rows; the rest are real, on that day, but off-screen.
/// Before this, the only way to touch one was to hunt for it in the week view.
/// Tapping the pile opens the whole day as a floating layer, so every card is
/// grabbable; clicking away folds it back.
late TaskState ts;

Future<void> pumpFrames(WidgetTester tester, [int n = 4]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 200));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final temp = Directory.systemTemp.createTempSync('slate_month_expand');
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
    // Start from a clean store so no stray task overflows another day.
    for (final t in List.of(ts.tasks)) {
      ts.deleteTask(t);
    }
  });

  // Each test starts from an empty month — otherwise a prior test's overflow day
  // leaves a second «+N more» in the grid.
  tearDown(() {
    for (final t in List.of(ts.tasks)) {
      ts.deleteTask(t);
    }
  });

  testWidgets('a task hidden behind «+N more» opens, then folds away',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // A quiet, unmistakable day this month: pick one that isn't today so no
    // styling special-cases the cell.
    final now = DateTime.now();
    var d = DateTime(now.year, now.month, now.day == 20 ? 21 : 20);
    final ms = d.millisecondsSinceEpoch;

    // Six untimed tasks. The cell shows the two freshest; the oldest sink
    // behind the pile.
    for (var i = 0; i < 6; i++) {
      await ts.createTask('mtask-$i', ms);
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonthGridView(
          core: ts.core,
          taskState: ts,
          onDayTap: (_) {},
        ),
      ),
    ));
    await pumpFrames(tester);

    // The pile is present and an oldest card is NOT in the tree yet.
    expect(find.textContaining('more'), findsOneWidget,
        reason: 'the day overflows its two rows');
    expect(find.text('mtask-0'), findsNothing,
        reason: 'the oldest is hidden behind «+N more»');

    // Open the day.
    await tester.tap(find.textContaining('more'));
    await pumpFrames(tester);

    expect(find.text('mtask-0'), findsWidgets,
        reason: 'the opened day surfaces every card, hidden ones included');

    // Click away folds it back.
    await tester.tapAt(const Offset(550, 720));
    await pumpFrames(tester);

    expect(find.text('mtask-0'), findsNothing,
        reason: 'the reach-in affordance is gone once it has served');
  });

  testWidgets('the «+N more» line is never clipped off a short cell',
      (tester) async {
    // The bug: a hardcoded cap of 2 cards had no idea how tall the cell was.
    // On a short month (6 rows, small window) two ~40px cards overran the task
    // area and the «+N more» line below them clipped — the user saw two tasks
    // and no way to reach the rest. The cap now measures the room and always
    // keeps a row for the label.
    tester.view.physicalSize = const Size(900, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day == 18 ? 19 : 18);
    final ms = d.millisecondsSinceEpoch;
    for (var i = 0; i < 5; i++) {
      await ts.createTask('short-$i', ms);
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonthGridView(core: ts.core, taskState: ts, onDayTap: (_) {}),
      ),
    ));
    await pumpFrames(tester);

    final more = find.textContaining('more');
    expect(more, findsOneWidget, reason: 'the overflow line must be present');

    // Its own cell — the label must sit WITHIN it, not clipped below its floor.
    final cell = find.ancestor(
        of: more, matching: find.byType(DayCellDropTarget));
    expect(cell, findsOneWidget);
    final moreRect = tester.getRect(more);
    final cellRect = tester.getRect(cell);
    expect(moreRect.bottom, lessThanOrEqualTo(cellRect.bottom + 0.5),
        reason: 'the «+N more» label falls inside its cell, not under it');
    expect(find.textContaining('more'), findsOneWidget,
        reason: 'exactly one overflow line, and it is reachable');
  });
}
