import 'dart:async';

import 'package:flutter/foundation.dart';

import 'slate_core_bridge.dart';
import 'windows_presence.dart';

/// One line on a reminder card, already formatted. The main isolate owns every
/// string in this feature — the notify window is a renderer and never writes
/// copy, so the house voice can only be changed in one place.
@immutable
class ReminderCard {
  const ReminderCard({
    required this.id,
    required this.title,
    required this.time,
    required this.lede,
    required this.dayStartMs,
    required this.slotMs,
    required this.priority,
  });

  final String id;
  final String title;
  /// Wall clock of the task itself, e.g. "18:00" — never the moment we speak.
  final String time;

  /// How far ahead this is, in words, computed PER CARD at the moment we speak.
  ///
  /// It used to be the literal string `in five minutes`, hardcoded in the
  /// renderer. That broke two things at once. It put copy in a window whose
  /// entire contract is that it writes none — and it was simply false: the
  /// grace window lets a card arrive up to two minutes late, and a merged stack
  /// showed three rows reading 18:00, 18:00 and 18:30 while all three claimed
  /// "in five minutes". A card that lies about time is worse than a card that
  /// says nothing.
  final String lede;

  final int dayStartMs;
  final int slotMs;
  /// 0 normal, 1 `!`, 2 `!!`.
  final int priority;

  Map<String, dynamic> toMap() => {
        'id': id,
        'title': title,
        'time': time,
        'lede': lede,
        'dayMs': dayStartMs,
        'priority': priority,
      };
}

/// What the scheduler needs from the world. Every one of these is swapped in
/// tests, which is what makes the whole policy provable without a window, a
/// clock, or an audio device — the same trick `Sfx.sink` uses.
typedef DueSource = List<DueReminder> Function(int nowMs);
typedef MarkSpoken = bool Function(String id, int slotMs, int nowMs);
/// `lifeMs` of 0 means the card does not leave on its own — see [lifeMsFor].
typedef Presenter = Future<bool> Function(
    List<ReminderCard> cards, bool merging, int lifeMs);

/// Decides WHEN Slate speaks. What and how early is Rust's answer; this class
/// owns the etiquette around it.
///
/// The tick is short-horizon and always recomputed from the wall clock, never
/// from a counter — which is why sleep, hibernation and a changed system clock
/// need no handling at all. Worst case after a lid opens is one tick.
class ReminderScheduler {
  ReminderScheduler({
    required this.due,
    required this.nextAt,
    required this.mark,
    required this.present,
    required this.chime,
    this.enabled = _alwaysOn,
    this.canNotify = _alwaysAllowed,
    this.appInFocus = _neverFocused,
    this.idleMs = _unknownIdle,
    this.now = _wallClock,
  });

  /// Wiring against the real app.
  factory ReminderScheduler.live({
    required SlateCore core,
    required Presenter present,
    required void Function(int priority) chime,
    required bool Function() enabled,
    required bool Function() appInFocus,
  }) {
    return ReminderScheduler(
      due: core.dueReminders,
      nextAt: core.nextReminderAt,
      mark: core.markReminded,
      present: present,
      chime: chime,
      enabled: enabled,
      canNotify: () => WindowsPresence.instance.acceptsNotifications,
      appInFocus: appInFocus,
      idleMs: () => WindowsPresence.instance.idleMs(),
    );
  }

  final DueSource due;
  final int? Function(int nowMs) nextAt;
  final MarkSpoken mark;
  final Presenter present;
  /// Carries the loudest priority in the batch — an insistent task should not
  /// sound identical to watering the plants.
  final void Function(int priority) chime;
  final bool Function() enabled;
  final bool Function() canNotify;

  /// Slate's own window is up and focused — the task is already on screen.
  final bool Function() appInFocus;

  /// Milliseconds since the last keystroke or mouse move, null if unknown.
  final int? Function() idleMs;

  final int Function() now;

  static bool _alwaysOn() => true;
  static bool _alwaysAllowed() => true;
  static bool _neverFocused() => false;
  static int? _unknownIdle() => null;
  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Below this the person is mid-keystroke. Interrupting between two words is
  /// the rudest possible moment; waiting for the smallest natural pause costs
  /// seconds and is the difference between a tool that notices you and one that
  /// talks over you.
  static const int typingGuardMs = 1600;

