import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/sfx/sfx.dart';

/// When each of Slate's two sounds fires, and how loud — asserted with no audio
/// device in sight. The mixer itself is C++ and is judged by ear; what is
/// testable (and what actually broke while wiring this up) is the decision
/// layer: the direction gate on completion, the undo gate, and the startup
/// latch that keeps the shader-warmup pass silent.
void main() {
  late List<Map<String, Object>> played;
  late int now;

  setUp(() {
    played = [];
    now = 100000;
    Sfx.armed = true;
    Sfx.clockMs = () => now;
    Sfx.sink = ({
      required String id,
      required double gain,
      required int trimMs,
      required int fadeMs,
    }) =>
        played.add({
          'id': id,
          'gain': gain,
          'trimMs': trimMs,
          'fadeMs': fadeMs,
        });
    Sfx.resetForTest();
  });

  tearDown(() {
    Sfx.armed = false;
    Sfx.clockMs = () => DateTime.now().millisecondsSinceEpoch;
  });

  group('the sound set', () {
    test('is exactly two: the pill and completion', () {
      expect(SfxId.values.map((e) => e.wire).toSet(), {'done', 'pill'});
    });
  });

  group('startup latch', () {
    test('nothing sounds before the warmup pass arms it', () {
      // WarmupStage mounts a pill, a week view and a month view under an
      // opaque veil purely to compile shaders. Those are real widget
      // lifecycles, so without this latch the app would announce itself with
      // an entrance sound nobody triggered.
      Sfx.armed = false;
      Sfx.pillAppear();
      Sfx.taskDone();
      expect(played, isEmpty);

      Sfx.armed = true;
      Sfx.pillAppear();
      expect(played.single['id'], 'pill');
    });
  });

  group('completion chime', () {
    test('fires on done', () {
      Sfx.taskDone();
      expect(played.single['id'], 'done');
      // A finished sound: played whole, nothing trimmed.
      expect(played.single['trimMs'], 0);
      expect(played.single['fadeMs'], 0);
    });

    test('the undo path stays silent', () {
      // undoLast re-toggles through the same funnel a real completion uses;
      // re-playing the chime there would celebrate taking a thing back.
      Sfx.suppressed = true;
      Sfx.taskDone();
      expect(played, isEmpty);
    });
  });

  group('pill rise', () {
    test('carries the trim and fade the mixer needs', () {
      Sfx.pillAppear();
      expect(played.single['id'], 'pill');
      // progress_loop.wav is a 1.5 s LOOP. Only its head is ever played, cut
      // to the pill spring's own settling time (~227 ms) and faded out, so the
      // sound lasts exactly as long as the movement it describes.
      expect(played.single['trimMs'], 250);
      expect(played.single['fadeMs'], 180);
    });
  });

  group('the mix', () {
    test('completion sits above the pill', () {
      // The pill appears many times a day and announces; completion is the
      // rarer payoff. Both stay well under full scale so an overlap of the two
      // cannot clip the mastering voice.
      Sfx.taskDone();
      now += 100;
      Sfx.pillAppear();
      final done = played[0]['gain']! as double;
      final pill = played[1]['gain']! as double;
      expect(done, greaterThan(pill));
      expect(done, lessThan(0.5));
      expect(pill, greaterThan(0.0));
    });

    test('a double-fire of the same event flams only once', () {
      Sfx.taskDone();
      Sfx.taskDone(); // same millisecond — e.g. a handler running twice
      expect(played, hasLength(1));
    });

    test('the floor does not swallow two deliberate ticks', () {
      Sfx.taskDone();
      now += 400; // two tasks ticked in quick succession by hand
      Sfx.taskDone();
      expect(played, hasLength(2));
    });

    test('the two sounds do not gate each other', () {
      Sfx.taskDone();
      Sfx.pillAppear(); // same millisecond, different channel
      expect(played.map((p) => p['id']), ['done', 'pill']);
    });
  });
}
