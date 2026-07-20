import 'package:flutter_test/flutter_test.dart';

import 'package:slate/ui/widgets/smart_day_input.dart';

/// The placeholder is the syntax teacher: each reveal of an empty pill shows
/// one real capture the parser fully understands. No tour, no tooltip.
void main() {
  test('first contact stays calm, later reveals teach and wrap around', () {
    expect(captureHintFor(0), 'Type a task…');
    // Every teaching hint carries at least one parseable token.
    final seen = <String>{};
    for (var i = 1; i <= captureHints.length; i++) {
      final h = captureHintFor(i);
      expect(h, isNot('Type a task…'));
      seen.add(h);
    }
    expect(seen.length, captureHints.length - 1,
        reason: 'all teaching hints get their turn before any repeats');
    expect(captureHintFor(captureHints.length), captureHintFor(1),
        reason: 'rotation wraps around the teaching set, never back to calm');
  });

  test('reveal counter on the notifier drives the rotation', () {
    final n = SmartInputNotifier();
    expect(n.reveals, 0);
    n.clear();
    n.clear();
    expect(n.reveals, 2);
    n.dispose();
  });
}
