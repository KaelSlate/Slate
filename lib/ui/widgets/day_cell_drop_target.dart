import 'package:flutter/material.dart';

import '../../core/interaction/drag_session.dart';
import '../../core/state/task_state.dart';
import '../../core/theme/app_theme.dart';

/// Drop zone for a week/month day cell. Registers itself by global rect
/// (initState/dispose — PageView page flips keep the registry correct for free).
///
/// A TIMED task dropped here can either keep its time (join the scheduled group)
/// or lose it (join the unscheduled pool). You choose by AIMING AT THE GROUP —
/// the boundary sits exactly where the two groups actually meet. See
/// [_splitGlobalY] for why that boundary is measured from the real tasks only.
///
/// [splitTime] turns the choice off entirely (the month cell): there, a drop
/// simply moves the task to that day and keeps its time. A month cell shows two
/// rows at most, so there is no honest room to aim at a group — zoom into the
/// day to re-schedule.
class DayCellDropTarget extends StatefulWidget {
  final DateTime date;
  final TaskState? taskState;

  /// Builds the cell content. The passed key MUST be attached to the cell's
  /// timed/untimed divider — it is what the hit-test splits keep/clear on.
  final Widget Function(GlobalKey dividerKey) builder;

  /// Approximate slot the preview settles into, inside the cell.
  final double settleTopOffset;
  final double settleHeight;
  final BorderRadius highlightRadius;
  /// Inset of the VISIBLE card inside this widget's box (the week column's
  /// glow background carries a margin) — the wash must hug the card frame.
  final EdgeInsets highlightInsets;

  /// Height of ONE task row (card + its bottom margin). The keep/clear boundary
  /// is measured in these, so it lands on the real gap between the groups.
  final double rowHeight;

  /// False → no keep/clear choice at all; a timed drop always keeps its time.
  final bool splitTime;

  const DayCellDropTarget({
    super.key,
    required this.date,
    required this.taskState,
    required this.builder,
    this.settleTopOffset = 92,
    this.settleHeight = 30,
    this.highlightRadius = const BorderRadius.all(Radius.circular(10)),
    this.highlightInsets = EdgeInsets.zero,
    this.rowHeight = 38,
    this.splitTime = true,
  });

  @override
  State<DayCellDropTarget> createState() => _DayCellDropTargetState();
}

