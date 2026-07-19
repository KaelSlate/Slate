import 'package:flutter/material.dart';

import '../../core/interaction/drag_session.dart';
import '../../core/state/task_state.dart';
import '../../core/theme/app_theme.dart';
import 'anytime_rail.dart';

/// Drop zone for a week/month day cell. Registers itself by global rect
/// (initState/dispose — PageView page flips keep the registry correct for free).
///
/// A TIMED task dropped on the cell's BODY moves to that day and keeps its hour
/// — the default every calendar on earth uses. Dropping it on the [AnytimeRail]
/// pinned to the cell's bottom edge clears the time instead. One rule, and it
/// holds on an empty day, on a day of only-timed tasks, on the same day, and in
/// a month cell — none of which have room to aim at a group.
class DayCellDropTarget extends StatefulWidget {
  final DateTime date;
  final TaskState? taskState;

  /// Builds the cell content. The passed key is attached to the cell's
  /// timed/untimed divider (kept for the list's own layout; the drop no longer
  /// measures anything from it).
  final Widget Function(GlobalKey dividerKey) builder;

  /// Approximate slot the preview settles into, inside the cell.
  final double settleTopOffset;
  final double settleHeight;
  final BorderRadius highlightRadius;
  /// Inset of the VISIBLE card inside this widget's box (the week column's
  /// glow background carries a margin) — the frame must hug the card.
  final EdgeInsets highlightInsets;

  /// Height of the "Anytime" rail at the cell's bottom edge.
  final double railHeight;

  const DayCellDropTarget({
    super.key,
    required this.date,
    required this.taskState,
    required this.builder,
    this.settleTopOffset = 92,
    this.settleHeight = 30,
    this.highlightRadius = const BorderRadius.all(Radius.circular(10)),
    this.highlightInsets = EdgeInsets.zero,
    this.railHeight = 22,
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
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _publishCardWidth());
  }

  @override
  void didUpdateWidget(DayCellDropTarget old) {
    super.didUpdateWidget(old);
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _publishCardWidth());
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

  /// Tell the session how wide a card is HERE, so the flying preview is carried
  /// at the size of what it becomes instead of the size it came from (an inbox
  /// card is far wider than a day row). Every cell in a row/grid is the same
  /// width, so any one of them is authoritative.
  void _publishCardWidth() {
    final r = globalRect();
    if (r == null) return;
    final w = r.width - widget.highlightInsets.horizontal - 12;
    if (w > 0) DragSession.instance.noteOverviewCardWidth(w);
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

  /// Local Y of the rail's top edge: the head of the task area, right under the
  /// day's own head. A CONSTANT offset from the cell's TOP — it owes nothing to
  /// the cell's content, so the "show the future" preview can never move the
  /// line that decides the preview. That is what retires the flicker/teleport
  /// loop for good.
  double get _railTopLocal => widget.settleTopOffset;

  /// Aiming slop. The strip is thin by design; the zone that answers to it is
  /// not — a drop target you have to hit precisely is a target you fight.
  static const double _slop = 10;

  /// 'whole' — an untimed task has exactly ONE destination (unallocated), so no
  /// choice and no rail: the day accepts it anywhere.
  /// 'keep' (body) | 'clear' (rail) | 'reject' (same-day body is a no-op).
  String _modeFor(Offset globalPos, DragPayload p) {
    if (p.task.startTime == null) return 'whole';
    final r = globalRect();
    if (r != null) {
      final top = r.top + _railTopLocal;
      final dy = globalPos.dy;
      if (dy >= top - _slop && dy <= top + widget.railHeight + _slop) {
        return 'clear';
      }
    }
    return _isSameDay(p) ? 'reject' : 'keep';
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
    // First-frame estimate only — the refine-to-card path corrects it to the
    // real row as soon as the list has laid the new card out.
    final head = r.top + widget.settleTopOffset;
    final top = (mode == 'keep' ? head : head + widget.railHeight + 6)
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
                  // 'reject' (same-day body) lights nothing — the cell says
                  // "no change" rather than pretending to be a target.
                  final on = h?.zoneId == id && h?.cellMode != 'reject';
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
        // The home of "no time" — see AnytimeRail. Sits at the head of the task
        // area, outside the list's layout, so it can never reflow what it
        // decides. Revealed only on the day the cursor is addressing.
        Positioned(
          left: widget.highlightInsets.left + 6,
          right: widget.highlightInsets.right + 6,
          top: _railTopLocal,
          child: ValueListenableBuilder<DropHover?>(
            valueListenable: DragSession.instance.hover,
            builder: (_, h, _) {
              final here = h?.zoneId == id;
              final mode = h?.cellMode;
              return AnytimeRail(
                // Every mode but 'whole' — an untimed task has no choice to make.
                visible: here && mode != null && mode != 'whole',
                armed: here && mode == 'clear',
                height: widget.railHeight,
              );
            },
          ),
        ),
      ],
    );
  }
}
