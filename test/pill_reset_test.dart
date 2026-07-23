import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/slate_core_bridge.dart';
import 'package:slate/ui/widgets/smart_day_input.dart';

/// A summon must hand the user an EMPTY pill.
///
/// `SmartInputNotifier.clear()` means "reset for a fresh capture" — the pill
/// calls it on every reveal. It used to reset only the parse result, so text
/// that was typed and never submitted survived a dismiss and came back on the
/// next summon, sitting on top of the teaching placeholder.
void main() {
  Future<void> pumpPill(
    WidgetTester tester,
    SmartInputNotifier notifier,
    FocusNode focus,
  ) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SmartDayInputWidget(
          core: SlateCore(),
          focusNode: focus,
          notifier: notifier,
          floating: true,
          onSubmit: (_, _) {},
          onDismiss: () {},
        ),
      ),
    ));
    // The field re-asserts focus 60 ms after mount (a Windows IME quirk); let
    // that timer expire or the test ends with it pending.
    await tester.pump(const Duration(milliseconds: 120));
  }

  testWidgets('a fresh reveal empties the field', (tester) async {
    final notifier = SmartInputNotifier();
    final focus = FocusNode();
    await pumpPill(tester, notifier, focus);

    await tester.enterText(find.byType(TextField), 'call mom tomorrow 15:00');
    await tester.pump();
    expect(find.text('call mom tomorrow 15:00'), findsOneWidget);

    // The pill was dismissed and summoned again.
    notifier.clear();
    await tester.pump();

    expect(find.text('call mom tomorrow 15:00'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);

    focus.dispose();
    notifier.dispose();
  });

  testWidgets('a parse-result update leaves typed text alone', (tester) async {
    final notifier = SmartInputNotifier();
    final focus = FocusNode();
    await pumpPill(tester, notifier, focus);

    await tester.enterText(find.byType(TextField), 'gym at 6pm');
    await tester.pump();

    // Only reveals must wipe the field; ordinary updates must not.
    notifier.update(const ParseResult(cleanTitle: 'gym'));
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'gym at 6pm');

    focus.dispose();
    notifier.dispose();
  });
}
