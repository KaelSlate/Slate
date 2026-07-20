import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/quick_capture_controller.dart';
import 'package:slate/core/engine/spatial_zoom_engine.dart';
import 'package:slate/core/state/first_run.dart';
import 'package:slate/ui/overlays/welcome_overlay.dart';

/// Welcome overlay: greeting with the REAL hotkey chord, confirm moment on
/// the first capture, Esc dismiss. No prefs / no engine — pure UI contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FirstRunController.instance.firstLanding.value = null;
    StaircaseState.isWelcoming = false;
  });

  Widget host({required VoidCallback onGone}) => MaterialApp(
        home: Scaffold(body: WelcomeOverlay(onGone: onGone)),
      );

  testWidgets('greeting shows the registered chord, not a hardcoded one',
      (tester) async {
    QuickCaptureController.instance.hotkeyLabel = 'Ctrl+Alt+Space';
    addTearDown(
        () => QuickCaptureController.instance.hotkeyLabel = 'Alt+Space');

    await tester.pumpWidget(host(onGone: () {}));
    await tester.pump(const Duration(milliseconds: 2500)); // entrance settles

    expect(StaircaseState.isWelcoming, isTrue);
    expect(find.text('Welcome to Slate.'), findsOneWidget);
    for (final cap in ['Ctrl', 'Alt', 'Space']) {
      expect(find.text(cap), findsOneWidget, reason: 'keycap $cap');
    }
    expect(find.textContaining('anywhere, anytime'), findsOneWidget);

    await tester.pumpWidget(const SizedBox()); // dispose cleanly
  });

  testWidgets('all chords taken → teaches C instead of a dead hotkey',
      (tester) async {
    QuickCaptureController.instance.hotkeyActive = false;
    addTearDown(() => QuickCaptureController.instance.hotkeyActive = true);

    await tester.pumpWidget(host(onGone: () {}));
    await tester.pump(const Duration(milliseconds: 2500));

    expect(find.textContaining('held by another app'), findsOneWidget);
    expect(find.text('C'), findsOneWidget, reason: 'the working key, as a cap');
    expect(find.textContaining('anywhere, anytime'), findsNothing);
    expect(find.textContaining('capture works all the same'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('first capture flips to the confirm moment, then auto-dissolves',
      (tester) async {
    var gone = false;
    await tester.pumpWidget(host(onGone: () => gone = true));
    await tester.pump(const Duration(milliseconds: 300));

    FirstRunController.instance.firstLanding.value = 'Today 14:00';
    await tester.pump(); // rebuild starts the switcher transition
    await tester.pump(const Duration(milliseconds: 400)); // crossfade runs out
    await tester.pump(const Duration(milliseconds: 50)); // outgoing unmounts

    expect(find.text('There — tucked into Today 14:00.'), findsOneWidget);
    expect(find.text('Welcome to Slate.'), findsNothing);

    await tester.pump(const Duration(milliseconds: 3100)); // auto-dismiss timer
    await tester.pump(); // exit ticker arms (first tick = t0)
    await tester.pump(const Duration(milliseconds: 500)); // 450ms exit
    await tester.pump(const Duration(milliseconds: 50)); // completion frame
    expect(gone, isTrue);
    expect(StaircaseState.isWelcoming, isFalse);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Esc hides it for the session without completing the arc',
      (tester) async {
    var gone = false;
    await tester.pumpWidget(host(onGone: () => gone = true));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(); // exit ticker arms (first tick = t0)
    await tester.pump(const Duration(milliseconds: 500)); // 450ms exit
    await tester.pump(const Duration(milliseconds: 50)); // completion frame
    expect(gone, isTrue);
    expect(StaircaseState.isWelcoming, isFalse);
    expect(FirstRunController.instance.firstLanding.value, isNull,
        reason: 'Esc must not count as a capture');

    await tester.pumpWidget(const SizedBox());
    // Flush the graphite stroke's 1s draw-on delay timer (mounted-guarded).
    await tester.pump(const Duration(milliseconds: 1100));
  });
}
