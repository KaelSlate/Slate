import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/slate_core_bridge.dart';
import 'package:slate/core/interaction/drag_session.dart';
import 'package:slate/core/state/task_state.dart';
import 'package:slate/ui/views/day_flow_view.dart';
import 'package:slate/ui/widgets/drop_future.dart';

/// The day's LEFT pane as a drop target, against the real engine DLL.
///
/// The pane has no regions. The ribbon owns "at an hour", the pane owns
/// "without one", so a card dropped here has exactly one outcome — there is
/// nothing to aim at. That retires the keep/clear split, whose boundary hung on
/// a divider that only mounts when BOTH sections are filled: on a day of
/// only-scheduled tasks the line fell silently to 40% of the pane height.
late TaskState ts;

const double viewW = 1200, viewH = 800;

/// A point unambiguously inside the left pane (flex 35 of the full width).
double paneX(double frac) => viewW * 0.35 * frac;

DateTime day(int n) => DateTime(2026, 10, n);

Widget harness(DateTime date) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: viewW,
          height: viewH,
          child: DayFlowView(
            selectedDate: date,
            core: ts.core,
            taskState: ts,
            onToggleTask: ts.toggleTask,
          ),
        ),
      ),
    );

DragPayload payloadFor(RustTask t, DateTime sourceDay,
        {DragSourceKind kind = DragSourceKind.timelineBlock}) =>
    DragPayload(
      task: t,
      kind: kind,
      sourceGlobalRect: const Rect.fromLTWH(0, 0, 100, 30),
      grabOffset: Offset.zero,
      sourceDay: sourceDay,
    );

/// Hover mode at a height inside the pane, as the live session reports it.
String? modeAt(double y, {double frac = 0.5}) {
  DragSession.instance.update(Offset(paneX(frac), y));
  return DragSession.instance.hover.value?.cellMode;
}

