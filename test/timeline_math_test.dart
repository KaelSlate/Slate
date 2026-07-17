import 'package:flutter_test/flutter_test.dart';
import 'package:slate/core/interaction/timeline_math.dart';

void main() {
  group('px ↔ minutes', () {
    test('zeroDate midnight is at hourCenter columns', () {
      expect(TimelineMath.pxToMinutes(2400 * 100.0), 0.0);
      expect(TimelineMath.minutesToPx(0), 2400 * 100.0);
    });

    test('roundtrip', () {
      for (final m in [-2880.0, -90.0, 0.0, 61.5, 720.0, 1439.0, 2000.0]) {
        expect(TimelineMath.pxToMinutes(TimelineMath.minutesToPx(m)),
            closeTo(m, 1e-9));
      }
    });

    test('100px = 60min, 25px = 15min', () {
      final base = TimelineMath.minutesToPx(0);
      expect(TimelineMath.pxToMinutes(base + 100), closeTo(60, 1e-9));
      expect(TimelineMath.pxToMinutes(base + 25), closeTo(15, 1e-9));
    });
  });

  group('snap', () {
    test('rounds to nearest 15', () {
      expect(TimelineMath.snap(0), 0);
      expect(TimelineMath.snap(7.4), 0);
      expect(TimelineMath.snap(7.5), 15);
      expect(TimelineMath.snap(22.4), 15);
      expect(TimelineMath.snap(22.6), 30);
      expect(TimelineMath.snap(846.0), 840); // 14:06 → 14:00
      expect(TimelineMath.snap(848.0), 855); // 14:08 → 14:15
      expect(TimelineMath.snap(-8.0), -15);
      expect(TimelineMath.snap(-7.0), 0);
    });
  });

  group('splitDay', () {
    test('same day', () {
      expect(TimelineMath.splitDay(0), (dayOffset: 0, minuteOfDay: 0));
      expect(TimelineMath.splitDay(870), (dayOffset: 0, minuteOfDay: 870));
      expect(TimelineMath.splitDay(1439), (dayOffset: 0, minuteOfDay: 1439));
    });

    test('next days', () {
      expect(TimelineMath.splitDay(1440), (dayOffset: 1, minuteOfDay: 0));
      expect(TimelineMath.splitDay(1440 + 615), (dayOffset: 1, minuteOfDay: 615));
    });

    test('negative offsets floor correctly', () {
      expect(TimelineMath.splitDay(-1), (dayOffset: -1, minuteOfDay: 1439));
      expect(TimelineMath.splitDay(-90), (dayOffset: -1, minuteOfDay: 1350));
      expect(TimelineMath.splitDay(-1440), (dayOffset: -1, minuteOfDay: 0));
      expect(TimelineMath.splitDay(-1441), (dayOffset: -2, minuteOfDay: 1439));
    });
  });

  group('dayFromOffset', () {
    test('crosses month boundaries', () {
      final zero = DateTime(2026, 7, 6);
      expect(TimelineMath.dayFromOffset(zero, 0), DateTime(2026, 7, 6));
      expect(TimelineMath.dayFromOffset(zero, 26), DateTime(2026, 8, 1));
      expect(TimelineMath.dayFromOffset(zero, -6), DateTime(2026, 6, 30));
    });
  });

  group('fmtTime', () {
    test('formats and wraps past midnight', () {
      expect(TimelineMath.fmtTime(0), '00:00');
      expect(TimelineMath.fmtTime(870), '14:30');
      expect(TimelineMath.fmtTime(1500), '01:00');
    });
  });

  group('grab-offset drop math (block drag)', () {
    test('drop at the block origin lands on its own start', () {
      // Block at 14:00, grabbed 30px (=18min) into the block.
      final blockLeftPx = TimelineMath.minutesToPx(840);
      const grabPx = 30.0;
      final pointerPx = blockLeftPx + grabPx;
      final minutes = TimelineMath.pxToMinutes(pointerPx - grabPx);
      expect(TimelineMath.snap(minutes), 840);
    });
  });

  group('lane assignment', () {
    test('non-overlapping spans all collapse to lane 0', () {
      final spans = [
        const LaneSpan(0, 100),
        const LaneSpan(120, 100),
        const LaneSpan(300, 100),
      ]..sort(TimelineMath.laneOrder);
      expect(TimelineMath.assignLanes(spans), [0, 0, 0]);
    });

    test('overlapping spans stack onto separate lanes', () {
      final spans = [
        const LaneSpan(0, 100), // 0..100
        const LaneSpan(50, 100), // overlaps → lane 1
        const LaneSpan(60, 100), // overlaps both → lane 2
      ]..sort(TimelineMath.laneOrder);
      expect(TimelineMath.assignLanes(spans), [0, 1, 2]);
    });

    test('pref keeps a block on its chosen lane (unless it can compact)', () {
      final spans = [
        const LaneSpan(0, 80, pref: 0), // existing taking lane 0
        const LaneSpan(0, 200, pref: 1), // dropped here, user chose lane 1
      ]..sort(TimelineMath.laneOrder);
      final lanes = TimelineMath.assignLanes(spans);
      // Find the pref'd (wider) span's lane.
      final wide = spans.indexWhere((s) => s.width == 200);
      expect(lanes[wide], 1); // Stays on 1 because 0 is occupied

      // If lane 0 is entirely free, it compacts upwards
      final spansCompacting = [const LaneSpan(0, 200, pref: 1)];
      expect(TimelineMath.assignLanes(spansCompacting)[0], 0);
    });
  });

  group('laneNearest — ghost follows the cursor', () {
    test('no overlap → always lane 0 whatever the cursor wants', () {
      final r = TimelineMath.laneNearest(
          const [], const LaneSpan(0, 100), 5,
          maxLanes: 1);
      expect(r, 0);
    });

    test('one overlapping block → cursor picks above or below', () {
      final existing = [const LaneSpan(0, 100)]; // occupies lane 0 at the slot
      final probe = const LaneSpan(0, 100); // overlaps it
      // Cursor high → lane 0 is taken → nearest free is 1.
      expect(
          TimelineMath.laneNearest(existing, probe, 0, maxLanes: 2), 1);
      // Cursor low → wants lane 1, which is free → 1.
      expect(
          TimelineMath.laneNearest(existing, probe, 1, maxLanes: 2), 1);
    });

    test('non-overlapping existing block leaves the probe on lane 0', () {
      final existing = [const LaneSpan(400, 100)]; // far away, no overlap
      final probe = const LaneSpan(0, 100);
      expect(
          TimelineMath.laneNearest(existing, probe, 3, maxLanes: 1), 0);
    });
  });

  group('pinnedIndex (resize stability)', () {
    test('pinned span keeps its lane even if it means bumping a leftmost span', () {
      // Scenario: A and B are touching on lane 0.
      // B resizes left, overlapping A. B is pinned to lane 0.
      // A (leftmost) should be bumped to lane 1, B keeps lane 0.
      final spans = [
        const LaneSpan(1100, 100, pref: 0, id: 'A'),
        const LaneSpan(1150, 150, pref: 0, id: 'B'), // Resized left, overlaps A
      ];
      // B is pinnedIndex = 1
      final lanes = TimelineMath.assignLanes(spans, gap: 0, pinnedIndex: 1);
      
      expect(lanes[1], 0); // B keeps lane 0
      expect(lanes[0], 1); // A is bumped to lane 1
    });

    test('pinned span does not bump a non-overlapping span', () {
      // Scenario: A and B don't overlap, but B is pinned to lane 0.
      final spans = [
        const LaneSpan(1100, 100, pref: 0, id: 'A'),
        const LaneSpan(1250, 150, pref: 0, id: 'B'),
      ];
      // B is pinnedIndex = 1
      final lanes = TimelineMath.assignLanes(spans, gap: 0, pinnedIndex: 1);
      
      expect(lanes[1], 0); // B keeps lane 0
      expect(lanes[0], 0); // A keeps lane 0, no overlap
    });
  });
}
