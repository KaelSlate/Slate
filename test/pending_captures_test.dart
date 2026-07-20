import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/state/pending_captures.dart';

/// Emergency spill: captures made while the vault is unopenable append to a
/// jsonl file and flow into the Inbox on the next good start. A capture must
/// never be lost to a storage problem the user can't even see.
void main() {
  late Directory dir;
  File spill() => File('${dir.path}\\pending_captures.jsonl');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('slate_pending_test');
  });

  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  test('line codec round-trips title, tags and priority', () {
    final line = PendingCaptures.encodeLine('call mom',
        tags: const ['family'], priority: 2);
    final back = PendingCaptures.decodeLine(line);
    expect(back, isNotNull);
    expect(back!.title, 'call mom');
    expect(back.tags, ['family']);
    expect(back.priority, 2);
  });

  test('garbage lines decode to null instead of throwing', () {
    expect(PendingCaptures.decodeLine('not json'), isNull);
    expect(PendingCaptures.decodeLine('{"no_title":1}'), isNull);
    expect(PendingCaptures.decodeLine(''), isNull);
  });

  test('append accumulates; drain returns everything and removes the file',
      () async {
    await PendingCaptures.appendTo(spill(), 'first thought');
    await PendingCaptures.appendTo(spill(), 'second',
        tags: const ['a'], priority: 1);

    final drained = await PendingCaptures.drainFile(spill());
    expect(drained.map((e) => e.title).toList(), ['first thought', 'second']);
    expect(drained[1].tags, ['a']);
    expect(await spill().exists(), isFalse,
        reason: 'drained means drained — no double import on next start');

    expect(await PendingCaptures.drainFile(spill()), isEmpty);
  });
}
