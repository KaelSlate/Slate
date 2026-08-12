import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/engine/reminder_scheduler.dart';
import 'package:slate/core/engine/slate_core_bridge.dart';

/// The etiquette of speaking, proved without a window, a clock or a speaker.
void main() {
  // A fixed instant; every test moves this by hand rather than waiting.
  const t0 = 1800000000000;

  DueReminder ripe(String id,
          {int slot = t0, int minutes = 18 * 60, int priority = 0}) =>
      DueReminder(
        id: id,
        title: 'Dinner',
        slotMs: slot,
        dayStartMs: t0 - 64800000,
        startTime: minutes,
        priority: priority,
      );

  ReminderCard card(int priority) => ReminderCard(
        id: 'c$priority',
        title: 'x',
        time: '18:00',
        lede: 'in 5 minutes',
        dayStartMs: 0,
        slotMs: 0,
        priority: priority,
      );

  group('speaking', () {
    late List<List<ReminderCard>> presented;
    late List<bool> mergeFlags;
    late List<int> lifeSpans;
    late List<String> marked;
    late List<int> chimePriorities;
    late int chimes;
    late int clock;
    late List<DueReminder> pending;
    late bool allowed;
    late bool on;
    late bool presentSucceeds;

    ReminderScheduler build() => ReminderScheduler(
          due: (_) => pending,
          nextAt: (_) => null,
          mark: (id, slot, at) {
            marked.add('$id@$slot');
            return true;
          },
          present: (cards, merging, lifeMs) async {
            presented.add(List.of(cards));
            mergeFlags.add(merging);
            lifeSpans.add(lifeMs);
            return presentSucceeds;
          },
          chime: (priority) {
            chimes++;
            chimePriorities.add(priority);
          },
          enabled: () => on,
          canNotify: () => allowed,
          now: () => clock,
        );

    setUp(() {
      presented = [];
      mergeFlags = [];
      lifeSpans = [];
      marked = [];
      chimePriorities = [];
      chimes = 0;
      clock = t0;
      pending = [];
      allowed = true;
      on = true;
      presentSucceeds = true;
    });

    test('a due moment shows once, rings once, and is sealed', () async {
      pending = [ripe('a')];
      final s = build();
      await s.pump();

      expect(presented, hasLength(1));
      expect(presented.single.single.title, 'Dinner');
      expect(presented.single.single.time, '18:00');
      expect(chimes, 1);
      expect(marked, ['a@$t0']);
    });

    test('nothing due stays completely silent', () async {
      final s = build();
      await s.pump();
      expect(presented, isEmpty);
      expect(chimes, 0);
      expect(marked, isEmpty);
    });

    test('a suppressed moment is NOT sealed, so it can still speak', () async {
      // Focus Assist, a full-screen game, a locked screen.
      allowed = false;
      pending = [ripe('a')];
      final s = build();
      await s.pump();

      expect(presented, isEmpty);
      expect(chimes, 0);
      expect(marked, isEmpty, reason: 'sealing here would lose it forever');

      // Windows relents on a later tick, still inside the grace window.
      allowed = true;
      await s.pump();
      expect(presented, hasLength(1));
      expect(marked, ['a@$t0']);
    });

    test('a card that failed to appear is never sealed', () async {
      // The most expensive failure in the feature: mark without showing and the
      // person never learns the reminder existed.
      presentSucceeds = false;
      pending = [ripe('a')];
      final s = build();
      await s.pump();

      expect(marked, isEmpty);
      expect(chimes, 0);
    });

    test('turned off in the tray means no card and no seal', () async {
      on = false;
      pending = [ripe('a')];
      final s = build();
      await s.pump();

      expect(presented, isEmpty);
      expect(marked, isEmpty);
    });

    test('two moments close together grow one card and ring once', () async {
      pending = [ripe('a')];
      final s = build();
      await s.pump();
      expect(chimes, 1);

      // A second task comes due 30 seconds later — same event, not a new one.
      clock += 30000;
      pending = [ripe('b', slot: clock)];
      await s.pump();

      expect(presented, hasLength(2));
      expect(mergeFlags.last, isTrue);
      expect(presented.last, hasLength(2), reason: 'the card grew');
      expect(chimes, 1, reason: 'growing a live card must not ring again');
      expect(marked, ['a@$t0', 'b@$clock']);
    });

    test('a moment past the merge window is a new card with its own sound',
        () async {
      pending = [ripe('a')];
      final s = build();
      await s.pump();

      clock += ReminderScheduler.mergeWindowMs + 1;
      pending = [ripe('b', slot: clock)];
      await s.pump();

      expect(mergeFlags.last, isFalse);
      expect(presented.last, hasLength(1));
      expect(chimes, 2);
    });

    test('a dismissed card does not get merged into', () async {
      pending = [ripe('a')];
      final s = build();
      await s.pump();

      s.cardClosed();
      clock += 5000;
      pending = [ripe('b', slot: clock)];
      await s.pump();

      expect(mergeFlags.last, isFalse);
      expect(chimes, 2);
    });
  });

  group('sleep horizon', () {
    ReminderScheduler withNext(int? next, int nowMs) => ReminderScheduler(
          due: (_) => const [],
          nextAt: (_) => next,
          mark: (id, slot, at) => true,
          present: (cards, merging, lifeMs) async => true,
          chime: (priority) {},
          now: () => nowMs,
        );

    test('never sleeps longer than the ceiling', () {
      expect(withNext(null, t0).sleepMs(), ReminderScheduler.maxSleepMs);
      expect(withNext(t0 + 3600000, t0).sleepMs(), ReminderScheduler.maxSleepMs);
    });

    test('wakes just PAST a nearer moment, never before it', () {
      // Landing a hair early makes due() return nothing and burns a whole
      // cycle, so the horizon deliberately overshoots by a few ms.
      final sleep = withNext(t0 + 12000, t0).sleepMs();
      expect(sleep, greaterThanOrEqualTo(12000));
      expect(sleep, lessThan(12200));
    });

    test('a moment in the past does not spin the loop', () {
      expect(withNext(t0 - 500000, t0).sleepMs(), greaterThan(0));
    });
  });

  group('importance decides patience, never whether we speak', () {
    test('a plain task shows itself out, ! waits longer, !! waits', () {
      expect(ReminderScheduler.lifeMsFor(0), 7000);
      expect(ReminderScheduler.lifeMsFor(1), 14000);
      expect(ReminderScheduler.lifeMsFor(2), 0, reason: '0 = stays put');
    });

    test('one insistent row keeps the whole stack open', () {
      expect(
        ReminderScheduler.lifeMsForBatch([card(0), card(2), card(0)]),
        0,
      );
    });

    test('more to read means more time to read it', () {
      final one = ReminderScheduler.lifeMsForBatch([card(0)]);
      final three =
          ReminderScheduler.lifeMsForBatch([card(0), card(0), card(0)]);
      expect(one, 7000);
      expect(three, greaterThan(one),
          reason: 'a card that shuts mid-sentence is worse than none');
      expect(three, 12000);
    });

    test('the chime carries the loudest priority in the batch', () async {
      // Built inline: this group has no fixtures of its own.
      final rings = <int>[];
      final s = ReminderScheduler(
        due: (_) => [
          DueReminder(
              id: 'a',
              title: 'x',
              slotMs: 0,
              dayStartMs: 0,
              startTime: 540,
              priority: 0),
          DueReminder(
              id: 'b',
              title: 'y',
              slotMs: 0,
              dayStartMs: 0,
              startTime: 540,
              priority: 2),
        ],
        nextAt: (_) => null,
        mark: (id, slot, at) => true,
        present: (cards, merging, lifeMs) async => true,
        chime: rings.add,
        now: () => 0,
      );
      await s.pump();
      expect(rings, [2]);
    });
  });

  group('knowing when NOT to speak', () {
    ReminderScheduler build({
      required bool focused,
      int? idle,
      required List<String> marked,
      required List<int> shows,
    }) =>
        ReminderScheduler(
          due: (_) => [
            DueReminder(
                id: 'a',
                title: 'x',
                slotMs: 5,
                dayStartMs: 0,
                startTime: 540,
                priority: 0)
          ],
          nextAt: (_) => null,
          mark: (id, slot, at) {
            marked.add(id);
            return true;
          },
          present: (cards, merging, lifeMs) async {
            shows.add(cards.length);
            return true;
          },
          chime: (_) {},
          appInFocus: () => focused,
          idleMs: () => idle,
          now: () => 100,
        );

    test('Slate on screen: no card, and the moment counts as delivered',
        () async {
      final marked = <String>[];
      final shows = <int>[];
      final s = build(focused: true, marked: marked, shows: shows);
      await s.pump();

      expect(shows, isEmpty, reason: 'the task is already in front of them');
      expect(marked, ['a'], reason: 'delivered by being visible, not by a card');
    });

    test('mid-keystroke: waits for the pause, seals nothing', () async {
      final marked = <String>[];
      final shows = <int>[];
      final s = build(
          focused: false,
          idle: ReminderScheduler.typingGuardMs - 1,
          marked: marked,
          shows: shows);
      await s.pump();

      expect(shows, isEmpty, reason: 'landing between two words is the rudest');
      expect(marked, isEmpty, reason: 'it still owes the person this reminder');
      expect(s.sleepMs(), ReminderScheduler.typingRetryMs,
          reason: 'come back the moment the burst ends');
    });

    test('once the typing stops it speaks', () async {
      final marked = <String>[];
      final shows = <int>[];
      final s = build(
          focused: false,
          idle: ReminderScheduler.typingGuardMs + 1,
          marked: marked,
          shows: shows);
      await s.pump();

      expect(shows, [1]);
      expect(marked, ['a']);
    });

    test('an unknown idle never blocks a reminder', () async {
      // A machine where the probe cannot load must not go silent.
      final marked = <String>[];
      final shows = <int>[];
      final s =
          build(focused: false, idle: null, marked: marked, shows: shows);
      await s.pump();
      expect(shows, [1]);
    });
  });

  group('sleeping', () {
    test('a refused moment makes the loop watch instead of doze', () async {
      // Quitting a full-screen game at 18:00:05 must not mean waiting until
      // 18:01 for the card.
      final s = ReminderScheduler(
        due: (_) => [
          DueReminder(
              id: 'a',
              title: 'x',
              slotMs: 0,
              dayStartMs: 0,
              startTime: 540,
              priority: 0)
        ],
        nextAt: (_) => null,
        mark: (id, slot, at) => true,
        present: (cards, merging, lifeMs) async => true,
        chime: (_) {},
        canNotify: () => false,
        now: () => 0,
      );
      expect(s.sleepMs(), ReminderScheduler.maxSleepMs);
      await s.pump();
      expect(s.sleepMs(), ReminderScheduler.suppressedSleepMs);
    });
  });

  group('time reads as the person wrote it', () {
    test('zero-padded 24-hour', () {
      expect(ReminderScheduler.formatTime(18 * 60), '18:00');
      expect(ReminderScheduler.formatTime(9 * 60 + 5), '09:05');
      expect(ReminderScheduler.formatTime(0), '00:00');
      expect(ReminderScheduler.formatTime(23 * 60 + 59), '23:59');
    });

    test('an unallocated task has no time string', () {
      expect(ReminderScheduler.formatTime(-1), '');
    });
  });

  group('the card never lies about how far ahead it is', () {
    /// Wall clock on the machine's own calendar — the same clock the card is
    /// read on, and the same one Rust resolved the slot against.
    int at(int hour, int minute) {
      final n = DateTime.now();
      return DateTime(n.year, n.month, n.day, hour, minute)
          .millisecondsSinceEpoch;
    }

    test('the ordinary case: five minutes ahead', () {
      // Numerals, not words: the moment a row can say "in 35 minutes", spelling
      // the small numbers out makes two rows of the same stack disagree about
      // their own typography.
      expect(ReminderScheduler.formatLede(18 * 60, at(17, 55)),
          'in 5 minutes');
    });

    test('a merged row with a LATER time says a longer sentence', () {
      // The exact row that exposed the bug: a stack showing 18:00 and 18:30
      // where both claimed "in five minutes".
      expect(
          ReminderScheduler.formatLede(18 * 60 + 30, at(17, 55)),
          'in 35 minutes');
    });

    test('arriving late inside the grace window never says "late"', () {
      expect(ReminderScheduler.formatLede(18 * 60, at(18, 1)), 'now');
      expect(ReminderScheduler.formatLede(18 * 60, at(18, 30)), 'now');
    });

    test('one minute is a word, not a numeral', () {
      expect(ReminderScheduler.formatLede(18 * 60, at(17, 59)), 'in a minute');
      expect(ReminderScheduler.formatLede(18 * 60, at(18, 0)), 'now');
    });
  });
}
