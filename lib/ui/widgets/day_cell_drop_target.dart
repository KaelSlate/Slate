import 'package:flutter/material.dart';

import '../../core/interaction/drag_session.dart';
import '../../core/state/task_state.dart';
import '../../core/theme/app_theme.dart';

/// Drop zone for a week/month day cell. Registers itself by global rect
/// (initState/dispose — PageView page flips keep the registry correct for free).
///
/// The cell splits at the SCHEDULED│TO-SCHEDULE divider the cell already draws
/// between timed and untimed tasks: cursor ABOVE it = keep the time, BELOW = drop
/// it. That split still decides the outcome — but it is no longer PAINTED. The
/// incoming card itself, rendered in its destination group (see DropFuture), is
/// what shows where it lands; this widget only frames the receiving day.
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

  const DayCellDropTarget({
    super.key,
    required this.date,
    required this.taskState,
    required this.builder,
    this.settleTopOffset = 92,
    this.settleHeight = 30,
    this.highlightRadius = const BorderRadius.all(Radius.circular(10)),
    this.highlightInsets = EdgeInsets.zero,
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

  /// Global Y of the keep/clear boundary — a STABLE fraction of the cell, never
  /// the live divider box. This is the fix for the flicker/teleport: reading the
  /// divider made the boundary depend on the layout, but inserting the "show the
  /// future" preview MOVES the divider (a timed group appears/vanishes), which
  /// flipped the decision, which moved the preview, which moved the divider — a
  /// feedback loop. A fixed fraction can't move, so the decision is rock-steady.
  /// There is no drawn line to disagree with it; the incoming card's own time
  /// (present above, gone below) is what tells you which half you're in.
  double _splitGlobalY(Rect r) {
    final head = widget.settleTopOffset.clamp(0.0, r.height);
    return r.top + head + (r.height - head) * 0.5;
  }

  /// 'whole' — an untimed task has exactly ONE destination (unallocated), so no
  /// split, no line, no rejection: the day accepts it anywhere.
  /// 'keep' (top) | 'clear' (bottom) | 'reject' (same-day keep is a no-op).
  String _modeFor(Offset globalPos, DragPayload p) {
    if (p.task.startTime == null) return 'whole';
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