/// Every answer the pane gives down its full height. Sweeps rather than
/// assuming where the pane starts and ends — the day header owns the top, and
/// hard-coding that here would test the harness, not the rule. Nulls (outside
/// the zone) are dropped; what matters is that the answers agree.
Set<String> modesDownThePane() {
  final seen = <String>{};
  for (var f = 0.02; f < 1.0; f += 0.02) {
    final m = modeAt(viewH * f);
    if (m != null) seen.add(m);
  }
  return seen;
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
    final temp = Directory.systemTemp.createTempSync('slate_pane_drop');
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

  testWidgets('a timed card dropped on the pane loses its hour', (tester) async {
    final d = day(2);
    final t = await makeTask('unschedule me', d, startMin: 570); // 09:30
    await tester.pumpWidget(harness(d));
    await tester.pumpAndSettle();

    DragSession.instance.begin(payloadFor(t, d), const Offset(10, 10));
    DragSession.instance.update(Offset(paneX(0.5), viewH * 0.5));
    await tester.pump();
    DragSession.instance.drop();
    await tester.pump();

    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.startTime, isNull);
    expect(after.endTime, isNull);
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, d.day,
        reason: 'it stays on the day it was already on');
  });

  testWidgets('THE POINT: one outcome at every height — no dead half',
      (tester) async {
    // The old pane answered 'keep' above the divider and 'clear' below it. The
    // 'keep' half was a pure no-op: the biggest target on screen did nothing.
    final d = day(3);
    final t = await makeTask('any height', d, startMin: 540);
    await tester.pumpWidget(harness(d));
    await tester.pumpAndSettle();

    DragSession.instance.begin(payloadFor(t, d), const Offset(10, 10));
    expect(modesDownThePane(), {'clear'},
        reason: 'one answer top to bottom — and never a no-op "keep"');
  });

  testWidgets(
      'REGRESSION: a day of only-scheduled tasks had an invisible boundary',
      (tester) async {
    // No untimed tasks → the ◇ divider never mounted → _splitY fell back to
    // 40% of the pane and nothing on screen said where the line was. The same
    // gesture meant different things on different days.
    final onlyScheduled = day(4), mixed = day(14), empty = day(15);
    await makeTask('sched a', onlyScheduled, startMin: 540);
    await makeTask('sched b', onlyScheduled, startMin: 720);
    await makeTask('mix timed', mixed, startMin: 540);
    await makeTask('mix untimed', mixed);
    final t = await makeTask('drag me', day(4), startMin: 900);

    // Three days with wildly different contents → identical answers.
    for (final d in [onlyScheduled, mixed, empty]) {
      await tester.pumpWidget(harness(d));
      await tester.pumpAndSettle();
      DragSession.instance.begin(payloadFor(t, day(4)), const Offset(10, 10));
      expect(modesDownThePane(), {'clear'}, reason: 'on day ${d.day}');
      DragSession.instance.debugReset();
    }
  });

  testWidgets('an inbox card lands on the day, without a time', (tester) async {
    final d = day(5);
    await ts.createInboxTask('from the inbox');
    final t = ts.tasks.firstWhere((x) => x.title == 'from the inbox');
    await tester.pumpWidget(harness(d));
    await tester.pumpAndSettle();

    DragSession.instance.begin(
        payloadFor(t, d, kind: DragSourceKind.inboxCard), const Offset(10, 10));
    expect(modeAt(viewH * 0.5), 'whole');
    DragSession.instance.drop();
    await tester.pump();

    final after = ts.tasks.firstWhere((x) => x.id == t.id);
    expect(after.isInbox, isFalse, reason: 'it joined the calendar');
    expect(after.startTime, isNull, reason: 'the pane never grants an hour');
    expect(DateTime.fromMillisecondsSinceEpoch(after.createdAt).day, d.day);
  });

  testWidgets('an already-untimed card is refused — nothing to offer',
      (tester) async {
    final d = day(6);
    final t = await makeTask('no time already', d);
    await tester.pumpWidget(harness(d));
    await tester.pumpAndSettle();

    DragSession.instance.begin(
        payloadFor(t, d, kind: DragSourceKind.planListCard),
        const Offset(10, 10));
    // canAccept rejects it, so the pane is not even the hovered zone.
    DragSession.instance.update(Offset(paneX(0.5), viewH * 0.5));
    await tester.pump();
    expect(DragSession.instance.hover.value?.zoneId, isNot('planning-pane'));
  });

  testWidgets('the pane SHOWS the future: the projected card has no time',
      (tester) async {
    final d = day(7);
    final t = await makeTask('future me', d, startMin: 810); // 13:30
    await tester.pumpWidget(harness(d));
    await tester.pumpAndSettle();

    DragSession.instance.begin(payloadFor(t, d), const Offset(10, 10));
    expect(modeAt(viewH * 0.5), 'clear');

    final f = DropFuture.forDate(d)!;
    expect(f.keepsTime, isFalse);
    expect(f.projected.startTime, isNull,
        reason: 'the absence of the time IS the message');
    expect(f.projected.title, 'future me');
  });

  testWidgets('the group head says ANYTIME, and hands the hour over',
      (tester) async {
    final d = day(8);
    final t = await makeTask('hand it over', d, startMin: 570); // 09:30
    await tester.pumpWidget(harness(d));
    await tester.pumpAndSettle();

    // At rest the imperative is gone for good.
    expect(find.text('TO SCHEDULE'), findsNothing);

    DragSession.instance.begin(payloadFor(t, d), const Offset(10, 10));
    DragSession.instance.update(Offset(paneX(0.5), viewH * 0.5));
    await tester.pump();

    expect(find.text('ANYTIME'), findsOneWidget,
        reason: 'the group materialises to receive the card');

    // Not just "09:30 appears somewhere" — the card it came from still shows
    // its badge, so that would pass for the wrong reason. The hand-over is the
    // one struck through.
    final struck = tester
        .widgetList<Text>(find.text('09:30'))
        .where((w) => w.style?.decoration == TextDecoration.lineThrough);
    expect(struck, hasLength(1),
        reason: 'the hour being given up, struck through on the group head');
  });
}
