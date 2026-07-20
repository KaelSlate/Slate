import 'dart:convert';
import 'dart:io';

import 'app_dirs.dart';

/// Emergency spill for captures made while the vault is unopenable: one JSON
/// per line; the next good start drains every line into the Inbox. A capture
/// must never be lost to a storage problem the user can't even see.

class PendingCapture {
  final String title;
  final List<String> tags;
  final int priority;
  const PendingCapture(this.title, this.tags, this.priority);
}

class PendingCaptures {
  PendingCaptures._();

  static String encodeLine(String title,
          {List<String> tags = const [], int priority = 0}) =>
      jsonEncode({'t': title, 'g': tags, 'p': priority});

  /// Tolerant by design: a corrupt line becomes null, never an exception —
  /// one bad byte must not take the rest of the spill down with it.
  static PendingCapture? decodeLine(String line) {
    try {
      final m = jsonDecode(line);
      if (m is! Map || m['t'] is! String) return null;
      final title = (m['t'] as String).trim();
      if (title.isEmpty) return null;
      return PendingCapture(
        title,
        (m['g'] as List?)?.whereType<String>().toList() ?? const [],
        (m['p'] as num?)?.toInt() ?? 0,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> appendTo(File f, String title,
      {List<String> tags = const [], int priority = 0}) async {
    try {
      await f.parent.create(recursive: true);
      await f.writeAsString(
        '${encodeLine(title, tags: tags, priority: priority)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {/* best-effort — must never throw back into the pill */}
  }

  /// Reads every valid line and deletes the file — drained means drained,
  /// so a capture can never be imported twice.
  static Future<List<PendingCapture>> drainFile(File f) async {
    try {
      if (!await f.exists()) return const [];
      final lines = await f.readAsLines();
      await f.delete();
      final out = <PendingCapture>[];
      for (final l in lines) {
        final c = decodeLine(l);
        if (c != null) out.add(c);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static Future<File> _file() async =>
      File('${(await AppDirs.dataDir()).path}\\pending_captures.jsonl');

  static Future<void> append(String title,
          {List<String> tags = const [], int priority = 0}) async =>
      appendTo(await _file(), title, tags: tags, priority: priority);

  static Future<List<PendingCapture>> drain() async => drainFile(await _file());
}
