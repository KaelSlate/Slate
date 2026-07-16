import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/engine/capture_destination.dart';
import 'package:slate/core/engine/slate_core_bridge.dart';

void main() {
  final now = DateTime(2026, 7, 3, 18, 0); // пятница, 18:00

  test('no date, no time -> inbox', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x'), now);
    expect(d.toInbox, true);
    expect(d.label, 'Inbox');
  });

  test('time in future -> today', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', startTime: 19 * 60), now);
    expect(d.toInbox, false);
    expect(d.day, DateTime(2026, 7, 3));
    expect(d.startTime, 19 * 60);
    expect(d.label, 'Today 19:00');
  });

  test('time passed -> rolls to tomorrow', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', startTime: 9 * 60), now);
    expect(d.day, DateTime(2026, 7, 4));
    expect(d.label, 'Tomorrow 09:00');
  });

  test('viewedDay: no roll, no inbox', () {
    final v = DateTime(2026, 7, 3);
    final d = resolveCapture(
        const ParseResult(cleanTitle: 'x', startTime: 9 * 60), now, viewedDay: v);
    expect(d.day, v);
    final d2 = resolveCapture(const ParseResult(cleanTitle: 'x'), now, viewedDay: v);
    expect(d2.toInbox, false);
    expect(d2.day, v);
  });

  test('offset date without time -> that day unallocated', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', dateKind: 1, dateA: 1), now);
    expect(d.day, DateTime(2026, 7, 4));
    expect(d.startTime, null);
    expect(d.label, 'Tomorrow');
  });

  test('weekday resolves to nearest, today included', () {
    final d = resolveCapture(const ParseResult(cleanTitle: 'x', dateKind: 2, dateA: 5), now);
    expect(d.day, DateTime(2026, 7, 3));
    final d2 = resolveCapture(const ParseResult(cleanTitle: 'x', dateKind: 2, dateA: 1), now);
    expect(d2.day, DateTime(2026, 7, 6));
    expect(d2.label, 'Mon · Jul 6');
  });

  test('explicit future date stays this year', () {
    final d = resolveCapture(
        const ParseResult(cleanTitle: 'x', dateKind: 3, dateB: 7, dateC: 15), now);
    expect(d.day, DateTime(2026, 7, 15));
  });

  // Problem 3: an explicit PAST date is HONORED (never a silent +1-year roll)
  // and the label carries its age so the user sees it before Enter.
  test('explicit past date is honored, not rolled to next year', () {
    final past = resolveCapture(
        const ParseResult(cleanTitle: 'x', dateKind: 3, dateB: 1, dateC: 10), now);
    expect(past.day, DateTime(2026, 1, 10)); // this year, in the past — NOT 2027
    expect(past.toInbox, false);
  });

  test('past date label shows a calm age', () {
    // 2 days ago (Jul 1) → "Jul 1 · 2d ago"
    final d2 = resolveCapture(
        const ParseResult(cleanTitle: 'x', dateKind: 3, dateB: 7, dateC: 1), now);
    expect(d2.day, DateTime(2026, 7, 1));
    expect(d2.label, 'Jul 1 · 2d ago');
    // 10 days ago (Jun 23) → weeks
    final dw = resolveCapture(
        const ParseResult(cleanTitle: 'x', dateKind: 3, dateB: 6, dateC: 23), now);
    expect(dw.label, 'Jun 23 · 1w ago');
  });

  test('yesterday label', () {
    final d = resolveCapture(
        const ParseResult(cleanTitle: 'x', dateKind: 3, dateB: 7, dateC: 2), now);
    expect(d.day, DateTime(2026, 7, 2));
    expect(d.label, 'Yesterday');
  });

  test('explicit year is honored exactly', () {
    final d = resolveCapture(
        const ParseResult(cleanTitle: 'x', dateKind: 3, dateA: 2027, dateB: 1, dateC: 10),
        now);
    expect(d.day, DateTime(2027, 1, 10));
  });

  test('date + time -> both', () {
    final d = resolveCapture(
        const ParseResult(cleanTitle: 'x', dateKind: 2, dateA: 1, startTime: 600, endTime: 660),
        now);
    expect(d.day, DateTime(2026, 7, 6));
    expect(d.startTime, 600);
    expect(d.label, 'Mon · Jul 6 10:00');
  });

  // Problem 4: in a TARGETED pill the pinned day always wins — a typed date
  // never re-routes the task. (The targeted parse yields dateKind 0 in practice;
  // this asserts the resolver ignores any date token when viewedDay is set.)
  test('targeted day wins over a typed date', () {
    final v = DateTime(2026, 7, 10);
    final d = resolveCapture(
        const ParseResult(cleanTitle: 'x', dateKind: 1, dateA: 1), now, viewedDay: v);
    expect(d.day, v); // stays on the pinned day, not tomorrow
    expect(d.toInbox, false);
  });

  test('targeted day keeps a typed time within the day', () {
    final v = DateTime(2026, 7, 10);
    final d = resolveCapture(
        const ParseResult(cleanTitle: 'x', startTime: 600, endTime: 660), now,
        viewedDay: v);
    expect(d.day, v);
    expect(d.startTime, 600);
  });
}