class _DayCellDropTargetState extends State<DayCellDropTarget>
    implements DropZone {
  /// Owned here so it stays stable across cell rebuilds.
  final GlobalKey _dividerKey = GlobalKey();

  @override
  String get id => 'cell#${identityHashCode(this)}';

  @override
  int get priority => 0;

  @override
  String get landingChrome => 'card';

  @override
  void initState() {
    super.initState();
    DragSession.instance.registry.register(this);
  }

  @override
  void dispose() {
    DragSession.instance.registry.unregister(this);
    super.dispose();
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  @override
  Rect? globalRect() {
    if (!mounted) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  bool _isSameDay(DragPayload p) {
    final d = p.sourceDay;
    return d != null && _sameDay(d, widget.date);
  }

  @override
  bool canAccept(DragPayload p) {
    if (widget.taskState == null) return false;
    if (p.kind == DragSourceKind.inboxCard) return true;
    return !_isSameDay(p) || p.task.startTime != null;
  }

  /// How many TIMED tasks really sit on this day. Read from the store, never
  /// from the laid-out widgets — that independence is what kills the feedback
  /// loop (see [_splitGlobalY]).
  int _realTimedCount() {
    final ts = widget.taskState;
    if (ts == null) return 0;
    final d = DateTime(widget.date.year, widget.date.month, widget.date.day);
    final tasks = ts.tasksForDateNotifier(d.millisecondsSinceEpoch).value;
    return tasks.where((t) => t.startTime != null).length;
  }

  /// Global Y where the scheduled group ends and the unscheduled pool begins —
  /// i.e. you aim AT THE GROUP you want, which is the only thing that matches
  /// what your eyes see.
  ///
  /// Measured from the REAL tasks (the store), never from the live widgets: the
  /// "show the future" preview inserts a row, which would move a widget-measured
  /// boundary, which would flip the decision, which would move the preview — the
  /// flicker/teleport loop. Real counts don't move while you hover, so it's
  /// rock-steady.
  ///
  /// An EMPTY timed group still reserves ONE row, so "keep the time" stays
  /// aimable on a day that holds only untimed tasks — or none at all. Below that
  /// reserved row is the pool, which is exactly where those untimed tasks are.
  double _splitGlobalY(Rect r) {
    final head = widget.settleTopOffset.clamp(0.0, r.height);
    final timed = _realTimedCount();
    final rows = timed == 0 ? 1 : timed;
    final y = r.top + head + rows * widget.rowHeight;
    return y.clamp(r.top + head, r.bottom - 4);
  }

  /// 'whole' — an untimed task has exactly ONE destination (unallocated), so no
  /// split, no line, no rejection: the day accepts it anywhere.
  /// 'keep' (top) | 'clear' (bottom) | 'reject' (same-day keep is a no-op).
  String _modeFor(Offset globalPos, DragPayload p) {
    if (p.task.startTime == null) return 'whole';
    // Month: no aiming — a drop keeps the time, full stop.
    if (!widget.splitTime) return _isSameDay(p) ? 'reject' : 'keep';
    final r = globalRect();
    final overTop = r == null ? false : globalPos.dy < _splitGlobalY(r);
    if (overTop) return _isSameDay(p) ? 'reject' : 'keep';
    return 'clear';
  }

  @override
  DropHover? hoverAt(Offset globalPos, DragPayload p) {
    // cellMode drives the "show the future" preview (which group the incoming
    // card joins); no badgeText — the cell no longer NARRATES the outcome, the
    // rendered card IS the outcome. See DropFuture.
    return DropHover(
      zoneId: id,
      targetDay: widget.date,
      cellMode: _modeFor(globalPos, p),
    );
  }

  @override
  DropResult? onDrop(Offset globalPos, DragPayload p) {
    final ts = widget.taskState;
    if (ts == null) return null;
    final mode = _modeFor(globalPos, p);
    if (mode == 'reject') return null;
    if (mode == 'clear') {
      ts.unschedule(p.task, widget.date);
    } else {
      ts.assignToDay(p.task, widget.date); // 'keep' holds the time; 'whole' has none
    }
    final r = globalRect();
    if (r == null) return const DropResult();
    // Everything but 'keep' lands in the unallocated section, below the divider.
    final top = (mode == 'keep'
            ? r.top + widget.settleTopOffset
            : _splitGlobalY(r) + 6)
        .clamp(r.top, r.bottom - widget.settleHeight);
    return DropResult(
      settleGlobalRect:
          Rect.fromLTWH(r.left + 6, top, r.width - 12, widget.settleHeight),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.builder(_dividerKey),
        // A soft honey frame on the WHOLE cell when it is the drop target — the
        // day says "I'm receiving this". Where inside it the card lands, and
        // whether it keeps its time, is shown by the haloed card itself (see
        // DropFuture), not by a wash or a badge.
        Positioned.fill(
          child: IgnorePointer(
            child: Padding(
              padding: widget.highlightInsets,
              child: ValueListenableBuilder<DropHover?>(
                valueListenable: DragSession.instance.hover,
                builder: (_, h, _) {
                  final on = h?.zoneId == id;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      borderRadius: widget.highlightRadius,
                      color: on
                          ? AppTheme.honey.withValues(alpha: 0.05)
                          : Colors.transparent,
                      border: Border.all(
                        color: on
                            ? AppTheme.honey.withValues(alpha: 0.30)
                            : Colors.transparent,
                        width: 1,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}
