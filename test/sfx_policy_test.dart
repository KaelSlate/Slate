import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/sfx/sfx.dart';

/// Slate's one sound, asserted with no audio device in sight. The mixer is C++
/// and is judged by ear; what is testable is the rule around it.
void main() {
  late List<Map<String, Object>> played;
  late int now;

  setUp(() {
    played = [];
    now = 100000;
    Sfx.clockMs = () => now;
    Sfx.sink = ({required String id, required double gain}) =>
        played.add({'id': id, 'gain': gain});
    Sfx.resetForTest();
  });

  tearDown(() {
    Sfx.clockMs = () => DateTime.now().millisecondsSinceEpoch;
  });

  test('a completed task rings', () {
    Sfx.taskDone();
    expect(played.single['id'], 'done');
  });

  test('the level stays well under full scale', () {
    // notification.wav is dense for its length (RMS -17 dBFS at a -5 dBFS
    // peak); at unity it would sit louder than anything else on the desktop.
    Sfx.taskDone();
    final gain = played.single['gain']! as double;
    expect(gain, greaterThan(0.0));
    expect(gain, lessThan(0.5));
  });

  test('a double-fire flams only once', () {
    Sfx.taskDone();
    Sfx.taskDone(); // same millisecond — e.g. a handler running twice
    expect(played, hasLength(1));
  });

  test('two tasks ticked in a row both ring', () {
    // The floor exists to swallow a repeated handler, NOT to rate-limit a
    // person working through a list.
    Sfx.taskDone();
    now += 400;
    Sfx.taskDone();
    expect(played, hasLength(2));
  });
}
