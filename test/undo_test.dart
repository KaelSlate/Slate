import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/capture_destination.dart';
import 'package:slate/core/engine/slate_core_bridge.dart';
import 'package:slate/core/state/task_state.dart';

/// Undo against the REAL engine DLL: toggle undo re-flips by id; delete undo
/// recreates the task with EVERY field intact (day, times, tags, priority,
/// inbox status, done) through the existing FFI path.
late TaskState ts;

RustTask byTitle(String title) => ts.tasks.firstWhere((t) => t.title == title);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final temp = Directory.systemTemp.createTempSync('slate_undo');
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

  test('toggle undo: Ctrl+Z un-checks an accidental check', () async {
    final day = DateTime.now().millisecondsSinceEpoch;
    await ts.createTask('oops checked', day);
    ts.toggleTask(byTitle('oops checked'));
    expect(byTitle('oops checked').isCompleted, isTrue);

    expect(ts.undoLast(), 'check removed');
    expect(byTitle('oops checked').isCompleted, isFalse);
  });

  test('delete undo: every field survives the round trip', () async {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day + 2);
    await ts.createCaptured(
      'precious plan',
      const ParseResult(
        cleanTitle: 'precious plan',
        startTime: 600,
        endTime: 675,
        priority: 2,
        tags: ['home', 'idea'],
      ),
      CaptureDestination(
          toInbox: false, day: day, startTime: 600, endTime: 675, label: 'x'),
    );
    ts.toggleTask(byTitle('precious plan')); // deleted while done

    ts.deleteTask(byTitle('precious plan'));
    expect(ts.tasks.where((t) => t.title == 'precious plan'), isEmpty);

    expect(ts.undoLast(), contains('precious plan'));
    final t = byTitle('precious plan');
    expect(t.createdAt, day.millisecondsSinceEpoch, reason: 'day restored');
    expect(t.startTime, 600);
    expect(t.endTime, 675);
    expect(t.priority, 2);
    expect(t.tags, ['home', 'idea']);
    expect(t.isInbox, isFalse);
    expect(t.isCompleted, isTrue, reason: 'done state restored');
  });

  test('delete undo: inbox thought comes back into the inbox', () async {
    await ts.createInboxTask('fleeting thought',
        priority: 1, tags: ['spark']);
    ts.deleteTask(byTitle('fleeting thought'));

    expect(ts.undoLast(), contains('fleeting thought'));
    final t = byTitle('fleeting thought');
    expect(t.isInbox, isTrue);
    expect(t.priority, 1);
    expect(t.tags, ['spark']);
    expect(t.isCompleted, isFalse);
  });

  test('undo puts tasks back on their original day-list spots', () async {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day + 3);
    final dayTs = day.millisecondsSinceEpoch;
    for (final t in ['ord A', 'ord B', 'ord C']) {
      await ts.createTask(t, dayTs);
    }
    final before = ts.core.tasksForDate(dayTs).map((t) => t.title).toList();

    // Scattered deletes (middle first) — the old append-on-restore shuffled.
    ts.deleteTask(byTitle('ord B'));
    ts.deleteTask(byTitle('ord A'));
    expect(ts.undoLast(), contains('ord A'));
    expect(ts.undoLast(), contains('ord B'));

    final after = ts.core.tasksForDate(dayTs).map((t) => t.title).toList();
    expect(after, before, reason: 'day-list order restored exactly');
  });

  test('undo skips toggles of since-deleted tasks, empty stack is graceful',
      () async {
    final day = DateTime.now().millisecondsSinceEpoch;
    await ts.createTask('ephemeral', day);
    final task = byTitle('ephemeral');
    ts.toggleTask(task);
    ts.deleteTask(byTitle('ephemeral'));

    // Undo #1 restores the delete; undo #2 re-flips the restored task? No —
    // the restored task has a NEW id, so the old toggle entry is skipped and
    // the next valid entry (if any) is used instead.
    expect(ts.undoLast(), contains('ephemeral'));
    expect(byTitle('ephemeral').isCompleted, isTrue);

    while (ts.undoLast() != null) {} // drain whatever history is left
    expect(ts.undoLast(), isNull, reason: 'empty stack must not throw');
  });
}
