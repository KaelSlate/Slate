import 'package:flutter/material.dart';

import '../../core/engine/slate_core_bridge.dart';
import '../../core/interaction/drag_session.dart';
import '../../core/theme/app_theme.dart';
import 'hover_task_card.dart';

/// "Show the future", not "describe it".
///
/// The old drop language DESCRIBED the outcome — a grey split wash, a line, a
/// black "No time" badge. That reads like an OSD, not a calendar. Apple never
/// narrates a drop; it shows the thing landing where it will land.
///
/// So a day cell that is the drop target renders the dragged task AS IT WILL BE:
/// the real card, in its real group, at its sorted spot — carrying its time
/// (kept) or without one (cleared). The presence or absence of the time badge
/// IS the message; no words. On drop the real mutation produces this exact card,
/// so the preview can never lie about where it lands or what happens to its time.
class DropFuture {
  /// The card to render — identical to the one the drop will create.
  final RustTask projected;

  /// Which group it joins: true → timed (keeps its time), false → untimed.
  final bool keepsTime;

  const DropFuture(this.projected, this.keepsTime);

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// The live preview for [date], or null when this cell is not the drop
  /// target. Reads the session directly — call inside a builder that listens to
  /// [DragSession.instance.hover] so the cell reflows as the cursor crosses the
  /// divider (timed ↔ untimed) or moves between days.
  static DropFuture? forDate(DateTime date) {
    final s = DragSession.instance;
    if (!s.isActive) return null;
    final h = s.hover.value;
    final p = s.payload;
    if (h == null || p == null) return null;
    if (h.cellMode == null) return null; // only split cells set a mode
    final td = h.targetDay;
    if (td == null || !_sameDay(td, date)) return null;

    final t = p.task;
    // 'reject' = same-day keep, a no-op: the card stays exactly where it is.
    if (h.cellMode == 'reject') return DropFuture(t, t.startTime != null);

    final keep = h.cellMode == 'keep'; // 'clear' / 'whole' → no time
    if (keep) return DropFuture(t, true);
    // copyWith can't null startTime (it uses ??) — raw constructor, as the real
    // reschedule does, so the cleared preview matches the committed card.
    return DropFuture(
      RustTask(
        id: t.id,
        title: t.title,
        isCompleted: t.isCompleted,
        createdAt: t.createdAt,
        updatedAt: t.updatedAt,
        startAt: t.startAt,
        endAt: t.endAt,
        userId: t.userId,
        isInbox: false,
        startTime: null,
        endTime: null,
        priority: t.priority,
        tags: t.tags,
      ),
      false,
    );
  }

  /// The incoming card, framed by a soft honey halo so the eye reads it as the
  /// one being placed. IgnorePointer — it is a preview, never a target.
  Widget card({EdgeInsets margin = const EdgeInsets.only(bottom: 4)}) =>
      IgnorePointer(
        // Stable key so a list reconciles the preview against real rows by
        // identity, not position, as it hops groups mid-drag.
        key: ValueKey('future-${projected.id}'),
        child: Padding(
          padding: margin,
          child: _LandingHalo(
            child: HoverTaskCard(
              key: ValueKey('future-${projected.id}'),
              task: projected,
              compact: true,
              enablePeek: false,
            ),
          ),
        ),
      );
}

/// A soft honey bloom behind the incoming card — the app's signature warm
/// accent (welcome / first-run stroke), here saying "this is the one landing".
class _LandingHalo extends StatelessWidget {
  final Widget child;
  const _LandingHalo({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.honey.withValues(alpha: 0.55), width: 1),
        boxShadow: const [
          BoxShadow(color: AppTheme.honeyGlow, blurRadius: 12, spreadRadius: 1),
        ],
      ),
      child: child,
    );
  }
}
