import 'dart:io';

/// The silent safety net behind «your data is never locked in»: once a day the
/// full export JSON lands in slate_data\backups as plain text. The SQLCipher
/// key lives in DPAPI and dies with the Windows profile — these files don't.

String _dateName(DateTime d) => 'tasks ${d.year}'
    '-${d.month.toString().padLeft(2, '0')}'
    '-${d.day.toString().padLeft(2, '0')}.json';

/// Writes at most one backup per calendar day; [refresh] (the quit hook)
/// rewrites today's file with the freshest state. Keeps the newest [keep]
/// files. Returns the written file, or null when today is already covered.
/// Never throws — a failed backup must not surface at startup or quit.
Future<File?> maybeWriteDailyBackup(String json, Directory dir,
    {DateTime? now, int keep = 7, bool refresh = false}) async {
  try {
    final ts = now ?? DateTime.now();
    await dir.create(recursive: true);
    final f = File('${dir.path}\\${_dateName(ts)}');
    if (!refresh && await f.exists()) return null;
    await f.writeAsString(json, flush: true);

    // ISO dates sort lexically, so filename order IS age order.
    final files = (await dir.list().toList())
        .whereType<File>()
        .where((e) => e.path.endsWith('.json'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (var i = 0; i < files.length - keep; i++) {
      try {
        await files[i].delete();
      } catch (_) {}
    }
    return f;
  } catch (_) {
    return null;
  }
}
