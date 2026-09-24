import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/engine/day_clock.dart';

/// The one owner of "what day is it", proved without waiting for a midnight.
void main() {
  late DateTime nowValue;
  DayClock clockAt(DateTime t) {
    nowValue = t;
    return DayClock(now: () => nowValue);
  }

  group('sleepMs', () {
    test('dozes no longer than a minute when midnight is far', () {
      final c = clockAt(DateTime(2026, 8, 18, 9, 0));
      expect(c.sleepMs(), DayClock.maxSleepMs);
    });

    test('lands just past midnight when it is close', () {
      final c = clockAt(DateTime(2026, 8, 18, 23, 59, 30));
      // 30s to go, plus the slack that stops us re-reading the same date.
      expect(c.sleepMs(), 30040);
    });

    test('never spins when midnight is a heartbeat away', () {
      final c = clockAt(DateTime(2026, 8, 18, 23, 59, 59, 990));
      expect(c.sleepMs(), greaterThanOrEqualTo(250));
    });

    // A DST day is 23 or 25 hours long. Both must still be exactly 30s from
    // their own midnight at 23:59:30 — that is the whole reason the next
    // midnight comes from the DateTime constructor and not from add(Duration).
    // Timezone-independent: true wherever this runs.
    for (final d in const [
      [2026, 3, 29], // Kyiv springs forward
      [2026, 10, 25], // Kyiv falls back
      [2026, 8, 18], // an ordinary day, as a control
    ]) {
      test('30s from midnight on ${d[0]}-${d[1]}-${d[2]}', () {
        final c = clockAt(DateTime(d[0], d[1], d[2], 23, 59, 30));
        expect(c.sleepMs(), 30040);
      });
    }
  });

  group('the day turning over', () {
    test('a tick inside the same day says nothing', () {
      final c = clockAt(DateTime(2026, 8, 18, 9, 0));
      var beats = 0;
      c.addListener(() => beats++);
      nowValue = DateTime(2026, 8, 18, 23, 59, 59);
      c.pump();
      expect(beats, 0);
      expect(c.today, DateTime(2026, 8, 18));
    });

    test('midnight moves the day, exactly once', () {
      final c = clockAt(DateTime(2026, 8, 18, 23, 59, 59));
      var beats = 0;
      c.addListener(() => beats++);
      nowValue = DateTime(2026, 8, 19, 0, 0, 1);
      c.pump();
      c.pump();
      expect(beats, 1);
      expect(c.today, DateTime(2026, 8, 19));
    });

    test('crosses a year boundary', () {
      final c = clockAt(DateTime(2026, 12, 31, 23, 59, 59));
      nowValue = DateTime(2027, 1, 1, 0, 0, 1);
      c.pump();
      expect(c.today, DateTime(2027, 1, 1));
    });

    test('a laptop asleep for three days catches up in one tick', () {
      final c = clockAt(DateTime(2026, 8, 18, 9, 0));
      nowValue = DateTime(2026, 8, 21, 14, 0);
      c.pump();
      expect(c.today, DateTime(2026, 8, 21));
    });

    test('a system clock dragged backwards is still obeyed', () {
      final c = clockAt(DateTime(2026, 8, 18, 9, 0));
      nowValue = DateTime(2026, 8, 16, 9, 0);
      c.pump();
      expect(c.today, DateTime(2026, 8, 16));
    });
  });

  group('today', () {
    test('carries no time', () {
      final c = clockAt(DateTime(2026, 8, 18, 14, 32, 7, 5));
      expect(c.today, DateTime(2026, 8, 18));
    });

    test('isToday ignores the time of day', () {
      final c = clockAt(DateTime(2026, 8, 18, 9, 0));
      expect(c.isToday(DateTime(2026, 8, 18, 23, 59)), isTrue);
      expect(c.isToday(DateTime(2026, 8, 19, 0, 0)), isFalse);
    });
  });

  // Documents the trap the constructor exists to avoid. Only asserts on a
  // machine that actually shifts its clock that night, so it stays green
  // wherever it runs.
  test('add(Duration(days: 1)) would miss midnight across a DST shift', () {
    final before = DateTime(2026, 3, 29);
    final after = DateTime(2026, 3, 30);
    if (before.timeZoneOffset != after.timeZoneOffset) {
      expect(before.add(const Duration(days: 1)), isNot(after));
      expect(DateTime(before.year, before.month, before.day + 1), after);
    }
  });
}
