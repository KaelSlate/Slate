/// Pure geometry for the day-view hour ribbon (100 px = 1 hour, hourCenter =
/// column index of zeroDate 00:00). Exact inverse of _TimelineBlockLayer's
/// layout math in day_flow_view.dart — keep the two in lockstep.
class TimelineMath {
  static const double colWidth = 100.0;
  static const int hourCenter = 2400;
  static const int snapStep = 15;

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
  /// layer and the drop ghost. [spans] must already be sorted left-to-right
  /// (equal left → wider first). A span with a [LaneSpan.pref] takes that lane
  /// when it's free for its extent, else falls back to first-fit — this is
  /// what makes a user-chosen lane stick after the drop.
  static List<int> assignLanes(List<LaneSpan> spans, {double gap = 5.0, int? pinnedIndex}) {
    final rowRight = <double>[];
    final lanes = List<int>.filled(spans.length, 0);

    int? pinLane;
    double pinL = 0, pinR = 0;
    if (pinnedIndex != null && pinnedIndex >= 0 && pinnedIndex < spans.length) {
      final s = spans[pinnedIndex];
      final p = s.pref;
      if (p != null && p >= 0) {
        pinLane = p;
        pinL = s.left;
        pinR = s.left + s.width;
        lanes[pinnedIndex] = p;
        while (rowRight.length <= p) {
          rowRight.add(-1.0e12);
        }
      }
    }

    bool free(int r, double left) => r >= rowRight.length || left >= rowRight[r] + gap;
    
    bool pinnedFree(int r, double left, double width) {
      if (r != pinLane) return true;
      return left >= pinR + gap || pinL >= left + width + gap;
    }

    for (var i = 0; i < spans.length; i++) {
      if (i == pinnedIndex && pinLane != null) continue;
      
      final g = spans[i];
      var lane = -1;
      final p = g.pref;
      if (p != null && p >= 0 && free(p, g.left) && pinnedFree(p, g.left, g.width)) {
        lane = p;
      }
      if (lane == -1) {
        for (var r = 0; ; r++) {
          if (free(r, g.left) && pinnedFree(r, g.left, g.width)) {
            lane = r;
            break;
          }
        }
      }
      while (rowRight.length <= lane) {
        rowRight.add(-1.0e12);
      }
      rowRight[lane] = g.left + g.width;
      lanes[i] = lane;
    }
    return lanes;
  }

  /// Which lane the assignment gives the probe span among the existing ones.
  /// Honest drop preview: the ghost sits exactly where the block will land.
  static int laneForProbe(List<LaneSpan> existing, LaneSpan probe,
      {double gap = 5.0}) {
    final all = [...existing, probe]..sort(laneOrder);
    final lanes = assignLanes(all, gap: gap);
    for (var i = 0; i < all.length; i++) {
      if (identical(all[i], probe)) return lanes[i];
    }
    return 0;
  }

  /// The free lane NEAREST to [desired] for [probe], searching outward among
  /// the already-assigned [existing] spans — the ghost follows the cursor's
  /// vertical position but never lies down on top of another block.
  /// [maxLanes] caps the search to lanes that actually fit the ribbon.
  static int laneNearest(List<LaneSpan> existing, LaneSpan probe, int desired,
      {double gap = 5.0, int maxLanes = 1}) {
    final cap = maxLanes < 1 ? 1 : maxLanes;
    final want = desired.clamp(0, cap - 1);
    final sorted = [...existing]..sort(laneOrder);
    final lanes = assignLanes(sorted, gap: gap);
    bool collides(int lane) {
      for (var i = 0; i < sorted.length; i++) {
        if (lanes[i] != lane) continue;
        final s = sorted[i];
        if (probe.left < s.left + s.width + gap &&
            s.left < probe.left + probe.width + gap) {
          return true;
        }
      }
      return false;
    }

    if (!collides(want)) return want;
    for (var d = 1; d < cap; d++) {
      final below = want + d;
      if (below < cap && !collides(below)) return below;
      final above = want - d;
      if (above >= 0 && !collides(above)) return above;
    }
    return want;
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

class LaneSpan {
  final double left;
  final double width;
  /// Sticky lane to hold this block on (null = first-fit).
  final int? pref;
  /// Stable tiebreak key for [TimelineMath.laneOrder] (null = fall back to width).
  final String? id;
  const LaneSpan(this.left, this.width, {this.pref, this.id});
}
