import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../core/theme/app_theme.dart';
import '../../core/engine/slate_core_bridge.dart';
import '../../core/state/task_state.dart';
import '../../core/interaction/drag_session.dart';
import '../../core/interaction/peek_session.dart';
import '../widgets/hover_task_card.dart';

/// Slate — hover-peek popover.
/// One floating glass card at a time, driven by [PeekSession], rendered in
/// PulseLayer's ROOT Stack (mirror of DragPreviewLayer). It SPRINGS open from
/// its centre (same recipe as the Alt+Space capture overlay) and is INTERACTIVE
/// — the empty area around it passes clicks through, but the popover box itself
/// takes the pointer so you can check off / edit a task inside it.

class TaskPeekLayer extends StatefulWidget {
  const TaskPeekLayer({super.key});

  @override
  State<TaskPeekLayer> createState() => _TaskPeekLayerState();
}

class _TaskPeekLayerState extends State<TaskPeekLayer>
    with TickerProviderStateMixin {
  final PeekSession _session = PeekSession.instance;
  late final AnimationController _enter; // spring 0→1 (overshoot to 1.2)
  late final AnimationController _exit; // 0→1 shrink+fade
  PeekRequest? _shown;
  bool _leaving = false;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(vsync: this, lowerBound: 0.0, upperBound: 1.2);
    _exit = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 110));
    _session.addListener(_onSession);
    // A drag owns the pointer — any peek must clear the moment one starts.
    DragSession.instance.addListener(_onDrag);
  }

  void _onDrag() {
    if (DragSession.instance.isActive) _session.hideAll();
  }

  void _onSession() {
    final cur = _session.current;
    if (cur != null) {
      // New / replaced peek → spring in from centre (Apple input-reveal).
      _leaving = false;
      _exit.value = 0.0;
      setState(() => _shown = cur);
      _enter
        ..stop()
        ..value = 0.0
        ..animateWith(SpringSimulation(
          SpringDescription(
            mass: 1.0,
            stiffness: 420.0,
            damping: 2 * 0.86 * math.sqrt(420.0),
          ),
          0.0,
          1.0,
          0.0,
        ));
    } else if (_shown != null && !_leaving) {
      _leaving = true;
      _enter.stop();
      _exit
          .animateTo(1.0, curve: Curves.easeInCubic)
          .then((_) {
        if (mounted && _session.current == null) {
          setState(() {
            _shown = null;
            _leaving = false;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    DragSession.instance.removeListener(_onDrag);
    _enter.dispose();
    _exit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final req = _shown;
    if (req == null) return const SizedBox.shrink();
    return Positioned.fill(
      child: AnimatedBuilder(
        animation: Listenable.merge([_enter, _exit]),
        // Static subtree (never rebuilt per frame): the bridge + chrome + body.
        child: MouseRegion(
          onEnter: (_) => _session.keepAlive(),
          onExit: (_) => _session.scheduleClose(),
          child: _PeekChrome(child: req.builder(context)),
        ),
        builder: (context, child) {
          final t = _enter.value;
          final tc = t.clamp(0.0, 1.0);
          final ex = _exit.value;
          final moving = _enter.isAnimating || _exit.isAnimating;
          return CustomSingleChildLayout(
            delegate: _PeekLayoutDelegate(
                anchor: req.anchorRect, maxWidth: req.maxWidth),
            child: Transform.translate(
              offset: Offset(0, (1 - tc) * 8 + ex * 6),
              child: Transform(
                alignment: Alignment.center,
                transform: Matrix4.diagonal3Values(
                  (0.6 + 0.4 * t) * (1 - 0.05 * ex),
                  (0.85 + 0.15 * t) * (1 - 0.05 * ex),
                  1.0,
                ),
                // Text-hop rule: filterQuality non-null only while animating.
                filterQuality: moving ? FilterQuality.low : null,
                child: Opacity(
                  opacity:
                      ((tc / 0.3).clamp(0.0, 1.0) * (1.0 - ex)).clamp(0.0, 1.0),
                  child: child,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Placement: centre horizontally on the source, grow upward ────────────────
class _PeekLayoutDelegate extends SingleChildLayoutDelegate {
  final Rect anchor;
  final double maxWidth;
  static const double _pad = 10;
  static const double _gap = 8;

  _PeekLayoutDelegate({required this.anchor, required this.maxWidth});

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    final size = constraints.biggest;
    return BoxConstraints(
      maxWidth: maxWidth.clamp(0.0, size.width - _pad * 2),
      maxHeight: size.height - _pad * 2,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // Centre on the source horizontally; prefer above, drop below if no room.
    double x = anchor.center.dx - childSize.width / 2;
    double y = anchor.top - _gap - childSize.height;
    if (y < _pad) y = anchor.bottom + _gap;
    x = x.clamp(_pad, math.max(_pad, size.width - childSize.width - _pad));
    y = y.clamp(_pad, math.max(_pad, size.height - childSize.height - _pad));
    return Offset(x, y);
  }

  @override
  bool shouldRelayout(_PeekLayoutDelegate old) =>
      old.anchor != anchor || old.maxWidth != maxWidth;
}

// ── Glass frame ──────────────────────────────────────────────────────────────
class _PeekChrome extends StatelessWidget {
  final Widget child;
  const _PeekChrome({required this.child});

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: const Color(0xFF221D16),
        borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.45),
            blurRadius: 24,
            spreadRadius: -4,
            offset: const Offset(0, 10),
          ),
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: CustomPaint(
        foregroundPainter: GlassBorderPainter(
          radius: AppTheme.radiusLarge,
          colors: [
            Colors.white.withOpacity(0.16),
            Colors.white.withOpacity(0.03),
          ],
        ),
        child: child,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PEEK HOVER GATE — dwell on enter → publish; grace-close on exit (bridge)
// ═══════════════════════════════════════════════════════════════════════════

class PeekHoverGate extends StatefulWidget {
  final Widget child;
  final WidgetBuilder contentBuilder;
  final PeekKind kind;
  final double maxWidth;
  final Duration dwell;
  final bool Function()? canShow;

  const PeekHoverGate({
    super.key,
    required this.child,
    required this.contentBuilder,
    this.kind = PeekKind.cardTitle,
    this.maxWidth = 280,
    this.dwell = const Duration(milliseconds: 320),
    this.canShow,
  });

  @override
  State<PeekHoverGate> createState() => _PeekHoverGateState();
}

class _PeekHoverGateState extends State<PeekHoverGate> {
  Timer? _timer;

  void _onEnter(_) {
    PeekSession.instance.keepAlive(); // re-entering source cancels a pending close
    if (DragSession.hoverSuppressed) return;
    _timer?.cancel();
    _timer = Timer(widget.dwell, _fire);
  }

  void _onExit(_) {
    _timer?.cancel();
    _timer = null;
    // Grace so the cursor can bridge into the interactive popover.
    PeekSession.instance.scheduleClose();
  }

  void _fire() {
    if (!mounted || DragSession.hoverSuppressed) return;
    if (widget.canShow != null && !widget.canShow!()) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final rect = box.localToGlobal(Offset.zero) & box.size;
    PeekSession.instance.show(PeekRequest(
      owner: this,
      anchorRect: rect,
      kind: widget.kind,
      maxWidth: widget.maxWidth,
      builder: widget.contentBuilder,
    ));
  }

  @override
  void dispose() {
    _timer?.cancel();
    PeekSession.instance.hide(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: _onEnter,
      onExit: _onExit,
      child: widget.child,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PEEK CONTENT — interactive bodies (reuse HoverTaskCard for real checkbox/edit)
// ═══════════════════════════════════════════════════════════════════════════

class PeekContent {
  /// Single-card peek: the full (wrapped) task, interactive.
  static Widget cardTitle(
    RustTask task, {
    VoidCallback? onToggle,
    VoidCallback? onDelete,
    ValueChanged<String>? onEditTitle,
  }) {
    return Padding(
      padding: const EdgeInsets.all(6),
      child: HoverTaskCard(
        task: task,
        fullTitle: true,
        enablePeek: false,
        onTap: onToggle,
        onDelete: onDelete,
        onEditTitle: onEditTitle,
      ),
    );
  }

  /// Read-only peek (timeline blocks): just the time + full title + tags, laid
  /// out neatly. Completing/deleting is done in the day list — the block peek is
  /// purely "let me read the whole thing".
  static Widget readOnly(RustTask task) {
    final tl = _timeLabel(task);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (tl != null) ...[
            Text(
              tl,
              style: AppFonts.robotoMono(
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                color: Colors.white.withOpacity(0.50),
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 5),
          ],
          Text(
            task.title,
            style: AppFonts.inter(
              fontSize: 12.5,
              fontWeight: FontWeight.w500,
              color: Colors.white.withOpacity(0.92),
              height: 1.32,
              letterSpacing: 0.1,
            ),
          ),
          if (task.tags.isNotEmpty) ...[
            const SizedBox(height: 7),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final tg in task.tags)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.tagColor.withOpacity(0.10),
                      borderRadius: BorderRadius.circular(100),
                      border: Border.all(
                        color: AppTheme.tagColor.withOpacity(0.22),
                        width: 0.5,
                      ),
                    ),
                    child: Text(
                      '#$tg',
                      style: AppFonts.inter(
                        fontSize: 9.5,
                        fontWeight: FontWeight.w500,
                        color: AppTheme.tagColor.withOpacity(0.80),
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// Always the full span — the peek exists to end the guessing. A block with no
  /// explicit end still occupies the hour the timeline draws for it, so spell it
  /// out; the compact bar keeps hiding that implicit end.
  static String? _timeLabel(RustTask t) {
    final s = t.startTime;
    if (s == null) return null;
    return '${_fmt(s)}–${_fmt(t.endTime ?? s + 60)}';
  }

  static String _fmt(int minutes) {
    final h = (minutes ~/ 60) % 24;
    final m = minutes % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// Month-cell peek: day header + the FULL, live task list (check off inline).
  static Widget monthDay(
    DateTime date,
    TaskState? taskState,
    List<RustTask> fallback,
  ) {
    Widget list(List<RustTask> tasks) {
      final unallocated = tasks.where((t) => t.startTime == null).toList();
      final allocated = tasks.where((t) => t.startTime != null).toList()
        ..sort((a, b) => (a.startTime ?? 0).compareTo(b.startTime ?? 0));
      final ordered = [...allocated, ...unallocated];
      final done = tasks.where((t) => t.isCompleted).length;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 8),
            child: Row(
              children: [
                Text(
                  _dayHeader(date),
                  style: AppFonts.interTight(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withOpacity(0.85),
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(width: 8),
                if (tasks.isNotEmpty)
                  Text(
                    '$done/${tasks.length}',
                    style: AppFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: Colors.white.withOpacity(0.32),
                    ),
                  ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final t in ordered)
                    HoverTaskCard(
                      task: t,
                      compact: true,
                      fullTitle: true,
                      enablePeek: false,
                      onTap: () => taskState?.toggleTask(t),
                      onDelete: () => taskState?.deleteTask(t),
                      onEditTitle: (v) =>
                          taskState?.updateTask(t.copyWith(title: v)),
                    ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 360),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
        child: taskState == null
            ? list(fallback)
            : ValueListenableBuilder<List<RustTask>>(
                valueListenable: taskState.tasksForDateNotifier(
                    DateTime(date.year, date.month, date.day)
                        .millisecondsSinceEpoch),
                builder: (context, tasks, _) => list(tasks),
              ),
      ),
    );
  }

  static String _dayHeader(DateTime d) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${wd[d.weekday - 1]}, ${mo[d.month - 1]} ${d.day}';
  }
}
