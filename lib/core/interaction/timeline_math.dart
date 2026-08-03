import 'dart:math' as math;

/// Pure geometry for the day-view hour ribbon (100 px = 1 hour, hourCenter =
/// column index of zeroDate 00:00). Exact inverse of _TimelineBlockLayer's
/// layout math in day_flow_view.dart — keep the two in lockstep.
class TimelineMath {
  static const double colWidth = 100.0;
  static const int hourCenter = 2400;
  static const int snapStep = 15;

  // ── Block geometry — ONE set of numbers ───────────────────────────────────
  // These used to be duplicated in _TimelineBlockLayer and _TimelineRibbonZone.
  // The ghost and the block it promises must be laid out by the same constants
  // or the preview lies by a row.
  static const double blockH = 36.0;
  static const double rowGap = 5.0;
  static const double topPad = 44.0; // clears the hour-label row

  /// A block narrower than this is unreadable, so it is drawn at [minBlockWidth]
  /// whatever its duration.
  static const double minBlockWidth = 48.0;

  /// Width a block OCCUPIES — pixels and lane packing must agree on it. Packing
  /// with the true duration while painting the clamped minimum is how two
  /// 15-minute blocks got the same row and then overlapped on screen.
  static double blockWidth(int durationMinutes) =>
      math.max(minBlockWidth, durationMinutes / 60.0 * colWidth);

  /// Ribbon-local top of a lane.
  static double laneTop(int lane) => topPad + lane * (blockH + rowGap);

  /// Absolute ribbon px (local x + scrollOffset) → continuous minutes from
  /// zeroDate 00:00. Negative = days before zeroDate.
  static double pxToMinutes(double absolutePx) =>
      (absolutePx / colWidth - hourCenter) * 60.0;

  static double minutesToPx(num minutes) =>
      (hourCenter + minutes / 60.0) * colWidth;

  static int snap(double minutes) => (minutes / snapStep).round() * snapStep;

  /// Continuous minutes → (whole-day offset from zeroDate, minute of day).
  /// Floor division so pre-zeroDate days come out right.
  static ({int dayOffset, int minuteOfDay}) splitDay(int minutes) {
    final dayOffset = (minutes / 1440.0).floor();
    return (dayOffset: dayOffset, minuteOfDay: minutes - dayOffset * 1440);
  }

  /// DST-safe: constructor arithmetic, matching the week view's pattern.
  static DateTime dayFromOffset(DateTime zeroDate, int dayOffset) =>
      DateTime(zeroDate.year, zeroDate.month, zeroDate.day + dayOffset);

