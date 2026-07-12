import 'package:flutter/material.dart';

import '../../core/interaction/drag_session.dart';
import '../../core/state/task_state.dart';

/// Drop zone for a week/month day cell. Registers itself by global rect
/// (initState/dispose — PageView page flips keep the registry correct for free).
///
/// The cell splits at the SCHEDULED│TO-SCHEDULE divider the cell already draws
/// between timed and untimed tasks: hover ABOVE it = keep the time, BELOW = drop
/// the time. The wash never draws its own line when that divider exists (it owns
/// [dividerKey]); it just stops short of it on both sides.
class DayCellDropTarget extends StatefulWidget {
  final DateTime date;
  final TaskState? taskState;

  /// Builds the cell content. The passed key MUST be attached to the cell's
  /// timed/untimed divider — it is what the wash and the hit-test split on.
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

  /// Gap so the wash never touches the divider line.
  static const double _gap = 4.0;

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

  /// Global Y of the cell's live divider; falls back to the list midpoint when
  /// the cell has only one group (no divider drawn).
  double _splitY(Rect r) {
    final box = _dividerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.attached && box.hasSize) {
      return box.localToGlobal(Offset.zero).dy + box.size.height / 2;
    }
    final head = widget.settleTopOffset.clamp(0.0, r.height);
    return r.top + head + (r.height - head) * 0.5;
  }

  /// 'whole' — an untimed task has exactly ONE destination (unallocated), so no
  /// split, no line, no rejection: the day accepts it anywhere.
  /// 'keep' (top) | 'clear' (bottom) | 'reject' (same-day keep is a no-op).
  String _modeFor(Offset globalPos, DragPayload p) {
    if (p.task.startTime == null) return 'whole';
    final r = globalRect();
    final overTop = r == null ? false : globalPos.dy < _splitY(r);
    if (overTop) return _isSameDay(p) ? 'reject' : 'keep';
    return 'clear';
  }

  @override
  DropHover? hoverAt(Offset globalPos, DragPayload p) => DropHover(
        zoneId: id,
        targetDay: widget.date,
        cellMode: _modeFor(globalPos, p),
      );

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
            : _splitY(r) + 6)
        .clamp(r.top, r.bottom - widget.settleHeight);
    return DropResult(
      settleGlobalRect:
          Rect.fromLTWH(r.left + 6, top, r.width - 12, widget.settleHeight),
    );
  }

  /// Divider Y in the wash's own (padded) coordinate space. null → no divider.
  double? _splitLocal() {
    final cellBox = context.findRenderObject() as RenderBox?;
    final divBox = _dividerKey.currentContext?.findRenderObject() as RenderBox?;
    if (cellBox == null || !cellBox.attached || !cellBox.hasSize) return null;
    if (divBox == null || !divBox.attached || !divBox.hasSize) return null;
    final dy = divBox.localToGlobal(Offset.zero).dy + divBox.size.height / 2;
    return cellBox.globalToLocal(Offset(0, dy)).dy - widget.highlightInsets.top;
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.passthrough,
      children: [
        widget.builder(_dividerKey),
        Positioned.fill(
          child: IgnorePointer(
            child: Padding(
              padding: widget.highlightInsets,
              child: ValueListenableBuilder<DropHover?>(
                valueListenable: DragSession.instance.hover,
                builder: (_, h, _) {
                  final on = h?.zoneId == id;
                  final mode = on ? (h?.cellMode ?? 'reject') : 'off';
                  // Read the divider's live Y in the BUILD phase — localToGlobal
                  // inside LayoutBuilder runs during layout and throws.
                  final local = _splitLocal();
                  final whole = mode == 'whole';
                  // 'whole' = one continuous wash (no split, no gaps, no line).
                  final gap = whole ? 0.0 : _gap;
                  final drawLine = local == null && !whole;
                  // Only the hovered zone lights; the other stays OFF.
                  final topOp = (whole || mode == 'keep') ? 1.0 : 0.0;
                  final bottomOp = (whole || mode == 'clear') ? 1.0 : 0.0;
                  return LayoutBuilder(builder: (context, c) {
                    final lineH = drawLine ? 0.5 : 0.0;
                    final maxTop =
                        (c.maxHeight - gap * 2 - lineH).clamp(0.0, c.maxHeight);
                    final split =
                        (local ?? c.maxHeight * 0.5).clamp(0.0, c.maxHeight);
                    return ClipRRect(
                      borderRadius: widget.highlightRadius,
                      // stretch: without it the Expanded wash below collapses to
                      // zero WIDTH (DecoratedBox has no child) and never shows.
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          SizedBox(
                            height: (split - gap).clamp(0.0, maxTop),
                            child: _wash(topOp),
                          ),
                          SizedBox(height: gap),
                          // The cell already draws its divider — never duplicate
                          // it. Only stand one in when the cell has none.
                          if (drawLine)
                            AnimatedOpacity(
                              duration: const Duration(milliseconds: 120),
                              opacity: on ? 1.0 : 0.0,
                              child: Container(
                                  height: 0.5,
                                  color: Colors.white.withOpacity(0.14)),
                            ),
                          SizedBox(height: gap),
                          Expanded(child: _wash(bottomOp)),
                        ],
                      ),
                    );
                  });
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _wash(double opacity) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 120),
      opacity: opacity,
      child: const DecoratedBox(
        decoration: BoxDecoration(color: Color(0x0DFFFFFF)),
      ),
    );
  }
}
