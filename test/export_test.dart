import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/app_version.dart';
import 'package:slate/core/engine/slate_core_bridge.dart';
import 'package:slate/core/state/export_service.dart';

/// Export completeness contract: every field survives, format is stable and
/// human-readable. Pure serialization — no IO, no engine.
void main() {
  test('export keeps every field of a scheduled task', () {
    final day = DateTime(2026, 7, 15).millisecondsSinceEpoch;
    final t = RustTask(
      id: 'abc-123',
      title: 'Ship the beta',
      isCompleted: true,
      createdAt: day,
      updatedAt: DateTime(2026, 7, 15, 18, 30).millisecondsSinceEpoch,
      startTime: 9 * 60 + 15,
      endTime: 10 * 60 + 45,
      priority: 2,
      tags: ['launch', 'dev'],
    );

    final doc = jsonDecode(buildExportJson([t], now: DateTime(2026, 7, 13)))
        as Map<String, dynamic>;
    expect(doc['app'], 'Slate');
    expect(doc['version'], kAppVersion);
    expect(doc['exported_at'], startsWith('2026-07-13T'));
    expect(doc['task_count'], 1);

    final j = (doc['tasks'] as List).single as Map<String, dynamic>;
    expect(j['id'], 'abc-123');
    expect(j['title'], 'Ship the beta');
    expect(j['completed'], true);
    expect(j['inbox'], false);
    expect(j['day'], '2026-07-15');
    expect(j['start_time'], '09:15');
    expect(j['end_time'], '10:45');
    expect(j['priority'], 2);
    expect(j['tags'], ['launch', 'dev']);
    expect(j['created_at'], startsWith('2026-07-15T'));
    expect(j['updated_at'], '2026-07-15T18:30:00');
  });

  test('inbox thought: no day, capture time preserved, nulls not "null"', () {
    final captured = DateTime(2026, 7, 12, 22, 5, 9).millisecondsSinceEpoch;
    final t = RustTask(
      id: 'inb-1',
      title: 'random spark',
      isCompleted: false,
      createdAt: captured,
      isInbox: true,
    );

    final raw = buildExportJson([t]);
    expect(raw, contains('  "tasks"'), reason: 'indented = human-readable');

    final j = ((jsonDecode(raw) as Map)['tasks'] as List).single
        as Map<String, dynamic>;
    expect(j['inbox'], true);
    expect(j['day'], isNull);
    expect(j['start_time'], isNull);
    expect(j['end_time'], isNull);
    expect(j['created_at'], '2026-07-12T22:05:09');
    expect(j['tags'], isEmpty);
  });
}
