import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What actually reaches the mixer. Tests substitute a recorder for this so the
/// trigger rule can be asserted without an audio device.
typedef SfxSink = void Function({required String id, required double gain});

/// Slate's two sounds: a task struck through, and a task asking for you.
///
/// Fire-and-forget — no await ever sits between the tick and the frame it
/// causes; the native side replies to `play` immediately
/// (windows/runner/sfx_player.cpp) precisely so that stays true.
///
/// Both play from the MAIN isolate. The reminder window has its own engine but
/// no sfx channel: one mixer, one caller, no chance of two device sessions
/// fighting over the same moment.
class Sfx {
  Sfx._();

  static const _channel = MethodChannel('slate/sfx');

  /// The id the runner registers this clip under (notification.wav).
  static const _done = 'done';

  /// The reminder chime (reminder.wav).
  static const _due = 'due';

  /// Above [_doneGain] deliberately. Finishing something is a reward the person
  /// caused; a reminder has to reach someone who is looking elsewhere, and
  /// Apple's own guidance puts notification sounds above UI feedback. Still
  /// well under unity — this is a status tone, not an alarm.
  ///
  /// 0.60, not the 0.52 that served while `due` was borrowing the done clip.
  /// reminder.wav is normalised to −6 dBFS peak but sounds for only 124 ms
  /// against the done clip's 262 ms, and the ear integrates loudness over
  /// ~150–200 ms — at equal RMS the shorter clip is heard quieter. This lands
  /// it at −10.4 dBFS peak: the same presence as the old fallback, ~1.7 dB
  /// less energy behind it.
  static const _dueGain = 0.60;

  /// Chosen against the clip's measured level (RMS −17 dBFS, peak −5 dBFS),
  /// which is dense for its length — at unity it would sit louder than
  /// anything else on the desktop. This lands it around −25 dBFS: present
  /// enough to feel like a reward, quiet enough to tick a dozen tasks in a row.
  static const _doneGain = 0.385;

  /// The shortest gap allowed between two chimes. Not a user-facing rate
  /// limit — ticking two tasks half a second apart still rings twice. This
  /// only stops a double-fire (a handler running twice) from flamming.
  static const _floorMs = 40;

  /// Swapped in tests. Production ships straight down the method channel.
  @visibleForTesting
  static SfxSink sink = _channelSink;

  /// Swapped in tests to drive the rate floor deterministically.
  @visibleForTesting
  static int Function() clockMs = () => DateTime.now().millisecondsSinceEpoch;

  static int? _lastFiredMs;

  static void _channelSink({required String id, required double gain}) {
    // .ignore() is load-bearing, not tidiness. Fire-and-forget must not leave
    // a rejectable future behind: where the channel is absent — `flutter test`,
    // or any future host that doesn't register it — invokeMethod completes
    // with MissingPluginException, which would surface as an unhandled async
    // error in the zone long after the tick that caused it, and land in the
    // crash log. A sound that cannot play is not an error worth reporting.
    _channel.invokeMethod<void>('play', <String, dynamic>{
      'id': id,
      'gain': gain,
      // The reminder clip exists to accompany a card and nothing else, so it
      // waits for that card to be on screen instead of playing the moment the
      // show is accepted. Measured, it used to lead its own picture by about
      // 110 ms, which is long enough to be heard as two separate events rather
      // than one arrival. The runner holds it and fires it on the uncloak —
      // see SfxPlayer::ArmDeferred.
      //
      // `taskDone` is not deferred: nothing is being revealed, the sound IS
      // the feedback, and it must land on the click.
      'onReveal': id == _due,
    }).ignore();
  }

  /// Opens the audio device. Non-fatal: a machine with no usable output just
  /// stays quiet, it never stops the app from starting.
  static Future<void> init() async {
    try {
      await _channel.invokeMethod<bool>('init');
    } catch (_) {/* no device / older Windows — run silent */}
  }

  /// A task was struck through.
  ///
  /// Completion only, and never on undo — both conditions live at the single
  /// call site in TaskState.toggleTask, which is the one funnel every checkbox
  /// in the app goes through. Un-ticking is not an achievement, and an undo is
  /// the user taking the moment back.
  static void taskDone() {
    final now = clockMs();
    final last = _lastFiredMs;
    if (last != null && now - last < _floorMs) return;
    _lastFiredMs = now;
    sink(id: _done, gain: _doneGain);
  }

  /// A card came up asking for someone's attention.
  ///
  /// Rings once per EVENT, not per row: a card that grows a second line while
  /// it is still on screen must not chime again. That rule lives in
  /// ReminderScheduler, which is the only caller.
  static void reminderDue({int priority = 0}) {
    final now = clockMs();
    final last = _lastFiredMs;
    if (last != null && now - last < _floorMs) return;
    _lastFiredMs = now;
    // A step per level, not a different sound: same voice, more presence. `!!`
    // still lands under unity — insistent, never an alarm.
    final gain = switch (priority) {
      2 => _dueGain * 1.32,
      1 => _dueGain * 1.15,
      _ => _dueGain,
    };
    sink(id: _due, gain: gain.clamp(0.0, 1.0));
  }

  @visibleForTesting
  static void resetForTest() => _lastFiredMs = null;
}
