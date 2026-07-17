import 'package:flutter/foundation.dart';

import 'local_prefs.dart';

/// Every mechanic worth teaching, and the ONE line that teaches it.
///
/// Two kinds, and the split is what keeps this from being a tour:
///
///   INVITE      — pulled. For a mechanic with no visible affordance at all.
///                 The whisper evaluates these from the current context, so an
///                 invite only exists while its moment does. Only two qualify:
///                 everything else in Slate can be reached with a visible
///                 click, and inviting someone to do what they can already see
///                 is noise.
///   ACCELERATOR — pushed. You just did the thing with the mouse; here is the
///                 key, once. Self-limiting by construction: it can only ever
///                 appear immediately after the action it names. This is the
///                 menu-shortcut pattern — the shortcut is written next to the
///                 thing you just clicked, and you learn it by doing.
///
/// The point of the whole system: **a good hint is one most users never see.**
/// Click a day before the zoom invite surfaces and it retires silently, for
/// good. Nothing is ever taught twice, and nothing is ever taught at once.
enum LessonKind { invite, accelerator }

class Lesson {
  final String id;
  final LessonKind kind;
  final String text;
  const Lesson(this.id, this.kind, this.text);
}

/// House voice: thing — em-dash — lowercase outcome. Matches the lines the app
/// already speaks ('Shift+Enter — keep going', 'date stays here').
class Lessons {
  // The signature spatial gesture, and the one thing no one discovers on their
  // own: a day cell has no pointer cursor (manifest law — no I-beam outside a
  // text field), so nothing hints it is even zoomable. One quiet line teaches
  // the whole move, both directions, and retires the instant the wheel is used.
  static const zoom = Lesson('zoom', LessonKind.invite,
      'Ctrl + scroll a day — zoom in, and back out.');
  static const drag = Lesson(
      'drag', LessonKind.invite, 'Tasks move — drag one to any day.');

  static const backKey =
      Lesson('backKey', LessonKind.accelerator, 'Esc — back out.');
  static const captureKey = Lesson('captureKey', LessonKind.accelerator,
      "C — adds to the day you're in.");
  static const inboxKey =
      Lesson('inboxKey', LessonKind.accelerator, 'I — opens the inbox.');
  static const viewKey = Lesson(
      'viewKey', LessonKind.accelerator, 'V — flips week and month.');

  // Shift+Enter is NOT here on purpose: it belongs to the pill window, which is
  // its own Flutter engine with no prefs and no DB. It teaches itself, session-
  // scoped — see pill_window.dart. Reaching across that boundary is exactly the
  // bug this replaces: the old whisper read a first-run flag that only exists in
  // the main isolate, so it was always false and never once appeared.

  static const all = [zoom, drag, backKey, captureKey, inboxKey, viewKey];
}

/// The teaching ladder. One slot, at most one line on screen, ever.
///
/// Replaces the old single `hintsActive` bool, which gated EVERY hint on the
/// first capture: catch one thought into the inbox and — in the same instant,
/// forever — the app stopped teaching zoom, drag and Shift+Enter. Each lesson
/// now retires on its OWN mastery. (The grey first-run ghost silhouettes it also
/// drove are gone too — the real demo seed teaches the anatomy by being real.)
class LessonState extends ChangeNotifier {
  LessonState._();
  static final LessonState instance = LessonState._();

  /// How many sessions an invite may go unheeded before it gives up.
  static const _maxSightings = 3;

  /// The accelerator currently holding the slot, if any. Invites are pulled by
  /// the whisper itself, so they never live here.
  Lesson? _pushed;
  Lesson? get pushed => _pushed;

  final Set<String> _learned = {};
  Map<String, int> _seen = {};

  /// Invites offered this session — counted once each, not once per rebuild.
  final Set<String> _countedThisSession = {};

  void syncFromPrefs() {
    try {
      _learned
        ..clear()
        ..addAll(LocalPrefs.instance.lessons);
      _seen = Map<String, int>.from(LocalPrefs.instance.lessonSeen);
    } catch (_) {/* prefs not loaded (tests) — in-memory defaults hold */}
  }

  bool isLearned(String id) => _learned.contains(id);

  /// Retire a lesson for good. Called from the action itself, so performing a
  /// mechanic is what teaches it — whether or not the hint was ever shown.
  void learn(String id) {
    if (!_learned.add(id)) return;
    if (_pushed?.id == id) _pushed = null;
    _persist();
    notifyListeners();
  }

  /// An accelerator asks for the slot: the user just did this with the mouse.
  void offer(Lesson lesson) {
    assert(lesson.kind == LessonKind.accelerator,
        'invites are pulled by the whisper, never pushed');
    if (isLearned(lesson.id) || _pushed?.id == lesson.id) return;
    _pushed = lesson;
    notifyListeners();
  }

  /// The accelerator's moment has passed (it auto-clears after a few seconds).
  /// NOT learned — it was shown, not performed; it may earn its slot again.
  void clearPushed(Lesson lesson) {
    if (_pushed?.id != lesson.id) return;
    _pushed = null;
    notifyListeners();
  }

  /// Whether an invite may still be offered: unlearned, and inside its
  /// sightings budget. Pure — safe to call from build.
  bool inviteAvailable(Lesson lesson) =>
      !isLearned(lesson.id) &&
      (_seen[lesson.id] ?? 0) < _maxSightings;

  /// Count one sighting. Called when an invite actually REACHED the screen, not
  /// when it was merely considered — so the budget measures what the user saw.
  void noteInviteShown(Lesson lesson) {
    if (!_countedThisSession.add(lesson.id)) return;
    _seen = {..._seen, lesson.id: (_seen[lesson.id] ?? 0) + 1};
    _persist();
  }

  void _persist() {
    try {
      LocalPrefs.instance
        ..lessons = _learned.toList()
        ..lessonSeen = _seen;
    } catch (_) {/* prefs not loaded (tests) — the in-memory set still holds */}
  }

  /// Pretend the app was restarted: the sightings budget counts SESSIONS, so a
  /// test that needs to spend it has to cross that boundary honestly.
  @visibleForTesting
  void debugNewSession() => _countedThisSession.clear();

  @visibleForTesting
  void debugReset() {
    _learned.clear();
    _seen = {};
    _countedThisSession.clear();
    _pushed = null;
    notifyListeners();
  }
}
