import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/state/app_dirs.dart';
import 'package:slate/core/state/local_prefs.dart';

/// Prefs writes are an atomic tmp→rename swap; a crash mid-write leaves a
/// valid tmp that load() recovers. Never a torn JSON, never a lost flag.
void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slate_prefs_test');
    AppDirs.testOverride = dir;
    AppDirs.debugReset();
    LocalPrefs.debugReset();
  });

  tearDown(() async {
    AppDirs.testOverride = null;
    AppDirs.debugReset();
    LocalPrefs.debugReset();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('a crashed write leaves only .tmp — load recovers it', () async {
    await File('${dir.path}\\prefs.json.tmp')
        .writeAsString('{"slate_view_pref":"month"}');

    final prefs = await LocalPrefs.load();

    expect(prefs.viewPref, 'month');
  });

  test('persist swaps atomically: valid file, no tmp left behind', () async {
    await File('${dir.path}\\prefs.json').writeAsString('{}');
    final prefs = await LocalPrefs.load();

    prefs.viewPref = 'month';
    prefs.autostart = false;
    await prefs.debugFlush();

    final onDisk = jsonDecode(
            await File('${dir.path}\\prefs.json').readAsString())
        as Map<String, dynamic>;
    expect(onDisk['slate_view_pref'], 'month');
    expect(onDisk['slate_autostart'], 'false');
    expect(await File('${dir.path}\\prefs.json.tmp').exists(), isFalse);
  });
}
