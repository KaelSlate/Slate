import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// One home for Slate's machine-local state (DB, prefs, logs, backups).
///
/// v1.0.6 and earlier kept it in Documents\slate_data — which on many Windows
/// machines is silently a OneDrive folder, and a cloud-sync client fighting
/// SQLite's WAL is a known corruption generator. Home is now the per-user
/// app-support dir; the first start after this change moves the old folder in.
/// Human-facing files (tray exports) stay in Documents on purpose.
class AppDirs {
  AppDirs._();

  /// Tests point everything at a temp dir.
  @visibleForTesting
  static Directory? testOverride;

  static Future<Directory>? _resolving;

  static Future<Directory> dataDir() => _resolving ??= _resolve();

  static Future<Directory> _resolve() async {
    if (testOverride != null) {
      await testOverride!.create(recursive: true);
      return testOverride!;
    }
    // `flutter test` without an override: a throwaway per-process dir. The
    // suite used to run against the REAL user DB — one stray fixture away
    // from polluting (or migrating) live data.
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      final d = Directory('${Directory.systemTemp.path}\\slate_test_$pid');
      await d.create(recursive: true);
      return d;
    }

    final support = await getApplicationSupportDirectory();
    final target = Directory('${support.path}\\slate_data');
    var home = target;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final legacy = Directory('${docs.path}\\slate_data');
      if (!await migrateLegacyData(legacy, target)) {
        // The old DB is still held open (an older instance mid-shutdown).
        // Never copy a live database — stay in the old home this session.
        home = legacy;
      }
    } catch (_) {/* Documents unresolvable — nothing to migrate from */}
    await home.create(recursive: true);
    return home;
  }

  @visibleForTesting
  static void debugReset() => _resolving = null;
}

/// Move the old Documents home into the new one, once. Returns true when
/// [target] is safe to use as home (moved, already moved, or nothing to move);
/// false means the legacy DB couldn't be moved safely — keep living in legacy.
/// A torn copy can never become the home: the copy path stages into a sibling
/// dir and adopts it with a single atomic rename.
Future<bool> migrateLegacyData(Directory legacy, Directory target) async {
  try {
    if (!await legacy.exists()) return true;
    if (!await File('${legacy.path}\\tasks.db').exists()) return true;
    if (await File('${target.path}\\tasks.db').exists()) return true;
    await target.parent.create(recursive: true);

    // Fast path: same volume, no open handles → one atomic dir rename.
    try {
      if (await target.exists()) await target.delete(recursive: true);
      await legacy.rename(target.path);
      return true;
    } catch (_) {/* cross-volume or a held file — try the staged copy */}

    if (await _isHeldOpen(File('${legacy.path}\\tasks.db'))) return false;

    final staging = Directory('${target.path}.migrating');
    if (await staging.exists()) await staging.delete(recursive: true);
    await _copyInto(legacy, staging);
    if (await target.exists()) await target.delete(recursive: true);
    await staging.rename(target.path);
    try {
      await legacy.delete(recursive: true);
    } catch (_) {/* an orphan legacy folder is harmless; target owns the data */}
    return true;
  } catch (_) {
    return false; // migration must never block startup; worst case = old home
  }
}

Future<bool> _isHeldOpen(File f) async {
  try {
    final raf = await f.open(mode: FileMode.append);
    await raf.close();
    return false;
  } catch (_) {
    return true;
  }
}

Future<void> _copyInto(Directory from, Directory to) async {
  await to.create(recursive: true);
  await for (final e in from.list()) {
    final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (e is File) {
      await e.copy('${to.path}\\$name');
    } else if (e is Directory) {
      await _copyInto(e, Directory('${to.path}\\$name'));
    }
  }
}
