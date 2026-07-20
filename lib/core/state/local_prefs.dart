import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'app_dirs.dart';

/// Plain-file app preferences — NON-secrets only.
///
/// view_pref / onboarded / welcomed used to live in flutter_secure_storage,
/// which on Windows means file IO + a DPAPI decrypt PER KEY on the startup
/// critical path — the wrong tool for values that aren't secrets. One tiny
/// JSON, read once before runApp. The SQLCipher DB key STAYS in DPAPI.
class LocalPrefs {
  LocalPrefs._(this._file, this._data);

  static late LocalPrefs instance;

  final File _file;
  final Map<String, dynamic> _data;

  static const _kViewPref = 'slate_view_pref';
  static const _kOnboarded = 'slate_onboarded';
  static const _kWelcomed = 'slate_welcomed';
  static const _kAutostart = 'slate_autostart';
  static const _kSeeded = 'slate_seeded';
  static const _kDemoIds = 'slate_demo_ids';
  static const _kLessons = 'slate_lessons';
  static const _kLessonSeen = 'slate_lesson_seen';

  /// Memoized load — main() and the engine (demo seeding) may both await it.
  static Future<LocalPrefs>? _loading;
  static Future<LocalPrefs> load() => _loading ??= _doLoad();

  /// Tests re-run load() against a fresh AppDirs.testOverride.
  @visibleForTesting
  static void debugReset() => _loading = null;

  static Future<LocalPrefs> _doLoad() async {
    final dir = await AppDirs.dataDir();
    final file = File('${dir.path}\\prefs.json');
    Map<String, dynamic> data = {};
    try {
      if (await file.exists()) {
        data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } else {
        final tmp = File('${file.path}.tmp');
        if (await tmp.exists()) {
          // A crash between tmp-write and swap — the tmp IS the latest state.
          data = jsonDecode(await tmp.readAsString()) as Map<String, dynamic>;
        }
        // No file, no tmp → a new user. The old secure-storage migration
        // branch that lived here resurrected onboarded/welcomed from the
        // DPAPI vault after a deliberate data wipe — the welcome never
        // played again. Stale keys in the vault are ignored for good.
      }
    } catch (_) {
      data = {}; // corrupt/unreadable prefs → sane defaults, never crash startup
    }
    instance = LocalPrefs._(file, data);
    if (!await file.exists()) instance._persist(); // finish migration on disk
    return instance;
  }

  String? get viewPref => _data[_kViewPref] as String?;
  bool get onboarded => _data[_kOnboarded] == 'true';
  bool get welcomed => _data[_kWelcomed] == 'true';
  /// Demo tasks were seeded once — never re-seed, even if the user deletes them.
  bool get seeded => _data[_kSeeded] == 'true';

  /// Ids of the seeded sample tasks — no visual tag on the cards; the tray's
  /// "Clear sample tasks" sweeps by id.
  List<String> get demoIds =>
      (_data[_kDemoIds] as List?)?.cast<String>() ?? const [];
  set demoIds(List<String> v) {
    if (v.isEmpty) {
      _data.remove(_kDemoIds);
    } else {
      _data[_kDemoIds] = v;
    }
    _persist();
  }
  /// Ids of mechanics the user has performed — each retires its own hint, so a
  /// lesson can never be killed off by an unrelated action.
  List<String> get lessons =>
      (_data[_kLessons] as List?)?.cast<String>() ?? const [];
  set lessons(List<String> v) {
    if (v.isEmpty) {
      _data.remove(_kLessons);
    } else {
      _data[_kLessons] = v;
    }
    _persist();
  }

  /// Sessions an invite has been shown in but not acted on. It retires anyway
  /// once this runs out: a hint that keeps asking is nagging, and the compass
  /// says calm, never guilt.
  Map<String, int> get lessonSeen =>
      (_data[_kLessonSeen] as Map?)?.map((k, v) => MapEntry('$k', v as int)) ??
      const {};
  set lessonSeen(Map<String, int> v) {
    if (v.isEmpty) {
      _data.remove(_kLessonSeen);
    } else {
      _data[_kLessonSeen] = v;
    }
    _persist();
  }

  /// Launch at Windows login (tray-resident, --hidden). Default ON — the
  /// global capture hotkey is the product's core promise.
  bool get autostart => _data[_kAutostart] != 'false';

  set viewPref(String? v) => _set(_kViewPref, v);
  set onboarded(bool v) => _set(_kOnboarded, '$v');
  set welcomed(bool v) => _set(_kWelcomed, '$v');
  set autostart(bool v) => _set(_kAutostart, '$v');
  set seeded(bool v) => _set(_kSeeded, '$v');

  void _set(String key, String? value) {
    if (value == null) {
      _data.remove(key);
    } else {
      _data[key] = value;
    }
    _persist();
  }

  /// Serialized atomic swap: tmp-write → rename. A crash mid-write leaves
  /// either the valid old file or a valid tmp (recovered on load) — never a
  /// torn JSON. Writes chain so two setters can't interleave on disk.
  Future<void> _writes = Future.value();
  void _persist() {
    _writes = _writes.then((_) async {
      try {
        await _file.parent.create(recursive: true);
        final tmp = File('${_file.path}.tmp');
        await tmp.writeAsString(jsonEncode(_data), flush: true);
        try {
          await tmp.rename(_file.path);
        } on FileSystemException {
          // Windows may refuse a rename onto an existing file.
          await _file.delete();
          await tmp.rename(_file.path);
        }
      } catch (_) {/* non-fatal: prefs are re-derivable */}
    });
  }

  @visibleForTesting
  Future<void> debugFlush() => _writes;
}