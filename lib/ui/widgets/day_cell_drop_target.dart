import 'package:flutter/material.dart';

import '../../core/interaction/drag_session.dart';
import '../../core/interaction/timeline_math.dart';
import '../../core/state/task_state.dart';
import '../../core/theme/app_theme.dart';

/// Drop zone for a week/month day cell. Registers itself by global rect
/// (initState/dispose — PageView page flips keep the registry correct for free).
///
/// The cell splits at the SCHEDULED│TO-SCHEDULE divider the cell already draws
/// between timed and untimed tasks: hover ABOVE it = keep the time, BELOW = drop
/// the time. The wash never draws its own line when that divider exists (it owns
/// [dividerKey]); it just stops short of it on both sides.
class DayCellDropTarget extends StatefulWidget {
  /// The stand-in split line, drawn only when the cell has no divider of its
  /// own. Keyed so a test can prove the line sits ON the hit boundary — the two
  /// used to be computed separately and disagreed by ~40-50px.
  static const splitLineKey = Key('cell-split-line');

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

  /// The cell's own divider box, when it draws one (only when BOTH groups are
  /// present). null → this cell has no divider and the wash must stand one in.
  RenderBox? get _dividerBox {
    final box = _dividerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box;
  }

  /// Global Y of the split — THE one source of truth. The hit-test reads it and
  /// the wash derives its line from it, so the line you see is always the line
  /// that decides. (They used to be computed apart: the hit-test from
  /// settleTopOffset, the line at a flat 50% of the padded box — ~40-50px of
  /// daylight between the boundary and its own picture.)
  double _splitGlobalY(Rect r) {
    final box = _dividerBox;
    if (box != null) {
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
    final overTop = r == null ? false : globalPos.dy < _splitGlobalY(r);
    if (overTop) return _isSameDay(p) ? 'reject' : 'keep';
    return 'clear';
  }

  /// Names the OUTCOME, never the mechanic. 'whole' gets none on purpose —
  /// there is no choice to explain, so narrating it would be noise.
  static String? _badgeFor(String mode, DragPayload p) => switch (mode) {
        'keep' => TimelineMath.fmtTime(p.task.startTime!),
        'clear' => 'No time',
        'reject' => 'Already here',
        _ => null,
      };

  @override
  DropHover? hoverAt(Offset globalPos, DragPayload p) {
    final mode = _modeFor(globalPos, p);
    return DropHover(
      zoneId: id,
      targetDay: widget.date,
      cellMode: mode,
      badgeText: _badgeFor(mode, p),
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

  /// The split in the wash's own (padded) coordinate space — the SAME Y the
  /// hit-test splits on, just moved into the coords the wash paints in. Derived
  /// from [_splitGlobalY], never recomputed, so the two cannot drift.
  double? _splitLocalY() {
    final cellBox = context.findRenderObject() as RenderBox?;
    if (cellBox == null || !cellBox.attached || !cellBox.hasSize) return null;
    final r = cellBox.localToGlobal(Offset.zero) & cellBox.size;
    final dy = _splitGlobalY(r);
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
                  // Read the live Y in the BUILD phase — localToGlobal inside
                  // LayoutBuilder runs during layout and throws.
                  final local = _splitLocalY();
                  final whole = mode == 'whole';
                  // 'whole' = one continuous wash (no split, no gaps, no line).
                  final gap = whole ? 0.0 : _gap;
                  // Keyed on the DIVIDER, not on a null Y: the fallback split is
                  // a real Y too, and it is exactly the one that must be drawn.
                  final drawLine = _dividerBox == null && !whole;
                  // Only the hovered zone lights; the other stays OFF. 'reject'
                  // lights faintly — a legal target that darkens reads as broken.
                  final topOp = (whole || mode == 'keep')
                      ? 1.0
                      : (mode == 'reject' ? 0.45 : 0.0);
                  final bottomOp = (whole || mode == 'clear') ? 1.0 : 0.0;
                  return LayoutBuilder(builder: (context, c) {
                    final lineH = drawLine ? 0.5 : 0.0;
                    final maxTop =
                        (c.maxHeight - gap * 2 - lineH).clamp(0.0, c.maxHeight);
                    final split =
                        (local ?? c.maxHeight * 0.5).clamp(0.0, c.maxHeight);
                    return Stack(
                      children: [
                        ClipRRect(
                          borderRadius: widget.highlightRadius,
                          // stretch: without it the Expanded wash below collapses
                          // to zero WIDTH (DecoratedBox has no child) and never
                          // shows.
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                height: (split - gap).clamp(0.0, maxTop),
                                child: _wash(topOp),
                              ),
                              SizedBox(height: gap),
                              // The cell already draws its divider — never
                              // duplicate it. Only stand one in when it has none.
                              if (drawLine)
                                AnimatedOpacity(
                                  key: DayCellDropTarget.splitLineKey,
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
                        ),
                        if (on && h?.badgeText != null)
                          _badge(h!.badgeText!, mode, split, c),
                      ],
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

  /// Sits just inside the half it describes, so the words and the wash name the
  /// same outcome. Same material as the ribbon's time badge — one drop, one
  /// language, whichever zone you are over.
  Widget _badge(String text, String mode, double split, BoxConstraints c) {
    const h = 18.0;
    final top = (mode == 'clear' ? split + 8 : split - 8 - h)
        .clamp(0.0, (c.maxHeight - h).clamp(0.0, c.maxHeight));
    return Positioned(
      left: 0,
      right: 0,
      top: top,
      child: Center(
        child: Container(
          height: h,
          padding: const EdgeInsets.symmetric(horizontal: 7),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.72),
            borderRadius: BorderRadius.circular(5),
            border:
                Border.all(color: Colors.white.withOpacity(0.14), width: 0.5),
          ),
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: AppFonts.robotoMono(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: Colors.white.withOpacity(0.92),
              letterSpacing: 0.3,
            ),
          ),
        ),
      ),
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
