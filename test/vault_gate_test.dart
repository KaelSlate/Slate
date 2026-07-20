import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/state/task_state.dart';
import 'package:slate/ui/overlays/vault_gate.dart';

/// The honest face of a vault that didn't open. Replaces the old silent
/// "Sample task 1..5" fallback that masqueraded as data loss.
void main() {
  Widget host(EngineFailure failure,
          {VoidCallback? onRetry, VoidCallback? onStartFresh}) =>
      MaterialApp(
        home: Scaffold(
          body: VaultGate(
            failure: failure,
            onRetry: onRetry ?? () {},
            onStartFresh: onStartFresh ?? () {},
          ),
        ),
      );

  testWidgets('key failure names the real cause and shows the file path',
      (tester) async {
    await tester.pumpWidget(host(
        const EngineFailure(EngineFailKind.key, 'C:\\x\\tasks.db')));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.textContaining("can't open your tasks"), findsOneWidget);
    expect(find.textContaining('key'), findsWidgets);
    expect(find.textContaining('tasks.db'), findsOneWidget);
    // The reassurance line — first impressions die of fear, not of errors.
    expect(find.textContaining('untouched'), findsOneWidget);
  });

  testWidgets('Try again fires immediately', (tester) async {
    var retried = 0;
    await tester.pumpWidget(host(
        const EngineFailure(EngineFailKind.io, 'C:\\x\\tasks.db'),
        onRetry: () => retried++));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.text('Try again'));
    expect(retried, 1);
  });

  testWidgets('Start fresh arms first, fires on the second tap',
      (tester) async {
    var fresh = 0;
    await tester.pumpWidget(host(
        const EngineFailure(EngineFailKind.other, 'C:\\x\\tasks.db'),
        onStartFresh: () => fresh++));
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.textContaining('Start fresh'));
    await tester.pump();
    expect(fresh, 0, reason: 'one tap only arms the action');
    expect(find.textContaining('sure'), findsOneWidget);

    await tester.tap(find.textContaining('sure'));
    expect(fresh, 1);
  });
}
