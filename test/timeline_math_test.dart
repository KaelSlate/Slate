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

  group('block geometry — packing and pixels are the same number', () {
    test('a short block occupies the minimum it is drawn at', () {
      expect(TimelineMath.blockWidth(15), TimelineMath.minBlockWidth);
      expect(TimelineMath.blockWidth(20), TimelineMath.minBlockWidth);
      // 29 min is the break-even at 100px/hour.
      expect(TimelineMath.blockWidth(60), 100.0);
      expect(TimelineMath.blockWidth(90), 150.0);
    });

    test('two short blocks 15 min apart do NOT share a row', () {
      // THE bug: packed by true duration (25px) they don't overlap and land on
      // the same row — then both paint 48px wide and sit on top of each other.
      final a = LaneSpan(TimelineMath.minutesToPx(600),
          TimelineMath.blockWidth(15),
          id: 'A');
      final b = LaneSpan(TimelineMath.minutesToPx(615),
          TimelineMath.blockWidth(15),
          id: 'B');
      final lanes = TimelineMath.assignLanes([a, b], gap: 0);
      expect(lanes[0] == lanes[1], isFalse,
          reason: 'they overlap on screen, so they must not share a row');
    });

    test('laneTop matches the block layer stride', () {
      expect(TimelineMath.laneTop(0), TimelineMath.topPad);
      expect(TimelineMath.laneTop(2),
          TimelineMath.topPad + 2 * (TimelineMath.blockH + TimelineMath.rowGap));
    });
  });

  group('laneForDrop — the ghost promises what the packer will do', () {
    /// The lane the block layer will actually give each span, so a test can
    /// check the ghost against reality rather than against itself.
    Map<String, int> realRows(List<LaneSpan> all) {
      final lanes = TimelineMath.assignLanes(all, gap: 0);
      return {for (var i = 0; i < all.length; i++) all[i].id!: lanes[i]};
    }

    test('no overlap → lane 0 however low the cursor points', () {
      // A lone block must not float below itself just because the pointer is low.
      const existing = [LaneSpan(400, 100, id: 'A', pref: 0)];
      const probe = LaneSpan(0, 100, id: 'P', pref: 5);
      expect(TimelineMath.laneForDrop(existing, probe, gap: 0), 0);
    });

    test('an occupied row pushes the probe down', () {
      const existing = [LaneSpan(0, 100, id: 'A', pref: 0)];
      const probe = LaneSpan(0, 100, id: 'P', pref: 0);
      expect(TimelineMath.laneForDrop(existing, probe, gap: 0), 1);
    });

    test('sticky rows: the ghost reads the layout that EXISTS, not a fresh one',
        () {
      // THE regression. A sits on row 1 and B on row 0 — a perfectly reachable
      // state, because the packer is sticky (pref-first). A fresh pref-less
      // pack of the same two spans comes out MIRRORED (A→0, B→1), which is what
      // the old second packer computed. The ghost then measured the wrong row,
      // drew itself over A, and the drop landed a row away.
      const a = LaneSpan(800, 400, id: 'A', pref: 1); // 08:00–12:00
      const b = LaneSpan(1000, 100, id: 'B', pref: 0); // 10:00–11:00
      const probe = LaneSpan(1150, 100, id: 'P', pref: 0); // 11:30, cursor row 0

      // Reality: A really is on row 1, B on row 0.
      final rows = realRows(const [a, b, probe]);
      expect(rows['A'], 1);
      expect(rows['B'], 0);

      final ghost = TimelineMath.laneForDrop(const [a, b], probe, gap: 0);
      expect(ghost, rows['P'],
          reason: 'the ghost IS the packer — it cannot differ from the landing');
      expect(ghost, 0, reason: 'row 0 is genuinely free at 11:30–12:30');
    });

    test('the promised lane survives the layer re-packing everything', () {
      // The drop hands laneForDrop's answer back as the new block's pref. The
      // layer then packs the lot from scratch — and must reproduce the same
      // rows, or the settled preview and the block that appears disagree. This
      // is the exact "flew there, then dropped a row" symptom, in one assert.
      const existing = [
        LaneSpan(800, 400, id: 'A', pref: 1),
        LaneSpan(1000, 100, id: 'B', pref: 0),
        LaneSpan(1150, 200, id: 'C', pref: 2),
      ];
      final before = realRows(existing);

      for (final desired in [0, 1, 2, 3]) {
        final probe = LaneSpan(900, 300, id: 'P', pref: desired);
        final promised = TimelineMath.laneForDrop(existing, probe, gap: 0);

        // What the block layer will hold a frame later: everyone's sticky row
        // plus the dropped block carrying the promised row.
        final after = realRows([
          ...existing,
          LaneSpan(probe.left, probe.width, id: 'P', pref: promised),
        ]);
        expect(after['P'], promised,
            reason: 'cursor row $desired: promised $promised, landed ${after['P']}');
        for (final s in existing) {
          expect(after[s.id], before[s.id],
              reason: '${s.id} must not be shoved aside by a drop');
        }
      }
    });

    test('the promised lane is never one an existing block is sitting on', () {
      const existing = [
        LaneSpan(800, 400, id: 'A', pref: 1),
        LaneSpan(1000, 100, id: 'B', pref: 0),
        LaneSpan(1150, 200, id: 'C', pref: 2),
      ];
      final rows = realRows(existing);
      for (final desired in [0, 1, 2, 3, 7]) {
        final probe = LaneSpan(900, 300, id: 'P', pref: desired);
        final lane = TimelineMath.laneForDrop(existing, probe, gap: 0);
        for (final s in existing) {
          if (rows[s.id] != lane) continue;
          final overlaps = probe.left < s.left + s.width &&
              s.left < probe.left + probe.width;
          expect(overlaps, isFalse,
              reason: 'cursor row $desired → lane $lane collides with ${s.id}');
        }
      }
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