  /// How long to wait out a burst of typing before looking again.
  static const int typingRetryMs = 2000;

  /// Never sleep longer than this, however far the next moment is. Keeps the
  /// worst-case delay after a resume inside the grace window in Rust.
  static const int maxSleepMs = 60 * 1000;

  /// Two moments closer together than this are one event, not two — a person
  /// who wrote 18:00 twice wants one card. Microsoft's own guidance: one
  /// complete notification per event, never several partial ones.
  static const int mergeWindowMs = 60 * 1000;

  /// While Windows is refusing us (a full-screen game, Focus Assist, a locked
  /// screen) the loop watches closely instead of dozing: quitting the game at
  /// 18:00:05 must not mean waiting until 18:01 for the card. Cheap — it is one
  /// system call, and only while something is actually waiting to be said.
  static const int suppressedSleepMs = 5 * 1000;

  /// Don't spin if a moment is a heartbeat away. A few ms of overshoot past the
  /// target beats waking up just before it and doing a wasted round trip.
  static const int _minSleepMs = 250;
  static const int _wakeSlackMs = 40;

  Timer? _timer;
  bool _ticking = false;
  int _lastShownAt = -1;
  final List<ReminderCard> _onScreen = [];

  /// Something was ripe last tick and Windows refused it. Drives the fast poll.
  bool _suppressed = false;

  /// Held back because the person was mid-keystroke.
  bool _typing = false;

  @visibleForTesting
  List<ReminderCard> get onScreen => List.unmodifiable(_onScreen);

  void start() {
    if (_timer != null) return;
    _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The card went away — by itself, by a tick, or by the capture pill taking
  /// the screen. The next due moment starts a fresh card rather than growing
  /// this one.
  void cardClosed() {
    _onScreen.clear();
    _lastShownAt = -1;
  }

  /// Tasks changed under us (captured, edited, dragged): the next moment may
  /// now be sooner than the sleep we are sitting on.
  void reschedule() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    _schedule();
  }

  /// How long to sleep before looking again. Pure and testable: the horizon is
  /// the nearest of "the next moment" and [maxSleepMs].
  @visibleForTesting
  int sleepMs() {
    // Something is due but the moment is wrong — watch closely rather than
    // doze, so the card lands the instant the moment becomes right.
    if (_typing) return typingRetryMs;
    if (_suppressed) return suppressedSleepMs;
    final at = now();
    var delay = maxSleepMs;
    final next = nextAt(at);
    if (next != null) {
      // Land just PAST the moment. Waking a few ms early makes due() return
      // nothing and costs a whole wasted cycle.
      final until = next - at + _wakeSlackMs;
      if (until < delay) delay = until;
    }
    return delay < _minSleepMs ? _minSleepMs : delay;
  }

  void _schedule() {
    _timer = Timer(Duration(milliseconds: sleepMs()), () {
      _timer = null;
      _tick();
    });
  }

  Future<void> _tick() async {
    if (_ticking) {
      _schedule();
      return;
    }
    _ticking = true;
    try {
      await _speakIfDue();
    } catch (e) {
      debugPrint('reminders: tick failed: $e');
    } finally {
      _ticking = false;
      _schedule();
    }
  }

