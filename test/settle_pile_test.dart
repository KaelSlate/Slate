import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:slate/core/engine/slate_core_bridge.dart';
import 'package:slate/core/interaction/drag_session.dart';
import 'package:slate/ui/widgets/drag_source.dart';

/// Where a dropped card flies when it has no row of its own.
///
/// A task that sorts below a cell's «+N more» cap produces no card, so the
/// pixel-perfect refine finds nothing and the flight used to run to a guessed
/// row, freeze there and vanish — an animation to a place the card is not.
/// It now dissolves INTO the pile, which is where the task actually went.

const Rect pileRect = Rect.fromLTWH(300, 400, 90, 12);
const Rect estimate = Rect.fromLTWH(300, 200, 90, 24);
final DateTime theDay = DateTime(2026, 11, 3);

RustTask task(String id) => RustTask(
      id: id,
      title: id,
      isCompleted: false,
      createdAt: theDay.millisecondsSinceEpoch,
      priority: 0,
      tags: const [],
    );

DragPayload payload(RustTask t) => DragPayload(
      task: t,
      kind: DragSourceKind.dayCellCard,
      sourceGlobalRect: const Rect.fromLTWH(0, 0, 100, 30),
      grabOffset: Offset.zero,
      sourceDay: theDay,
    );

/// A cell-like zone that always accepts and reports the pile as its fallback.
class _Zone extends DropZone {
  @override
  String get id => 'test-cell';

  @override
  Rect? globalRect() => const Rect.fromLTWH(0, 0, 800, 600);

  @override
  DropHover? hoverAt(Offset p, DragPayload payload) =>
      DropHover(zoneId: id, targetDay: theDay, cellMode: 'whole');

  @override
  DropResult? onDrop(Offset p, DragPayload payload) => DropResult(
        settleGlobalRect: estimate,
        settleFallbackId: DragCardRegistry.pileId(theDay),
      );
}

/// Renders the «+N more» pile at [pileRect], plus optionally a real card for
/// [withCardId] — so we can flip between "the card exists" and "it doesn't".
Widget harness({String? withCardId}) => MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Positioned.fromRect(
              rect: pileRect,
              child: SettleAnchor(
                id: DragCardRegistry.pileId(theDay),
                child: const SizedBox.expand(),
              ),
            ),
            if (withCardId != null)
              Positioned.fromRect(
                rect: const Rect.fromLTWH(500, 100, 90, 24),
                child: DragSource(
                  task: task(withCardId),
                  kind: DragSourceKind.dayCellCard,
                  child: const SizedBox.expand(),
                ),
              ),
          ],
        ),
      ),
    );

void main() {
  late _Zone zone;

  setUp(() {
    zone = _Zone();
    DragSession.instance.registry.register(zone);
  });

  tearDown(() {
    DragSession.instance.registry.unregister(zone);
    DragSession.instance.debugReset();
  });

  testWidgets('no row for it → the flight lands on the «+N more» pile',
      (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();

    final t = task('hidden-one');
    DragSession.instance.begin(payload(t), const Offset(10, 10));
    DragSession.instance.update(const Offset(400, 300));
    await tester.pump();
    DragSession.instance.drop();
    await tester.pump(); // the post-frame refine runs here

    expect(DragSession.instance.settleTarget, pileRect,
        reason: 'it dissolves into the pile it actually joined');
    expect(DragSession.instance.settleTarget, isNot(estimate),
        reason: 'never the guessed row — that is the freeze-and-vanish bug');
  });

  testWidgets('a card that IS on screen still wins — pile is only the fallback',
      (tester) async {
    await tester.pumpWidget(harness(withCardId: 'visible-one'));
    await tester.pump();

    final t = task('visible-one');
    DragSession.instance.begin(payload(t), const Offset(10, 10));
    DragSession.instance.update(const Offset(400, 300));
    await tester.pump();
    DragSession.instance.drop();
    await tester.pump();

    expect(DragSession.instance.settleTarget,
        const Rect.fromLTWH(500, 100, 90, 24),
        reason: 'pixel-perfect landing on the real card is still preferred');
  });

  testWidgets('an empty pile publishes nothing — the estimate stands',
      (tester) async {
    // hiddenCount == 0 collapses the label to zero size. Landing on a
    // zero-height rect would be a different lie.
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SettleAnchor(
          id: DragCardRegistry.pileId(theDay),
          child: const SizedBox.shrink(),
        ),
      ),
    ));
    await tester.pump();

    expect(DragCardRegistry.rectFor(DragCardRegistry.pileId(theDay)), isNull);

    final t = task('no-pile');
    DragSession.instance.begin(payload(t), const Offset(10, 10));
    DragSession.instance.update(const Offset(400, 300));
    await tester.pump();
    DragSession.instance.drop();
    await tester.pump();

    expect(DragSession.instance.settleTarget, estimate);
  });
}
