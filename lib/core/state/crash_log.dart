import 'dart:io';

import '../app_version.dart';

/// Crash log — Documents/slate_data/logs/slate_log.txt, next to the DB.
/// Size-capped with a one-file rotation (slate_log.1.txt). Writes are
/// SYNCHRONOUS: a crashing process has no "later". Errors that arrive
/// before the Documents dir is known are buffered and flushed on init.
class CrashLog {
  CrashLog._();

  static Directory? _dir;
  static final List<String> _pending = [];
  static const _maxBytes = 512 * 1024;

  static final List<String> _trace = [];
  static const _traceCap = 400;

  /// In-memory breadcrumbs (window morph, foreground handoffs). Zero I/O on
  /// the hot path; dumped into crash records and by "Report a problem".
  static void trace(String msg) {
    _trace.add('${DateTime.now().toIso8601String()} $msg');
    if (_trace.length > _traceCap) _trace.removeAt(0);
  }

  /// Snapshot for "Report a problem" — slate_trace.txt next to the log.
  static String? dumpTrace() {
    final dir = _dir;
    if (dir == null) return null;
    try {
      final f = File('${dir.path}\\slate_trace.txt');
      f.writeAsStringSync('${_trace.join('\n')}\n', flush: true);
      return f.path;
    } catch (_) {
      return null;
    }
  }

  static void init(Directory logsDir) {
    _dir = logsDir;
    try {
      logsDir.createSync(recursive: true);
    } catch (_) {}
    for (final e in _pending) {
      _append(e);
    }
    _pending.clear();
  }

  /// Folder shown by the tray's "Report a problem".
  static String? get folderPath => _dir?.path;

  static void record(Object error, StackTrace? stack,
      {String source = 'dart'}) {
    final entry = StringBuffer()
      ..writeln('──── ${DateTime.now().toIso8601String()} '
          '· Slate v$kAppVersion · $source')
      ..writeln(error)
      ..writeln(stack ?? StackTrace.current);
    if (_trace.isNotEmpty) {
      entry.writeln('· trace tail:');
      _trace
          .skip(_trace.length <= 40 ? 0 : _trace.length - 40)
          .forEach(entry.writeln);
    }
    entry.writeln();
    final s = entry.toString();
    if (_dir == null) {
      _pending.add(s);
      if (_pending.length > 32) _pending.removeAt(0);
      return;
    }
    _append(s);
  }

  static void _append(String s) {
    try {
      final f = File('${_dir!.path}\\slate_log.txt');
      if (f.existsSync() && f.lengthSync() > _maxBytes) {
        final old = File('${_dir!.path}\\slate_log.1.txt');
        if (old.existsSync()) old.deleteSync();
        f.renameSync(old.path);
      }
      f.writeAsStringSync(s, mode: FileMode.append, flush: true);
    } catch (_) {/* logging must never take the app down */}
  }
}
