import 'dart:async';

import 'package:flutter/foundation.dart';

/// The one owner of "what day is it".
///
/// Every view used to answer that with its own `DateTime.now()` at build time —
/// right at the moment of the build and wrong forever after. An app left open
/// overnight kept yesterday highlighted, and the week view (which recomputes per
/// build) could disagree with the day view (which does not). Anything that
/// carries a day cannot be built on that: a carry-forward line waking at 00:05
/// would say "yesterday" meaning the day before, and move tasks into a day
/// nobody is looking at.
///
/// The tick is always recomputed from the wall clock, never from a counter, and
/// never sleeps longer than [maxSleepMs]. That is why sleep, hibernation, a
/// changed system clock and a DST boundary need no handling at all — worst case
/// after a lid opens is one tick. Same discipline as ReminderScheduler.
class DayClock extends ValueNotifier<DateTime> {
  DayClock({DateTime Function()? now})
      : _now = now ?? DateTime.now,
        super(dateOnly((now ?? DateTime.now)()));

  static final DayClock instance = DayClock();

  final DateTime Function() _now;
  Timer? _timer;

  /// Never doze past this, however far midnight is. Keeps the worst-case lag
  /// after a resume to one minute instead of a whole night.
  static const int maxSleepMs = 60 * 1000;

  static const int _minSleepMs = 250;

  /// Land just PAST midnight — waking a hair early re-reads the same date and
  /// costs a whole wasted cycle.
  static const int _wakeSlackMs = 40;

  /// Today at local midnight. Never carries a time.
  DateTime get today => value;

  /// Local midnight of [d]. The one place the whole app strips a time.
  static DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// True when [d] is today. Cheap enough to call per build.
  bool isToday(DateTime d) => dateOnly(d) == value;

  void start() {
    if (_timer != null) return;
    _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// How long to sleep before looking again. Pure and testable: the nearer of
  /// "next local midnight" and [maxSleepMs].
  ///
  /// Midnight comes from the DateTime constructor with an overflowing day, not
  /// from `add(Duration(days: 1))` — a DST day is 23 or 25 hours long, and only
  /// the constructor knows that.
  @visibleForTesting
  int sleepMs() {
    final at = _now();
    final midnight = DateTime(at.year, at.month, at.day + 1);
    final until = midnight.difference(at).inMilliseconds + _wakeSlackMs;
    if (until > maxSleepMs) return maxSleepMs;
    return until < _minSleepMs ? _minSleepMs : until;
  }

  void _schedule() {
    _timer = Timer(Duration(milliseconds: sleepMs()), () {
      _timer = null;
      pump();
      _schedule();
    });
  }

  /// One pass with no timer behind it — tests drive the clock themselves rather
  /// than waiting on real midnights. ValueNotifier only speaks on a real change,
  /// so a tick inside the same day is silent.
  @visibleForTesting
  void pump() => value = dateOnly(_now());

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