  Future<void> _speakIfDue() async {
    if (!enabled()) {
      _suppressed = false;
      return;
    }

    final at = now();
    final ripe = due(at);
    if (ripe.isEmpty) {
      _suppressed = false;
      return;
    }

    // Asked at the moment of the decision, never cached: Windows sends no event
    // when a game goes full screen. Nothing is marked spoken here — a suppressed
    // moment stays unspoken and gets another chance on the next tick, until the
    // grace window in Rust closes it for good. While refused, the loop polls
    // every few seconds instead of dozing a full minute.
    if (!canNotify()) {
      _suppressed = true;
      return;
    }
    _suppressed = false;

    // Slate is open and focused: the task is already on the screen the person
    // is looking at. A card here would be the app telling you what you can
    // plainly see. Sealed rather than deferred — it HAS been delivered, just
    // not by a banner.
    if (appInFocus()) {
      for (final r in ripe) {
        mark(r.id, r.slotMs, at);
      }
      return;
    }

    // Mid-keystroke. Wait for the smallest pause rather than landing between
    // two words — same moment, far less rude. Nothing is sealed, so it speaks
    // as soon as the burst ends.
    final idle = idleMs();
    if (idle != null && idle < typingGuardMs) {
      _typing = true;
      return;
    }
    _typing = false;

    final cards = ripe.map((r) => _toCard(r, at)).toList();
    final merging = _onScreen.isNotEmpty &&
        _lastShownAt >= 0 &&
        at - _lastShownAt < mergeWindowMs;

    final batch = merging ? [..._onScreen, ...cards] : cards;
    final shown = await present(batch, merging, lifeMsForBatch(batch));

    // The single most important line in the feature: a moment is only ever
    // sealed once it has actually been seen. Marking a card that failed to
    // appear loses the reminder forever, and the person never learns it existed.
    if (!shown) return;

    _onScreen
      ..clear()
      ..addAll(batch);
    _lastShownAt = at;

    for (final c in cards) {
      mark(c.id, c.slotMs, at);
    }

    // One sound per event, not per card: growing a card that is already on
    // screen must not ring again.
    if (!merging) {
      var loudest = 0;
      for (final c in cards) {
        if (c.priority > loudest) loudest = c.priority;
      }
      chime(loudest);
    }
  }

  ReminderCard _toCard(DueReminder r, int atMs) => ReminderCard(
        id: r.id,
        title: r.title,
        time: formatTime(r.startTime),
        lede: formatLede(r.startTime, atMs),
        dayStartMs: r.dayStartMs,
        slotMs: r.slotMs,
        priority: r.priority,
      );

  /// How far ahead the task is, said the way the house says things: lowercase,
  /// no count of anything undone, and never the word "late".
  ///
  /// Measured in WALL-CLOCK minutes — `startTime` is already DST-resolved by
  /// Rust, and the current minute comes from the local calendar. That is why
  /// the lead is not a parameter here: it lives in exactly one place, in Rust,
  /// and this arithmetic never needs to know it.
  @visibleForTesting
  static String formatLede(int startTime, int atMs) {
    final now = DateTime.fromMillisecondsSinceEpoch(atMs);
    final delta = startTime - (now.hour * 60 + now.minute);
    if (delta >= 2) return 'in $delta minutes';
    if (delta == 1) return 'in a minute';
    return 'now';
  }

  /// How long the card stays before letting itself out.
  ///
  /// This is the whole job importance has now. A time is still the only thing
  /// that decides WHETHER Slate speaks — `!` and `!!` decide how patient the
  /// card is once it has. It is Apple's own split: a banner shows itself out,
  /// an alert waits to be seen. Crucially it WAITS — it never repeats, never
  /// rings twice and never counts, so the compass holds.
  static int lifeMsFor(int priority) {
    switch (priority) {
      case 2:
        return 0; // `!!` — stays until it is dealt with
      case 1:
        return 14000;
      default:
        return 7000;
    }
  }

  /// A stack takes the patience of its most insistent row: one `!!` in the pile
  /// and nothing leaves on its own.
  ///
  /// Time also grows with how much there is to read. Three merged rows on a
  /// flat seven seconds means the card shuts in the middle of the second one —
  /// roughly 2.5 s per extra row covers scanning it at normal reading speed.
  @visibleForTesting
  static int lifeMsForBatch(List<ReminderCard> cards) {
    var life = 7000;
    for (final c in cards) {
      final l = lifeMsFor(c.priority);
      if (l == 0) return 0;
      if (l > life) life = l;
    }
    if (cards.length > 1) life += (cards.length - 1) * 2500;
    return life;
  }

  /// Minutes since midnight → "18:00". 24-hour, zero-padded, matching how the
  /// day view already writes time.
  @visibleForTesting
  static String formatTime(int minutes) {
    if (minutes < 0) return '';
    final h = (minutes ~/ 60).clamp(0, 23);
    final m = (minutes % 60).clamp(0, 59);
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// One pass of the policy, with no timer behind it — tests drive the clock
  /// themselves rather than waiting on real seconds.
  @visibleForTesting
  Future<void> pump() => _speakIfDue();
}
