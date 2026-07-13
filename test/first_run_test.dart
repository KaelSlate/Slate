import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/spatial_zoom_engine.dart';
import 'package:slate/core/state/first_run.dart';
import 'package:slate/core/state/local_prefs.dart';
import 'package:slate/core/state/task_state.dart';

/// First-run mechanics against the REAL engine DLL: demo seeding (once, into
/// an empty store, muted) and the first-capture arc (flags + landing label).
late TaskState ts;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final temp = Directory.systemTemp.createTempSync('slate_first_run');
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
    await LocalPrefs.load();
  });

  test('demo seed: natural sample week, ids in prefs, muted — not a capture',
      () async {
    expect(ts.tasks, isEmpty, reason: 'FLUTTER_TEST gate skips auto-seed');

    StaircaseState.isFirstRun = true;
    FirstRunController.instance.syncFromPrefs();
    await ts.maybeSeedDemo();

    final ids = LocalPrefs.instance.demoIds.toSet();
    final demos = ts.tasks.where((t) => ids.contains(t.id)).toList();
    expect(demos.length, 9, reason: '7 day tasks + 2 inbox thoughts');
    expect(demos.where((t) => t.isInbox).length, 2);
    expect(demos.where((t) => t.startTime != null).length, 5,
        reason: 'five timed tasks lie on the timeline');
    expect(demos.where((t) => !t.isInbox && t.startTime == null).length, 2,
        reason: 'unscheduled cards split the day cells');
    expect(demos.where((t) => t.isCompleted).length, 1,
        reason: 'one done task — the progress ring lives');
    expect(demos.any((t) => t.priority == 2), isTrue);
    expect(demos.any((t) => t.tags.isNotEmpty), isTrue);
    expect(demos.any((t) => t.tags.contains('demo')), isFalse,
        reason: 'no visual #demo pollution');
    expect(LocalPrefs.instance.seeded, isTrue);
    expect(FirstRunController.instance.firstLanding.value, isNull,
        reason: 'seeding is muted — not a capture');
    expect(StaircaseState.isFirstRun, isTrue);

    // Re-seed attempt is a no-op (slate_seeded).
    await ts.maybeSeedDemo();
    expect(ts.tasks.length, 9);
  });

  test('first capture completes the arc: flags flip, landing label recorded',
      () async {
    expect(StaircaseState.isFirstRun, isTrue);
    StaircaseState.showWelcome = true;

    await ts.createInboxTask('my very first thought');

    expect(FirstRunController.instance.firstLanding.value, 'Inbox');
    expect(StaircaseState.isFirstRun, isFalse);
    expect(StaircaseState.showWelcome, isFalse);
    expect(FirstRunController.instance.hintsActive.value, isFalse);
    expect(LocalPrefs.instance.onboarded, isTrue);
    expect(LocalPrefs.instance.welcomed, isTrue);

    // Second capture must not overwrite the recorded landing.
    await ts.createInboxTask('second thought');
    expect(FirstRunController.instance.firstLanding.value, 'Inbox');
  });

  test('clear sample tasks sweeps every seeded id, keeps real ones', () {
    final ids = LocalPrefs.instance.demoIds.toSet();
    expect(ids, isNotEmpty);
    ts.clearDemoTasks();
    expect(ts.tasks.where((t) => ids.contains(t.id)), isEmpty);
    expect(LocalPrefs.instance.demoIds, isEmpty);
    expect(ts.tasks.where((t) => t.title == 'my very first thought'),
        isNotEmpty, reason: 'real tasks survive the sweep');
  });
}
