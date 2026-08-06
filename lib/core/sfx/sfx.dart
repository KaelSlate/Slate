import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What actually reaches the mixer. Tests substitute a recorder for this so the
/// trigger rule can be asserted without an audio device.
typedef SfxSink = void Function({required String id, required double gain});

/// Slate's one sound: a task struck through.
///
/// Nothing else in the app makes noise. Fire-and-forget — no await ever sits
/// between the tick and the frame it causes; the native side replies to `play`
/// immediately (windows/runner/sfx_player.cpp) precisely so that stays true.
class Sfx {
  Sfx._();

  static const _channel = MethodChannel('slate/sfx');

  /// The id the runner registers this clip under (notification.wav).
  static const _done = 'done';

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

  @visibleForTesting
  static void resetForTest() => _lastFiredMs = null;
}
