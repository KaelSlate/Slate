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

  testWidgets('the «+N more» button sits inside the cell, in the corner',
      (tester) async {
    // «+N more» is a bottom-right corner overlay now, so it costs no row (two
    // cards stay whole) and can never clip off below the cell floor.
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
        reason: 'the «+N more» button falls inside its cell, not under it');
    // Bottom-right corner: to the right of the cell's midline.
    expect(moreRect.center.dx, greaterThan(cellRect.center.dx),
        reason: 'it lives in the corner, not centred');
  });

  testWidgets('a cell shows at least two cards, not one', (tester) async {
    // The regression: measuring the cap and reserving a label row dropped the
    // cell to a SINGLE card. With «+N more» moved to the corner, the cards keep
    // the full height and the cap floors at two — what the cell always showed.
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day == 9 ? 10 : 9);
    final ms = d.millisecondsSinceEpoch;
    for (var i = 0; i < 6; i++) {
      await ts.createTask('two-$i', ms);
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonthGridView(core: ts.core, taskState: ts, onDayTap: (_) {}),
      ),
    ));
    await pumpFrames(tester);

    // The two freshest are BOTH on screen (a single-card cell would hide the
    // second), and the rest are behind the pile.
    expect(find.text('two-5'), findsOneWidget);
    expect(find.text('two-4'), findsOneWidget,
        reason: 'the second card is visible — not just one');
    expect(find.textContaining('more'), findsOneWidget);
  });

  testWidgets('the opened day groups timed and untimed under labels',
      (tester) async {
    tester.view.physicalSize = const Size(1100, 850);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final now = DateTime.now();
    final d = DateTime(now.year, now.month, now.day == 11 ? 12 : 11);
    final ms = d.millisecondsSinceEpoch;

    // Enough to overflow the cell, mixing timed and untimed.
    for (var i = 0; i < 3; i++) {
      await ts.createTask('am-$i', ms); // untimed
    }
    for (var i = 0; i < 3; i++) {
      await ts.createTask('timed-$i', ms);
      final t = ts.tasks.firstWhere((x) => x.title == 'timed-$i');
      ts.scheduleAt(t, d, 540 + i * 60, 600 + i * 60); // 09:00, 10:00, 11:00
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MonthGridView(core: ts.core, taskState: ts, onDayTap: (_) {}),
      ),
    ));
    await pumpFrames(tester);

    await tester.tap(find.textContaining('more'));
    await pumpFrames(tester);

    // Both group heads are present, and a timed card shows its hour — the
    // sections are labelled, not one flat pile.
    expect(find.text('SCHEDULED'), findsOneWidget);
    expect(find.text('ANYTIME'), findsOneWidget);
    expect(find.text('09:00'), findsWidgets,
        reason: 'a timed card carries its time in the opened day');
  });
}
