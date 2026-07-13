import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../app_version.dart';
import '../engine/slate_core_bridge.dart';

/// "Your data is never locked in" — the tray's Export writes every task as
/// human-readable JSON into Documents. Field completeness is the law: title,
/// day, times, tags, done, inbox, priority, created/updated — nothing lost.

String _two(int n) => n.toString().padLeft(2, '0');

String _isoLocal(int ms) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  return '${d.year}-${_two(d.month)}-${_two(d.day)}T'
      '${_two(d.hour)}:${_two(d.minute)}:${_two(d.second)}';
}

String? _hhmm(int? minutes) {
  if (minutes == null) return null;
  return '${_two((minutes ~/ 60) % 24)}:${_two(minutes % 60)}';
}

/// Stable, human-readable export document. Pure — unit-testable without IO.
String buildExportJson(List<RustTask> tasks, {DateTime? now}) {
  final ts = now ?? DateTime.now();
  final doc = {
    'app': 'Slate',
    'version': kAppVersion,
    'exported_at':
        _isoLocal(ts.millisecondsSinceEpoch),
    'task_count': tasks.length,
    'tasks': [
      for (final t in tasks)
        {
          'id': t.id,
          'title': t.title,
          'completed': t.isCompleted,
          'inbox': t.isInbox,
          // Inbox thoughts have no day — their createdAt is the capture time.
          'day': t.isInbox
              ? null
              : _isoLocal(t.createdAt).substring(0, 10),
          'start_time': _hhmm(t.startTime),
          'end_time': _hhmm(t.endTime),
          'priority': t.priority,
          'tags': t.tags,
          'created_at': _isoLocal(t.createdAt),
          'updated_at': _isoLocal(t.updatedAt),
        },
    ],
  };
  return const JsonEncoder.withIndent('  ').convert(doc);
}

/// Writes the export into Documents and returns the file (the tray opens
/// Explorer with it selected). Filename carries a local timestamp.
Future<File> exportAllTasks(SlateCore core) async {
  final dir = await getApplicationDocumentsDirectory();
  final n = DateTime.now();
  final name = 'Slate export ${n.year}-${_two(n.month)}-${_two(n.day)} '
      '${_two(n.hour)}-${_two(n.minute)}.json';
  final file = File('${dir.path}\\$name');
  await file.writeAsString(buildExportJson(core.getAllTasks()));
  return file;
}