  static String fmtTime(int minuteOfDay) {
    final h = (minuteOfDay ~/ 60) % 24;
    final m = minuteOfDay % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// Greedy lane assignment — THE single source of truth shared by the block
  /// layer and the drop ghost.
  /// 
  /// The algorithm is "Sticky & Compacting" (Apple-level UX):
  /// 1. Processes tasks by their preferred lane first (giving manipulated blocks priority).
  /// 2. Tries to pack them into lower rows first (auto-compacting).
  /// 3. Falls back to higher rows if blocked.
  /// Uses true interval overlap tracking rather than simple left-to-right sweep.
  static List<int> assignLanes(List<LaneSpan> spans, {double gap = 5.0, int? pinnedIndex}) {
    final lanes = List<int>.filled(spans.length, 0);
    final laneIntervals = <List<_Interval>>[];

    bool isFree(int r, double left, double width) {
      if (r >= laneIntervals.length) return true;
      final right = left + width;
      for (final inv in laneIntervals[r]) {
        // Overlap condition: left < inv.right + gap && inv.left < right + gap
        if (left < inv.right + gap && inv.left < right + gap) {
          return false;
        }
      }
      return true;
    }

    void place(int i, int r) {
      lanes[i] = r;
      while (laneIntervals.length <= r) {
        laneIntervals.add([]);
      }
      laneIntervals[r].add(_Interval(spans[i].left, spans[i].left + spans[i].width));
    }

    // Determine processing order. The pinned span is lifted OUT of the sort and
    // put at the front — deciding it inside the comparator is not a strict weak
    // ordering (it answers -1 for both operands when they are the same element),
    // which a sort is entitled to make a mess of.
    final order = List<int>.generate(spans.length, (i) => i)
      ..removeWhere((i) => i == pinnedIndex);
    order.sort((a, b) {
      final spanA = spans[a];
      final spanB = spans[b];

      // 2. By pref (ascending, nulls last)
      final prefA = spanA.pref ?? 999999;
      final prefB = spanB.pref ?? 999999;
      final byPref = prefA.compareTo(prefB);
      if (byPref != 0) return byPref;

      // 3. By left
      final byLeft = spanA.left.compareTo(spanB.left);
      if (byLeft != 0) return byLeft;

      // 4. By id (stable)
      final idA = spanA.id;
      final idB = spanB.id;
      if (idA != null && idB != null) {
        return idA.compareTo(idB);
      }
      return 0;
    });
    if (pinnedIndex != null &&
        pinnedIndex >= 0 &&
        pinnedIndex < spans.length) {
      order.insert(0, pinnedIndex); // placed first, keeps its row, bumps others
    }

    for (final i in order) {
      final g = spans[i];
      final p = g.pref;
      var placedLane = -1;

      if (i == pinnedIndex && p != null && p >= 0) {
        // Pinned block MUST go to its pref.
        placedLane = p;
      } else {
        // Try compacting: rows < pref
        final limit = p != null && p >= 0 ? p : 0;
        for (var r = 0; r < limit; r++) {
          if (isFree(r, g.left, g.width)) {
            placedLane = r;
            break;
          }
        }

        // Try pref
        if (placedLane == -1 && p != null && p >= 0) {
          if (isFree(p, g.left, g.width)) {
            placedLane = p;
          }
        }

        // Fallback: first fit from max(0, p) upwards
        if (placedLane == -1) {
          final start = p != null && p >= 0 ? p + 1 : 0;
          for (var r = start; ; r++) {
            if (isFree(r, g.left, g.width)) {
              placedLane = r;
              break;
            }
          }
        }
      }

      place(i, placedLane);
    }

    return lanes;
  }

  /// THE drop preview: the row a dropped block will occupy among [existing].
  ///
  /// Three things make the ghost's promise binding, and all three were broken:
  ///
  /// 1. **The rows it measures against are the rows on screen.** [existing]
  ///    carries each block's sticky `pref`, so [assignLanes] here reproduces the
  ///    live layout exactly. The old second packer (`laneNearest`) re-derived
  ///    them from scratch WITHOUT prefs — and since placement is pref-ordered, a
  ///    sticky layout and a fresh one can come out mirrored. The ghost then
  ///    measured the wrong row, drew itself over a real block, and the drop
  ///    landed a row away from where the preview had flown.
  /// 2. **A drop asks for a row, it does not take one.** The probe is fitted
  ///    AFTER everyone else and never displaces a block: pointing at an occupied
  ///    row means "near here", not "move over". Feeding the probe through
  ///    [assignLanes] as a peer let it evict whatever sat where the cursor was —
  ///    the ghost drew straight onto that block, and on release the block it
  ///    shoved slid away underneath. Only a RESIZE may bump neighbours, and that
  ///    is what `pinnedIndex` is for.
  /// 3. **The caller hands the answer back** as the dropped task's `pref`, so
  ///    the layer's next pack reproduces this row rather than first-fitting.
  ///
  /// The search itself is the same rule [assignLanes] applies to any span:
  /// compact into a free row ABOVE the wish, else take the wish, else the first
  /// free row below. So a lone block never floats under an empty row just
  /// because the pointer was low.
  static int laneForDrop(List<LaneSpan> existing, LaneSpan probe,
      {double gap = 0}) {
    final rows = assignLanes(existing, gap: gap);

    bool free(int r) {
      for (var i = 0; i < existing.length; i++) {
        if (rows[i] != r) continue;
        final s = existing[i];
        if (probe.left < s.left + s.width + gap &&
            s.left < probe.left + probe.width + gap) {
          return false;
        }
      }
      return true;
    }

    final wish = (probe.pref ?? 0) < 0 ? 0 : (probe.pref ?? 0);
    for (var r = 0; r < wish; r++) {
      if (free(r)) return r;
    }
    if (free(wish)) return wish;
    for (var r = wish + 1;; r++) {
      if (free(r)) return r;
    }
  }

  /// Canonical span ordering for lane assignment: left-to-right, equal left →
  /// by id (STABLE, duration-independent). Ordering by width flipped when a
  /// block was resized, which swapped two rows — id never changes, so it can't.
  static int laneOrder(LaneSpan a, LaneSpan b) {
    final byLeft = a.left.compareTo(b.left);
    if (byLeft != 0) return byLeft;
    final ai = a.id, bi = b.id;
    if (ai != null && bi != null) return ai.compareTo(bi);
    return b.width.compareTo(a.width);
  }
}

class _Interval {
  final double left;
  final double right;
  _Interval(this.left, this.right);
}

class LaneSpan {
  final double left;
  final double width;
  /// Sticky lane to hold this block on (null = first-fit).
  final int? pref;
  /// Stable tiebreak key for [TimelineMath.laneOrder] (null = fall back to width).
  final String? id;
  const LaneSpan(this.left, this.width, {this.pref, this.id});
}
