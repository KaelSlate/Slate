import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The two sounds Slate makes. Wire ids MUST match the RCDATA clips registered
/// in windows/runner/sfx_player.cpp (`LoadClipFromResource`).
enum SfxId {
  /// notification.wav — a task struck through.
  done('done'),

  /// progress_loop.wav (head only) — the capture pill arriving.
  pill('pill');

  const SfxId(this.wire);
  final String wire;
}

/// What actually reaches the mixer. Tests substitute a recorder for this so the
/// trigger policy can be asserted without an audio device.
typedef SfxSink = void Function({
  required String id,
  required double gain,
  required int trimMs,
  required int fadeMs,
});

/// The app's voice.
///
/// Two events, no settings, no tuning file: the mix below was chosen once and
/// is compiled in. Everything is fire-and-forget — no await ever sits between
/// a user action and the frame that action causes, and the native side replies
/// to `play` immediately (sfx_player.cpp) precisely so that stays true.
class Sfx {
  Sfx._();

  static const _channel = MethodChannel('slate/sfx');

  // ── The mix ──────────────────────────────────────────────────────────────
  // Master leaves headroom: the two can overlap (tick a task, then summon the
  // pill) and a mastering voice at full scale would clip.
  static const _master = 0.70;

  /// Completion is the payoff moment and the rarer of the two, so it sits
  /// slightly above the pill. Effective level 0.385.
  static const _doneGain = 0.55;

  /// The pill appears many times a day; it announces rather than rewards, so
  /// it stays under the chime. Effective level 0.315.
  static const _pillGain = 0.45;

  /// How much of progress_loop.wav's head to play — DERIVED, not taste.
  ///
  /// The pill rides one spring (mass 1.0, stiffness 420, damping ratio 0.86 —
  /// pill_window.dart and AppTheme.glassSpringAppear*). Its settling time is
  ///
  ///     w = sqrt(420) = 20.5 rad/s     t = 4 / (0.86 * 20.5) ~= 227 ms
  ///
  /// so the entrance is visually over at ~230 ms. 250 ms covers the movement
  /// and stops just past it: the sound lasts exactly as long as the thing it
  /// describes. The file itself is a 1.5 s LOOP — played whole it would leave
  /// a hum sitting under a pill that finished arriving a second earlier.
  static const _pillTrimMs = 250;

  /// Raised-cosine fade at the end of that head. Long relative to the clip on
  /// purpose: this is a sustained tone, and a sustained tone that stops
  /// abruptly reads as a click rather than as an ending.
  static const _pillFadeMs = 180;

  /// The shortest gap allowed between two of the SAME sound. Neither event is
  /// triggered at anything like keyboard rate, so this exists only to stop a
  /// double-fire (a handler running twice) from flamming. Well below the
  /// fastest a person can tick two tasks.
  static const _floorMs = 40;

  /// Swapped in tests. Production ships straight down the method channel.
  @visibleForTesting
  static SfxSink sink = _channelSink;

  /// Swapped in tests to drive the rate floor deterministically.
  @visibleForTesting
  static int Function() clockMs =
      () => DateTime.now().millisecondsSinceEpoch;

  static final Map<SfxId, int> _lastFiredMs = {};

  /// Undo re-toggles tasks through the same funnel a real completion uses.
  /// Re-playing the chime there would celebrate taking a thing back.
  static bool suppressed = false;

  /// Startup is silent until the warmup pass is over.
  ///
  /// WarmupStage mounts a full pill, a week view and a month view under an
  /// opaque veil purely so Skia compiles their shaders (warmup_layer.dart).
  /// Those are real widget lifecycles, so without this gate the app would
  /// announce itself with an entrance sound nobody triggered. Set from
  /// PulseLayer when the warmup finishes — a single latch is safer here than
  /// teaching each call site about the veil, because the next surface added to
  /// the warmup stage would otherwise reintroduce the bug silently.
  static bool armed = false;

  static void _channelSink({
    required String id,
    required double gain,
    required int trimMs,
    required int fadeMs,
  }) {
    _channel.invokeMethod<void>('play', <String, dynamic>{
      'id': id,
      'gain': gain,
      'trimMs': trimMs,
      'fadeMs': fadeMs,
    });
  }

  /// Opens the audio device. Non-fatal: a machine with no usable output just
  /// stays quiet, it never stops the app from starting.
  static Future<void> init() async {
    try {
      await _channel.invokeMethod<bool>('init');
    } catch (_) {/* no device / older Windows — run silent */}
  }

  static void _emit(SfxId id, double gain, {int trimMs = 0, int fadeMs = 0}) {
    if (!armed || suppressed) return;

    final now = clockMs();
    final last = _lastFiredMs[id];
    if (last != null && now - last < _floorMs) return;
    _lastFiredMs[id] = now;

    sink(
      id: id.wire,
      gain: (_master * gain).clamp(0.0, 1.0),
      trimMs: trimMs,
      fadeMs: fadeMs,
    );
  }

  /// A task was struck through. Completion only — see TaskState.toggleTask.
  static void taskDone() => _emit(SfxId.done, _doneGain);

  /// The capture pill is arriving (global, day, or overview — all three are
  /// the same SmartDayInputWidget).
  static void pillAppear() => _emit(
        SfxId.pill,
        _pillGain,
        trimMs: _pillTrimMs,
        fadeMs: _pillFadeMs,
      );

  @visibleForTesting
  static void resetForTest() {
    _lastFiredMs.clear();
    suppressed = false;
  }
}
