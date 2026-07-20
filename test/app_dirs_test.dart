import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/state/app_dirs.dart';

/// slate_data moves out of Documents (OneDrive roulette) into the app-support
/// dir. The move is a one-time, never-overwriting migration.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('slate_dirs_test');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  });

  Directory dir(String rel) => Directory('${root.path}\\$rel');
  File file(String rel) => File('${root.path}\\$rel');

  test('moves the legacy folder into the new home, subfolders included',
      () async {
    final legacy = dir('docs\\slate_data');
    await Directory('${legacy.path}\\logs').create(recursive: true);
    await File('${legacy.path}\\tasks.db').writeAsString('DB-BYTES');
    await File('${legacy.path}\\prefs.json').writeAsString('{"a":1}');
    await File('${legacy.path}\\logs\\slate_log.txt').writeAsString('log');
    final target = dir('appdata\\slate_data');

    await migrateLegacyData(legacy, target);

    expect(await file('appdata\\slate_data\\tasks.db').readAsString(),
        'DB-BYTES');
    expect(await file('appdata\\slate_data\\prefs.json').readAsString(),
        '{"a":1}');
    expect(await file('appdata\\slate_data\\logs\\slate_log.txt').exists(),
        isTrue);
    expect(await legacy.exists(), isFalse,
        reason: 'the old folder is gone — no split-brain second home');
  });

  test('never overwrites an existing new-home DB with the legacy one',
      () async {
    final legacy = dir('docs\\slate_data');
    await legacy.create(recursive: true);
    await File('${legacy.path}\\tasks.db').writeAsString('OLD');
    final target = dir('appdata\\slate_data');
    await target.create(recursive: true);
    await File('${target.path}\\tasks.db').writeAsString('NEW');

    await migrateLegacyData(legacy, target);

    expect(await file('appdata\\slate_data\\tasks.db').readAsString(), 'NEW');
    expect(await file('docs\\slate_data\\tasks.db').readAsString(), 'OLD',
        reason: 'when in doubt, touch nothing');
  });

  test('no legacy folder → no-op', () async {
    final target = dir('appdata\\slate_data');
    await migrateLegacyData(dir('docs\\slate_data'), target);
    expect(await target.exists(), isFalse);
  });
}
