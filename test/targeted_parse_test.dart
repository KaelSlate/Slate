import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/engine/slate_core_bridge.dart';

/// Bridge-level proof (real DLL) that `parseInput(targeted: true)` routes to
/// `ffi_parse_input_targeted`: a typed calendar date is KEPT as title text (the
/// pinned day wins, zero lost input), while time/tags/priority still parse.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final core = SlateCore();

  test('FFI is connected (targeted symbol resolved)', () {
    expect(core.isFFIConnected, true);
  });

  test('normal parse strips the date; targeted keeps it as text', () {
    final normal = core.parseInput('call mom 14 июля');
    expect(normal.dateKind, 3); // explicit date extracted
    expect(normal.cleanTitle, 'call mom');

    final targeted = core.parseInput('call mom 14 июля', targeted: true);
    expect(targeted.dateKind, 0); // no date token — the pinned day wins
    expect(targeted.cleanTitle, 'call mom 14 июля'); // nothing lost
  });

  test('targeted parse still schedules a typed time within the day', () {
    final targeted = core.parseInput('gym 14:00', targeted: true);
    expect(targeted.dateKind, 0);
    expect(targeted.startTime, 14 * 60);
    expect(targeted.cleanTitle, 'gym');
  });

  test('targeted parse still extracts tags and priority', () {
    final targeted = core.parseInput('отчёт 15.07 !! #работа', targeted: true);
    expect(targeted.dateKind, 0);
    expect(targeted.priority, 2);
    expect(targeted.tags, ['работа']);
    expect(targeted.cleanTitle, 'отчёт 15.07'); // date words remain
  });
}
