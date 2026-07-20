import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/state/backup_service.dart';

/// The silent daily safety net: one JSON per calendar day, newest 7 kept.
/// The DPAPI key dies with the Windows profile — this is what survives it.
void main() {
  late Directory dir;
  final noon = DateTime(2026, 7, 19, 12);

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slate_backup_test');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('first write of the day creates a dated file', () async {
    final f = await maybeWriteDailyBackup('{"tasks":[1]}', dir, now: noon);
    expect(f, isNotNull);
    expect(f!.path.endsWith('tasks 2026-07-19.json'), isTrue);
    expect(await f.readAsString(), '{"tasks":[1]}');
  });

  test('second write the same day is a no-op unless refreshed', () async {
    await maybeWriteDailyBackup('{"v":1}', dir, now: noon);
    final again = await maybeWriteDailyBackup('{"v":2}', dir,
        now: noon.add(const Duration(hours: 3)));
    expect(again, isNull);
    expect(await File('${dir.path}\\tasks 2026-07-19.json').readAsString(),
        '{"v":1}');

    // refresh (the quit hook): today's file is rewritten with the fresh state
    final quit = await maybeWriteDailyBackup('{"v":3}', dir,
        now: noon.add(const Duration(hours: 10)), refresh: true);
    expect(quit, isNotNull);
    expect(await File('${dir.path}\\tasks 2026-07-19.json').readAsString(),
        '{"v":3}');
  });

  test('prunes to the newest seven', () async {
    for (var d = 1; d <= 9; d++) {
      await maybeWriteDailyBackup('{"d":$d}', dir,
          now: DateTime(2026, 7, d, 9));
    }
    final names = (await dir.list().toList())
        .map((e) => e.uri.pathSegments.last)
        .toList()
      ..sort();
    expect(names.length, 7);
    expect(names.first, 'tasks 2026-07-03.json',
        reason: 'the two oldest are gone');
    expect(names.last, 'tasks 2026-07-09.json');
  });
}
