import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

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

  /// Memoized load — main() and the engine (demo seeding) may both await it.
  static Future<LocalPrefs>? _loading;
  static Future<LocalPrefs> load() => _loading ??= _doLoad();

  static Future<LocalPrefs> _doLoad() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/slate_data/prefs.json');
    Map<String, dynamic> data = {};
    try {
      if (await file.exists()) {
        data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      } else {
        // One-time migration from secure storage, where these never belonged.
        const storage = FlutterSecureStorage();
        final values = await Future.wait([
          storage.read(key: _kViewPref),
          storage.read(key: _kOnboarded),
          storage.read(key: _kWelcomed),
        ]);
        data = {
          if (values[0] != null) _kViewPref: values[0],
          if (values[1] != null) _kOnboarded: values[1],
          if (values[2] != null) _kWelcomed: values[2],
        };
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

  /// Fire-and-forget write — three tiny keys, never blocks the UI.
  void _persist() {
    Future(() async {
      try {
        await _file.parent.create(recursive: true);
        await _file.writeAsString(jsonEncode(_data));
      } catch (_) {/* non-fatal: prefs are re-derivable */}
    });
  }
}