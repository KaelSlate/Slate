import 'dart:math' as math;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart'
    show RenderStack, BoxHitTestResult, BoxHitTestEntry;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import '../../core/theme/app_theme.dart';
import '../../core/engine/capture_destination.dart';
import '../../core/engine/quick_capture_controller.dart';
import '../../core/engine/slate_core_bridge.dart';
import '../../core/engine/spatial_zoom_engine.dart';
import '../../core/state/lesson_state.dart';
import '../../core/state/task_state.dart';
import '../../core/interaction/drag_session.dart';
import '../../core/interaction/timeline_math.dart';
import '../overlays/time_line_painter.dart';
import '../overlays/task_peek_layer.dart';
import '../widgets/hover_task_card.dart';
import '../widgets/drop_future.dart';
import '../widgets/drag_source.dart';
import '../widgets/desktop_scroll_wrapper.dart';
import '../widgets/quiet_progress_ring.dart';
import '../widgets/smart_day_input.dart';

/// Phase 3.0 — Unified Day View (Dual-Pane: Planning + 24-Hour Ribbon)
///
/// Single StaircaseLevel.day renders both panes simultaneously:
///   Left  (~35%): Vertical task list, progress bars, inline 'New Task' input.
///   Right (~65%): Continuous 24-hour horizontal timeline ribbon ("Flow").
///
/// Both panes are independent, scrollable, and share the same day header.

class DayFlowView extends StatefulWidget {
  final DateTime selectedDate;
  final SlateCore core;
  final ValueChanged<RustTask> onToggleTask;
  final TaskState? taskState;
  /// Phase 4: When this notifier's value increments, auto-open the add-task
  /// field immediately. Used by the 'C' global shortcut in PulseLayer.
  final ValueNotifier<int>? autoFocusAddNotifier;

  const DayFlowView({
    super.key,
    required this.selectedDate,
    required this.core,
    required this.onToggleTask,
    this.taskState,
    this.autoFocusAddNotifier,
  });

  @override
  State<DayFlowView> createState() => _DayFlowViewState();
}

class _DayFlowViewState extends State<DayFlowView>
    with SingleTickerProviderStateMixin {
  // ── Flow Ribbon state ──────────────────────────────────────────────────────
  // Center index: 2400 = selectedDate hour 0 (100 days in each direction)
  static const int _hourCenter = 2400;
  static const double _colWidth = 100.0;

  late _RibbonScrollController _flowScrollController;
  double _viewportWidth = 600; // Default, updated on first build
  bool _ribbonReady = false;

  late final ValueNotifier<DateTime> _ribbonDate;
  // NOT `late final`: didUpdateWidget reassigns this when selectedDate changes
  // without the State being recreated. A second write to a `late final` throws
  // LateInitializationError and crashes the day view.
  late DateTime _zeroDate;

  // ── Planning pane state ────────────────────────────────────────────────────
  bool _isAddingTask = false;
  late final FocusNode _addFocusNode;
  late final SmartInputNotifier _smartNotifier;

  // ── Drag & drop zones ──────────────────────────────────────────────────────
  final GlobalKey _ribbonKey = GlobalKey();
  final GlobalKey _planningPaneKey = GlobalKey();
  // The ANYTIME group head — a landing card flies to rest just below it.
  final GlobalKey _anytimeKey = GlobalKey();
  late final _TimelineRibbonZone _ribbonZone;
  late final _PlanningPaneZone _paneZone;

  // Edge auto-scroll while dragging over the ribbon.
  Ticker? _autoScrollTicker;
  Duration? _lastAutoScrollTick;
  double _autoScrollVelocity = 0;

  // ── Offset helpers ─────────────────────────────────────────────────────────
  //
  // The ribbon is a RULER, and a ruler never opens on half a number. Every
  // resting offset it is given is a whole number of hour columns, so the
  // viewport's left edge always falls on an hour line and the leading label is
  // always whole. It used to centre a MINUTE (now / the middle of the densest
  // task window / noon), which lands mid-column virtually every time — that is
  // why the hour at the left edge came out sliced through the digits.

  /// Scroll offset that puts absolute column [index] flush against the left
  /// edge. Always hour-aligned by construction.
  double _columnOffset(num index) =>
      (index * _colWidth).clamp(0.0, _hourCenter * 2 * _colWidth);

  /// Column index of a minute-of-day on the day [dayOffset] days from zeroDate.
  int _columnFor(int minuteOfDay, {int dayOffset = 0}) =>
      _hourCenter + dayOffset * 24 + (minuteOfDay ~/ 60);

  /// Where TODAY rests: the current hour is the SECOND column, so the hour just
  /// gone stays in view and the rest of the viewport is the day ahead.
  double _nowAnchorOffset() {
    final now = DateTime.now();
    final dayOffset =
        DateTime(now.year, now.month, now.day).difference(_zeroDate).inDays;
    return _columnOffset(
        _columnFor(now.hour * 60 + now.minute, dayOffset: dayOffset) - 1);
  }

  /// THE day-open rule. One function — entering a day, the DAY button and a
  /// date change all use it, so pressing DAY returns you to exactly the view
  /// the day opened with. Three cases, each an exact column:
  ///
  ///   today            → the current hour, one column in from the left
  ///   day with tasks   → the earliest scheduled hour, with an hour of lead-in
  ///   empty day        → 08:00 at the left edge
  ///
  /// Stable on purpose: the old "densest viewport-wide window" search re-aimed
  /// the whole view whenever ANY task on the day moved, so the same day never
  /// opened the same way twice.
  double _dayOpenOffset() {
    final now = DateTime.now();
    final sel = widget.selectedDate;
    final isToday =
        sel.year == now.year && sel.month == now.month && sel.day == now.day;
    if (isToday) return _nowAnchorOffset();

    final state = widget.taskState;
    final tasks = state
            ?.tasksForDateNotifier(_zeroDate.millisecondsSinceEpoch)
            .value
            .where((t) => t.isAllocated && t.startTime != null) ??
        const <RustTask>[];

    var earliest = -1;
    for (final t in tasks) {
      if (earliest < 0 || t.startTime! < earliest) earliest = t.startTime!;
    }
    // 08:00 is the civil start of a day — an empty day looks the same wherever
    // you meet it, instead of parking on an arbitrary noon.
    if (earliest < 0) return _columnOffset(_columnFor(8 * 60));
    return _columnOffset(_columnFor(earliest) - 1); // one hour of lead-in
  }

  @override
  void initState() {
    super.initState();
    _zeroDate = DateTime(
        widget.selectedDate.year, widget.selectedDate.month, widget.selectedDate.day);
    _ribbonDate = ValueNotifier<DateTime>(_zeroDate);
    _addFocusNode = FocusNode();
    _smartNotifier = SmartInputNotifier();

    // Provisional offset only; the ribbon ListView attaches after _ribbonReady,
    // by which point the post-frame below has set the exact day-open target.
    // Hour-aligned even here, so nothing can ever attach mid-column.
    _flowScrollController = _RibbonScrollController(initial: _dayOpenOffset());
    _flowScrollController.addListener(_onRibbonScroll);

    // Global 'C' shortcut: HardwareKeyboard raw handler — zero latency,
    // fires even when no text field has focus, guards against active input.
    HardwareKeyboard.instance.addHandler(_globalKeyHandler);

    // The chord raises the window pill; this shuts ours first so the two never
    // stack (it no-ops when we have none open).
    QuickCaptureController.instance.addInAppCloser(_closeAddTask);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _flowScrollController.pending = _dayOpenOffset();
      setState(() => _ribbonReady = true);
    });

    // Phase 4: Also respond to external autoFocus trigger (e.g. menu action)
    widget.autoFocusAddNotifier?.addListener(_onAutoFocusTrigger);

    _ribbonZone = _TimelineRibbonZone(this);
    _paneZone = _PlanningPaneZone(this);
    DragSession.instance.registry.register(_ribbonZone);
    DragSession.instance.registry.register(_paneZone);
    DragSession.instance.addListener(_onDragPhaseChanged);
    DragSession.instance.pointerGlobal.addListener(_onDragPointerMoved);
  }

  // ── Edge auto-scroll (drag near ribbon edges pans the timeline) ───────────

  /// The edge pan is the one thing allowed to leave the ribbon mid-column —
  /// it has to be smooth while a card is in the air. This remembers that it
  /// happened so the ribbon can be put back on the hour grid afterwards.
  bool _autoScrolledOffGrid = false;

  void _onDragPhaseChanged() {
    if (DragSession.instance.isActive) return;
    _stopAutoScroll();
    // Only once the session is fully IDLE: the preview settles onto a global
    // rect, so moving the ribbon while it is still flying would slide the
    // landing spot out from under it.
    if (DragSession.instance.phase == DragPhase.idle) _realignToHour();
  }

  /// Ease back onto the nearest hour line after an edge pan left the ribbon
  /// between columns.
  void _realignToHour() {
    if (!_autoScrolledOffGrid) return;
    _autoScrolledOffGrid = false;
    if (!_flowScrollController.hasClients) return;
    final offset = _flowScrollController.offset;
    final aligned = (offset / _colWidth).round() * _colWidth;
    if ((aligned - offset).abs() < 0.5) return;
    _glideTo(aligned, duration: const Duration(milliseconds: 260));
  }

  void _onDragPointerMoved() {
    if (!mounted || !DragSession.instance.isActive) return;
    final rect = _ribbonZone.globalRect();
    final p = DragSession.instance.pointerGlobal.value;
    if (rect == null || !rect.contains(p)) {
      _stopAutoScroll();
      return;
    }
    const band = 56.0;
    final leftDepth = (band - (p.dx - rect.left)).clamp(0.0, band);
    final rightDepth = (band - (rect.right - p.dx)).clamp(0.0, band);
    if (leftDepth > 0) {
      _autoScrollVelocity = -(300 + 900 * (leftDepth / band));
      _startAutoScroll();
    } else if (rightDepth > 0) {
      _autoScrollVelocity = 300 + 900 * (rightDepth / band);
      _startAutoScroll();
    } else {
      _stopAutoScroll();
    }
  }

  void _startAutoScroll() {
    _autoScrollTicker ??= createTicker(_autoScrollTick);
    if (!_autoScrollTicker!.isActive) {
      _lastAutoScrollTick = null;
      _autoScrollTicker!.start();
    }
  }

  void _autoScrollTick(Duration elapsed) {
    final last = _lastAutoScrollTick;
    _lastAutoScrollTick = elapsed;
    if (last == null || !_flowScrollController.hasClients) return;
    final dt = (elapsed - last).inMicroseconds / 1e6;
    final pos = _flowScrollController.position;
    final next = (_flowScrollController.offset + _autoScrollVelocity * dt)
        .clamp(0.0, pos.maxScrollExtent);
    _autoScrolledOffGrid = true;
    _flowScrollController.jumpTo(next);
    // _onRibbonScroll fires via the controller listener → hover refresh below
    // keeps the snapped ghost glued to the grid while the ribbon pans.
  }

  void _stopAutoScroll() {
    _autoScrollTicker?.stop();
    _lastAutoScrollTick = null;
  }

  /// Called when the 'C' shortcut fires. Opens the add-task inline field and
  /// requests keyboard focus immediately — no extra click required.
  void _openAddTask() {
    StaircaseState.isComposingTask = true;
    setState(() => _isAddingTask = true);
    // Post-frame: field is now in the tree, safe to request focus
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _addFocusNode.requestFocus();
    });
  }

  /// Single close path — keeps the global composing flag in sync so the
  /// pulse_layer key handlers stop treating the pill as modal.
  ///
  /// No-op when closed: it is also registered as the chord's in-app closer, and
  /// clearing isComposingTask blind would yank the flag out from under whatever
  /// OTHER pill is open.
  void _closeAddTask() {
    if (!_isAddingTask) return;
    StaircaseState.isComposingTask = false;
    _addFocusNode.unfocus();
    if (mounted) setState(() => _isAddingTask = false);
    _smartNotifier.clear();
  }

  void _onAutoFocusTrigger() => _openAddTask();

  /// Raw global keyboard handler — captures 'C' even when no widget has focus.
  /// Guards: skips when pill is already open, or when a text field is active.
  bool _globalKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // The welcome overlay owns all keys while it's up — let it dismiss first.
    if (StaircaseState.isWelcoming) return false;

    // Warmup veil is up — this instance may be the invisible warming copy.
    if (StaircaseState.isWarmingUp) return false;

    // Escape closes the pill — handled here (not inside it) so it works even
    // when the field momentarily loses focus, and is CONSUMED so it doesn't
    // fall through to the global "back to Week view" shortcut.
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (!_isAddingTask) return false;
      _closeAddTask();
      return true;
    }

    if (event.logicalKey != LogicalKeyboardKey.keyC) return false;
    if (_isAddingTask) return false;
    // If ANY text field has focus, don't intercept — let 'c' type normally.
    // primaryFocus.context.widget is the EditableText's INTERNAL Focus widget, not
    // the EditableText itself, so the old `widget is EditableText` check never
    // matched inline title-editing → typing 'c' wrongly opened the command pill
    // ("console"). Walk the focused context for EditableTextState — the canonical
    // "a text input is active" signal (same robust check pulse_layer uses).
    final primaryCtx = FocusManager.instance.primaryFocus?.context;
    if (primaryCtx != null &&
        primaryCtx.findAncestorStateOfType<EditableTextState>() != null) {
      return false;
    }
    LessonState.instance.learn(Lessons.captureKey.id);
    _openAddTask();
    return true; // consumed
  }

  @override
  void didUpdateWidget(DayFlowView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedDate != oldWidget.selectedDate) {
      _zeroDate = DateTime(widget.selectedDate.year, widget.selectedDate.month,
          widget.selectedDate.day);
      _ribbonDate.value = _zeroDate;

      if (_flowScrollController.hasClients) {
        _flowScrollController.jumpTo(_dayOpenOffset());
      }
    }
  }

  void _onRibbonScroll() {
    if (!_flowScrollController.hasClients) return;
    // Ribbon moved under a held card (wheel or auto-scroll) → re-snap the ghost.
    if (DragSession.instance.isActive) DragSession.instance.refreshHover();
    final centerOffset = _flowScrollController.offset + (_viewportWidth / 2);
    final absoluteIndex = (centerOffset / _colWidth).floor();
    final hourOffset = absoluteIndex - _hourCenter;
    final dayOffset = hourOffset < 0
        ? -(((-hourOffset - 1) ~/ 24) + 1)
        : hourOffset ~/ 24;
    final newDate = _zeroDate.add(Duration(days: dayOffset));
    if (newDate.day != _ribbonDate.value.day ||
        newDate.month != _ribbonDate.value.month ||
        newDate.year != _ribbonDate.value.year) {
      _ribbonDate.value = newDate;
    }
  }

  @override
  void dispose() {
    DragSession.instance.registry.unregister(_ribbonZone);
    DragSession.instance.registry.unregister(_paneZone);
    DragSession.instance.removeListener(_onDragPhaseChanged);
    DragSession.instance.pointerGlobal.removeListener(_onDragPointerMoved);
    _autoScrollTicker?.dispose();
    StaircaseState.isComposingTask = false;
    QuickCaptureController.instance.removeInAppCloser(_closeAddTask);
    HardwareKeyboard.instance.removeHandler(_globalKeyHandler);
    widget.autoFocusAddNotifier?.removeListener(_onAutoFocusTrigger);
    _flowScrollController.removeListener(_onRibbonScroll);
    _flowScrollController.dispose();
    _ribbonDate.dispose();
    _addFocusNode.dispose();
    _smartNotifier.dispose();
    super.dispose();
  }

  /// Ease to an hour-aligned offset. The ONE way anything moves the ribbon to
  /// rest — nothing else is allowed to leave it mid-column.
  void _glideTo(double offset,
      {Duration duration = const Duration(milliseconds: 600)}) {
    if (!_flowScrollController.hasClients) return;
    _flowScrollController.animateTo(
      offset.clamp(0.0, _flowScrollController.position.maxScrollExtent),
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  void _snapToCurrentHour() => _glideTo(_nowAnchorOffset());

  // ═══════════════════════════════════════════════════════════════════════════
  // BUILD — Dual-Pane Root
  // ═══════════════════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Column(
            children: [
              _buildDayHeader(),
              const SizedBox(height: 10),
            // ── Dual-Pane Row ──────────────────────────────────────────────────
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // LEFT: Planning pane (~35%) on a faint static glass slab.
                  // "Стекло панели": a flat translucent plane that holds the flat
                  // rows, giving glass depth WITHOUT a live BackdropFilter — a live
                  // blur here would sample empty under the zoom cross-fade's opacity
                  // and flash, the very artifact we're killing. Tint only → no flash.
                  Flexible(
                    flex: 35,
                    child: DecoratedBox(
                      key: _planningPaneKey,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white.withOpacity(0.020),
                            Colors.white.withOpacity(0.006),
                          ],
                        ),
                      ),
                      // No drop-wash layer: the pane shows the incoming card
                      // itself (DropFuture), it does not describe the outcome.
                      child: _buildPlanningPane(),
                    ),
                  ),
                  // Gradient Divider
                  Container(
                    width: 1,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.white.withOpacity(0.12),
                          Colors.white.withOpacity(0.12),
                          Colors.transparent,
                        ],
                        stops: const [0.0, 0.08, 0.92, 1.0],
                      ),
                    ),
                  ),
                  // RIGHT: Flow ribbon (~65%)
                  Flexible(
                    flex: 65,
                    child: _buildFlowPane(),
                  ),
                ],
              ),
            ),
          ],
        ),

        // ── Floating Liquid Glass Command Pill ─────────────────────────────
        if (_isAddingTask)
          Positioned.fill(
            child: GestureDetector(
              onTap: _closeAddTask,
              behavior: HitTestBehavior.opaque,
              child: Stack(
                children: [
                  // Whisper-thin scrim — focuses attention without blacking
                  // out the day, so the timeline stays visible THROUGH the
                  // glass pill (the whole point of transparent glass).
                  Container(color: Colors.black.withOpacity(0.10)),
                  // Command Pill — bottom center at 40px clearance
                  Positioned(
                    bottom: 40,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: SizedBox(
                        width: 600,
                        child: GestureDetector(
                          // Tapping anywhere on the pill re-focuses the field (and
                          // absorbs the tap so the scrim's outside-tap-to-dismiss
                          // doesn't fire). Fixes "the click area to refocus doesn't
                          // match the pill" (#8) — the whole pill is now the target.
                          onTap: () => _addFocusNode.requestFocus(),
                          child: MouseRegion(
                            // The whole pill is a text input → I-beam everywhere on
                            // it, not just over the glyphs. The padding edges used to
                            // flip back to the default arrow (#3). Outside the pill,
                            // the scrim keeps the default arrow (dismiss-on-click).
                            cursor: SystemMouseCursors.text,
                            child: SmartDayInputWidget(
                              core: widget.core,
                              focusNode: _addFocusNode,
                              notifier: _smartNotifier,
                              // Pinned to the day centered under the timeline. In
                              // targeted mode a typed date STAYS as title text (it
                              // never re-routes the task) while a typed time still
                              // schedules within the day — the chip shows the day.
                              targeted: true,
                              destinationLabel: (r) => resolveCapture(r, DateTime.now(),
                                      viewedDay: _ribbonDate.value)
                                  .label,
                              onSubmit: (cleanTitle, result) {
                                final dest = resolveCapture(result, DateTime.now(),
                                    viewedDay: _ribbonDate.value);
                                widget.taskState?.createCaptured(cleanTitle, result, dest);
                              },
                              onDismiss: _closeAddTask,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // SHARED DAY HEADER
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildDayHeader() {
    if (widget.taskState == null) return const SizedBox.shrink();

    // #D v2 — the glass chrome (gradient + blurred boxShadow + GlassBorderPainter)
    // is a SIBLING underlay in the Stack, not the PARENT of the content row. As a
    // parent it re-rasterised (the blur-16 shadow "tint blink") whenever a child
    // changed SIZE and relayouted the Row — e.g. the progress dots collapsing /
    // changing count on a day flip. RepaintBoundaries on the children cannot stop
    // a relayout from dirtying their parent's paint. As a Positioned.fill sibling
    // whose layer contains nothing dynamic, the chrome's raster physically cannot
    // change. The dots also sit in a FIXED-width slot so day flips never relayout
    // the Row at all.
    return RepaintBoundary(
      child: Container(
        margin: const EdgeInsets.fromLTRB(
            AppTheme.spacing24, 0, AppTheme.spacing24, 0),
        child: Stack(
          children: [
            // Chrome underlay — nothing inside ever changes.
            Positioned.fill(
              child: RepaintBoundary(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Colors.white.withOpacity(0.03),
                        Colors.white.withOpacity(0.01),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
                    boxShadow: [
                      BoxShadow(
                          color: Colors.black.withOpacity(0.3),
                          blurRadius: 16,
                          offset: const Offset(0, 4)),
                    ],
                  ),
                  child: CustomPaint(
                    foregroundPainter: GlassBorderPainter(
                      radius: AppTheme.radiusLarge,
                      colors: [
                        Colors.white.withOpacity(0.18),
                        Colors.white.withOpacity(0.02),
                      ],
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            // Content row — the non-positioned child sizes the Stack (and thus
            // the chrome underlay).
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  AppTheme.spacing24, 16, AppTheme.spacing24, 14),
              child: Row(
                children: [
                  // Date + relative label — own RB; only this rebuilds on day-change.
                  Expanded(
                    child: RepaintBoundary(
                      child: ValueListenableBuilder<DateTime>(
                        valueListenable: _ribbonDate,
                        builder: (context, currentRibbonDate, _) => Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _formatDate(currentRibbonDate),
                              style: AppTheme.displayMedium.copyWith(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 24,
                                  letterSpacing: -0.3),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _relativeDayLabel(currentRibbonDate),
                              style: AppTheme.bodyMedium
                                  .copyWith(color: Colors.white24, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 20),
                  // Quiet progress ring — own RB in a fixed-width slot, so a
                  // day flip can't relayout the Row. "n of m" only on hover.
                  SizedBox(
                    width: 110,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: RepaintBoundary(
                        child: ValueListenableBuilder<DateTime>(
                          valueListenable: _ribbonDate,
                          builder: (context, currentRibbonDate, _) =>
                              ValueListenableBuilder<List<RustTask>>(
                            valueListenable:
                                widget.taskState!.tasksForDateNotifier(
                                    currentRibbonDate.millisecondsSinceEpoch),
                            builder: (context, dayTasks, _) {
                              final completed =
                                  dayTasks.where((t) => t.isCompleted).length;
                              final total = dayTasks.length;
                              return QuietProgressRing(
                                  completed: completed,
                                  total: total,
                                  size: 16,
                                  revealLabel: true,
                                  labelOnLeft: true);
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  // NOW button — own RB so its per-scroll-frame repaint never
                  // touches the glass. Matches the WEEK/MONTH "Today" pill. (#H)
                  RepaintBoundary(
                    child: AnimatedBuilder(
                      animation: _flowScrollController,
                      builder: (context, child) {
                        bool isSnapped = false;
                        if (_flowScrollController.hasClients) {
                          // Against the SAME anchor the button flies to, within
                          // half a column — "you are already here" has to mean
                          // the place the button would take you.
                          isSnapped = (_flowScrollController.offset -
                                      _nowAnchorOffset())
                                  .abs() <
                              _colWidth / 2;
                        }

                        return AnimatedOpacity(
                          duration: const Duration(milliseconds: 250),
                          opacity: isSnapped ? 0.0 : 1.0,
                          child: IgnorePointer(
                            ignoring: isSnapped,
                            child: MouseRegion(
                              cursor: SystemMouseCursors.basic,
                              child: GestureDetector(
                                onTap: _snapToCurrentHour,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(20),
                                    color: Colors.white.withOpacity(0.04),
                                    border: Border.all(
                                      color: Colors.white.withOpacity(0.08),
                                      width: 0.5,
                                    ),
                                  ),
                                  child: Text('Now',
                                      style: TextStyle(
                                        fontFamily: 'Inter',
                                        fontSize: 11,
                                        fontWeight: FontWeight.w400,
                                        color: Colors.white.withOpacity(0.5),
                                      )),
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _relativeDayLabel(DateTime date) {
    final now = DateTime.now();
    final diff = DateTime(date.year, date.month, date.day)
        .difference(DateTime(now.year, now.month, now.day))
        .inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    if (diff == -1) return 'Yesterday';
    if (diff > 0) return 'In $diff days';
    return '${-diff} days ago';
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // LEFT PANE — Vertical Task Planning List
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildPlanningPane() {
    if (widget.taskState == null) return const SizedBox.shrink();

    return ValueListenableBuilder<DateTime>(
      valueListenable: _ribbonDate,
      builder: (context, currentRibbonDate, child) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Pane label
            Padding(
              // Top breathing room so 'TASKS' + the + / DAY controls don't sit
              // flush against the top edge of the pane (#G — nudged down).
              padding: const EdgeInsets.fromLTRB(AppTheme.spacing24, 22, 16, 8),
          child: Row(
            children: [
              Text('TASKS',
                  style: AppTheme.mono.copyWith(
                      color: Colors.white24, fontSize: 9, letterSpacing: 1.0)),
              const Spacer(),
              _HoverIconButton(
                icon: Icons.add_rounded,
                onTap: _openAddTask,
              ),
              const SizedBox(width: 8),
              // DAY returns you to the view the day OPENED with — same rule,
              // same function. It used to run a second, different policy, so
              // pressing it gave you a view you had never seen.
              _HoverDayButton(onTap: () => _glideTo(_dayOpenOffset())),
            ],
          ),
        ),
            // Task list
            Expanded(
              child: ValueListenableBuilder<List<RustTask>>(
                valueListenable: widget.taskState!.tasksForDateNotifier(
                    currentRibbonDate.millisecondsSinceEpoch),
                builder: (context, dayTasks, child) {
                  // RAW, unordered: the ghost and the landing card are appended
                  // first and the whole lot is ordered ONCE below, so a preview
                  // can never sit somewhere the drop won't put it.
                  final rawUnallocated =
                      dayTasks.where((t) => !t.isAllocated).toList();
                  final scheduled = dayTasks.where((t) => t.isAllocated).toList()
                    ..sort((a, b) => (a.startTime ?? 0).compareTo(b.startTime ?? 0));

              return ListenableBuilder(
                listenable: _smartNotifier,
                builder: (context, _) {
                  final ghostRes = _smartNotifier.result;
                  final hasGhostList = _isAddingTask && !ghostRes.hasTime && ghostRes.cleanTitle.isNotEmpty;

                  // Rebuild as a card enters/leaves the pane so the list can
                  // show what the drop is about to do.
                  return ValueListenableBuilder<DropHover?>(
                      valueListenable: DragSession.instance.hover,
                      builder: (context, hover, _) {
                  // Our zone only — the ribbon leaves cellMode null today, but
                  // gating on the id keeps the list honest if that changes.
                  final preview = hover?.zoneId == _PlanningPaneZone.zoneId
                      ? DropFuture.forDate(currentRibbonDate)
                      : null;
                  final pending = List<RustTask>.from(rawUnallocated);

                  if (hasGhostList) {
                    pending.add(RustTask(
                      id: 'ghost',
                      title: ghostRes.cleanTitle,
                      isCompleted: false,
                      createdAt: currentRibbonDate.millisecondsSinceEpoch,
                      priority: ghostRes.priority,
                      tags: ghostRes.tags,
                    ));
                  }

                  // Splice the incoming card in only when it isn't already in
                  // this group; otherwise the real (dimmed) card is the show.
                  final showPreview = preview != null &&
                      !pending.any((t) => t.id == preview.projected.id);
                  if (showPreview) pending.add(preview.projected);

                  // Ordered ONCE, over the real rows AND the pending ones, by
                  // the same function the list uses after the drop. Appending
                  // mirrors the store's append, so the spot the preview shows
                  // is the spot the drop commits — importance still wins, and a
                  // plain card lands BELOW a «!!» one instead of jumping there.
                  final displayUnallocated =
                      TaskState.orderUnallocated(pending);
                  // The hour being handed over, struck through on the group
                  // head. Same sentence the week's rail says.
                  final st = DragSession.instance.payload?.task.startTime;
                  final handOver =
                      showPreview && !preview.keepsTime && st != null
                          ? '${((st ~/ 60) % 24).toString().padLeft(2, '0')}'
                              ':${(st % 60).toString().padLeft(2, '0')}'
                          : null;

                  // #2 — Instant day swap (NO crossfade). The old AnimatedSwitcher
                  // faded the whole list out+in on EVERY day change while scrolling
                  // the timeline → an opacity dip that read as the top panel
                  // "blinking" (most visible on empty days, where "No tasks planned"
                  // pulsed). A paged calendar swaps days instantly — calmer, premium.
                  return Padding(
                      key: ValueKey('${currentRibbonDate.year}-${currentRibbonDate.month}-${currentRibbonDate.day}'),
                        padding: const EdgeInsets.only(left: AppTheme.spacing24, right: 6),
                        // Right padding INSIDE the list keeps the scroll thumb
                        // (drawn at the viewport edge) off the task cards.
                        child: ListView(
                          padding: const EdgeInsets.only(right: 10),
                          children: [
                            // ── "Scheduled" section — timed tasks live ON TOP,
                            // earliest first: the next thing is the first thing.
                            if (scheduled.isNotEmpty) ...[
                              _SectionLabel(label: 'SCHEDULED', count: scheduled.length),
                              const SizedBox(height: 4),
                              ...scheduled.asMap().entries.map((entry) {
                                final t = entry.value;
                                return DragSource(
                                  key: ValueKey(t.id),
                                  task: t,
                                  kind: DragSourceKind.planListCard,
                                  sourceDay: currentRibbonDate,
                                  sourceInsets: const EdgeInsets.only(bottom: 5),
                                  child: HoverTaskCard(
                                    task: t,
                                    // The list is where you READ the full task —
                                    // no hover peek, no "…" truncation.
                                    enablePeek: false,
                                    fullTitle: true,
                                    onTap: () => widget.onToggleTask(t),
                                    onDelete: () => widget.taskState?.deleteTask(t),
                                    onEditTitle: (val) =>
                                        widget.taskState?.updateTask(t.copyWith(title: val)),
                                    onLongPress: null,
                                  ),
                                );
                              }),
                            ],

                            // ── Divider — decoration now, not a boundary ──────────
                            if (scheduled.isNotEmpty && displayUnallocated.isNotEmpty)
                              const _ScheduleDivider(),

                            // ── "Anytime" section ─────────────────────────────────
                            // Not "TO SCHEDULE": that reads as unfinished debt.
                            // No hour is a resting state, not a chore pending.
                            if (displayUnallocated.isNotEmpty) ...[
                              _SectionLabel(
                                key: _anytimeKey,
                                label: 'ANYTIME',
                                count: displayUnallocated.length,
                                fromTime: handOver,
                              ),
                              const SizedBox(height: 4),
                              ...displayUnallocated.map((t) {
                                // The incoming card renders as itself — halo,
                                // no time. Its own widget, never a DragSource.
                                if (showPreview &&
                                    identical(t, preview.projected)) {
                                  return preview.card(
                                      margin: const EdgeInsets.only(bottom: 5));
                                }
                                return Opacity(
                                  key: ValueKey(t.id),
                                  opacity: t.id == 'ghost' ? 0.5 : 1.0,
                                  child: DragSource(
                                    task: t,
                                    kind: DragSourceKind.planListCard,
                                    sourceDay: currentRibbonDate,
                                    sourceInsets: const EdgeInsets.only(bottom: 5),
                                    enabled: t.id != 'ghost',
                                    child: HoverTaskCard(
                                      task: t,
                                      enablePeek: false,
                                      fullTitle: true,
                                      onTap: () => t.id == 'ghost' ? null : widget.onToggleTask(t),
                                      onDelete: () => t.id == 'ghost' ? null : widget.taskState?.deleteTask(t),
                                      onEditTitle: (val) => t.id == 'ghost' ? null : widget.taskState?.updateTask(t.copyWith(title: val)),
                                      onLongPress: null,
                                    ),
                                  ),
                                );
                              }),
                            ],

                            // ── Empty state ───────────────────────────────────────
                            // Never alongside a landing card — "No tasks planned"
                            // next to the card arriving is the pane contradicting
                            // itself.
                            if (dayTasks.isEmpty && !_isAddingTask && !showPreview)
                              _buildEmptyState(),

                            const SizedBox(height: 24),
                          ],
                        ),
                  );
                      });
              },
            );
          },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildEmptyState() => _buildCalmEmpty();

  Widget _buildCalmEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 40),
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.03),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withOpacity(0.07), width: 0.5),
            ),
            child: const Icon(Icons.inbox_outlined, size: 22, color: Colors.white12),
          ),
          const SizedBox(height: 14),
          Text(
            'No tasks planned',
            style: AppTheme.bodyMedium.copyWith(color: Colors.white24, fontSize: 12),
          ),
          // Only while the mechanic is still unlearned. Once you know C, an
          // empty day is just an empty day — room to breathe, not a prompt
          // repeating itself at you forever.
          if (!LessonState.instance.isLearned(Lessons.captureKey.id)) ...[
            const SizedBox(height: 8),
            RichText(
              textAlign: TextAlign.center,
              text: TextSpan(
                style: AppFonts.inter(
                  fontSize: 10,
                  color: Colors.white.withOpacity(0.18),
                ),
                children: [
                  const TextSpan(text: 'Press '),
                  TextSpan(
                    text: 'C',
                    style: AppFonts.inter(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: Colors.white.withOpacity(0.32),
                      letterSpacing: 0.5,
                    ),
                  ),
                  const TextSpan(text: ' to add a task'),
                ],
              ),
            ),
          ],
          const SizedBox(height: 40),
        ],
      ),
    );
  }


  // ═══════════════════════════════════════════════════════════════════════════
  // RIGHT PANE — 24-Hour Flow Ribbon
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildFlowPane() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Pane date label (FLOW badge removed)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, AppTheme.spacing24, 8),
          child: Row(
            children: [
              ValueListenableBuilder<DateTime>(
                valueListenable: _ribbonDate,
                builder: (context, date, _) => Text(
                  _formatDate(date),
                  style: AppTheme.mono.copyWith(
                      color: Colors.white.withOpacity(0.38),
                      fontSize: 10,
                      letterSpacing: 0.8),
                ),
              ),
            ],
          ),
        ),
        // Ribbon — LayoutBuilder wraps the skeleton too, so _viewportWidth is
        // measured on frame 1, before the day-open offset is computed.
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth > 0 &&
                  constraints.maxWidth != _viewportWidth) {
                _viewportWidth = constraints.maxWidth;
              }
              return _ribbonReady
                  ? _buildFlowRibbonInner()
                  : _buildRibbonSkeleton();
            },
          ),
        ),
      ],
    );
  }

  Widget _buildRibbonSkeleton() {
    return Container(color: const Color(0xFF0D0D0D));
  }

  // ═══════════════════════════════════════════════════════════════════════════
  // RIGHT PANE — 24-Hour Flow Ribbon with Temporal Block Layer
  // ═══════════════════════════════════════════════════════════════════════════

  Widget _buildFlowRibbonInner() {
    final now = DateTime.now();
    final currentHour = now.hour;
    final isToday = widget.selectedDate.day == now.day &&
        widget.selectedDate.month == now.month &&
        widget.selectedDate.year == now.year;

    return DesktopScrollWrapper(
      scrollController: _flowScrollController,
      // One notch, one hour. The ribbon comes to rest on an hour line every
      // time, so the leading label is never sliced and "scroll back to where it
      // was" is an exact, countable move.
      snapExtent: _colWidth,
      child: ClipRect(
        key: _ribbonKey,
        child: Stack(
          children: [
          ListView.builder(
            controller: _flowScrollController,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: _hourCenter * 2,
            itemExtent: _colWidth,
            itemBuilder: (context, index) {
              final hourOffset = index - _hourCenter;
              final displayHour = ((hourOffset % 24) + 24) % 24;
              final dayOffset = (hourOffset < 0)
                  ? -(((-hourOffset - 1) ~/ 24) + 1)
                  : hourOffset ~/ 24;
              final isCurrentHour =
                  isToday && dayOffset == 0 && displayHour == currentHour;
              final isMidnight = displayHour == 0;

              // P9: each hour column caches its own raster — neighbours (block
              // layer, laser overlay) can't dirty it during scroll.
              return RepaintBoundary(
                  child: Container(
                width: _colWidth,
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: isMidnight
                          ? Colors.white.withOpacity(0.12)
                          : Colors.white.withOpacity(0.04),
                      width: isMidnight ? 1.5 : 0.5,
                    ),
                  ),
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: CustomPaint(
                        painter: _HourColumnGridPainter(displayHour: displayHour),
                      ),
                    ),
                    // Hour label row (no task cards here — they live in _TimelineBlockLayer)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
                      child: Row(
                        children: [
                          if (isMidnight && dayOffset != 0) ...[
                            Text(
                              dayOffset > 0 ? '+${dayOffset}d ' : '${dayOffset}d ',
                              style: AppTheme.mono.copyWith(
                                  fontSize: 8,
                                  letterSpacing: 0.5,
                                  color: Colors.white.withOpacity(0.15)),
                            ),
                          ],
                          Text(
                            '${displayHour.toString().padLeft(2, '0')}:00',
                            style: AppTheme.mono.copyWith(
                                color: isCurrentHour
                                    ? Colors.white
                                    : Colors.white.withOpacity(0.2),
                                fontWeight: isCurrentHour
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                fontSize: 11),
                          ),
                          if (isCurrentHour) ...[
                            const SizedBox(width: 6),
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: [
                                  BoxShadow(
                                      color: Colors.white.withOpacity(0.4),
                                      blurRadius: 4),
                                ],
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ));
            },
          ),
          // ── Temporal Block Layer ── absolute-positioned task blocks ──────────
          // Reactively bound to the centered day: when the ribbon scrolls to a new
          // day, the block layer re-subscribes and renders THAT day's cards. Without
          // this listener the layer kept a stale day and cards vanished (#13).
          if (widget.taskState != null)
            ValueListenableBuilder<DateTime>(
              valueListenable: _ribbonDate,
              builder: (context, ribbonDate, _) => _TimelineBlockLayer(
                taskState: widget.taskState!,
                selectedDate: ribbonDate,
                zeroDate: _zeroDate,
                colWidth: _colWidth,
                hourCenter: _hourCenter,
                scrollController: _flowScrollController,
                onToggle: widget.onToggleTask,
                smartNotifier: _smartNotifier, // Phase 3: Ghost Task
              ),
            ),
          // ── Drag ghost ── snapped drop preview + floating time badge ────────
          _TimelineGhostLayer(scrollController: _flowScrollController),
          // Time laser overlay (on top of everything)
          Positioned.fill(
            child: IgnorePointer(
              child: TimeLineOverlay(
                zeroDate: _zeroDate,
                hourColumnWidth: _colWidth,
                scrollController: _flowScrollController,
                centerIndex: _hourCenter,
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    const weekdays = [
      'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'
    ];
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    return '${weekdays[date.weekday - 1]}, ${months[date.month - 1]} ${date.day}';
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// HOUR COLUMN GRID PAINTER
// ═══════════════════════════════════════════════════════════════════════════
// Mutable initial offset: the exact day-open target is computed post-frame
// (after viewport measurement) but before the ribbon ListView first attaches.
class _RibbonScrollController extends ScrollController {
  _RibbonScrollController({double initial = 0}) : pending = initial;
  double pending;
  @override
  double get initialScrollOffset => pending;
}

class _HourColumnGridPainter extends CustomPainter {
  final int displayHour;
  _HourColumnGridPainter({required this.displayHour});

  @override
  void paint(Canvas canvas, Size size) {
    final dotPaint = Paint()..color = Colors.white.withOpacity(0.06);
    for (int q = 1; q <= 3; q++) {
      final x = q * 25.0;
      for (double y = 16; y < size.height; y += 24) {
        canvas.drawRect(
            Rect.fromCenter(center: Offset(x, y), width: 2, height: 2), dotPaint);
      }
    }
    for (double y = 50; y < size.height; y += 50) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        Paint()
          ..color = Colors.white.withOpacity(0.03)
          ..strokeWidth = 0.5,
      );
    }
  }

  @override
  bool shouldRepaint(_HourColumnGridPainter old) => old.displayHour != displayHour;
}

// ═══════════════════════════════════════════════════════════════════════════
// SECTION LABEL — "SCHEDULED" / "ANYTIME"
// ═══════════════════════════════════════════════════════════════════════════

class _SectionLabel extends StatelessWidget {
  final String label;
  final int count;

  /// The hour a landing card is giving up, e.g. '14:30'. Struck through beside
  /// the group name: seeing the time sitting on the group about to take it is
  /// the whole explanation — no verb needed. Same sentence the week's rail says.
  final String? fromTime;

  const _SectionLabel({
    super.key,
    required this.label,
    required this.count,
    this.fromTime,
  });

  @override
  Widget build(BuildContext context) {
    final armed = fromTime != null;
    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 2),
      child: Row(
        children: [
          Text(
            label,
            style: AppFonts.inter(
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              color: Colors.white.withOpacity(armed ? 0.55 : 0.20),
            ),
          ),
          if (armed) ...[
            const SizedBox(width: 6),
            Text(
              fromTime!,
              maxLines: 1,
              style: AppFonts.robotoMono(
                fontSize: 8.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
                color: Colors.white.withValues(alpha: 0.40),
                decoration: TextDecoration.lineThrough,
                decorationColor: AppTheme.honey.withValues(alpha: 0.75),
                decorationThickness: 1.4,
              ),
            ),
          ],
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.06),
              borderRadius: BorderRadius.circular(100), // pill shape
            ),
            child: Text(
              '$count',
              style: AppFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color: Colors.white.withOpacity(0.28),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SCHEDULE DIVIDER
// ═══════════════════════════════════════════════════════════════════════════

class _ScheduleDivider extends StatelessWidget {
  const _ScheduleDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 0.5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Colors.white.withValues(alpha: 0.08),
                    Colors.white.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.15, 0.85, 1.0],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Text(
              '◇',
              style: AppFonts.inter(
                fontSize: 8,
                color: Colors.white.withValues(alpha: 0.12),
              ),
            ),
          ),
          Expanded(
            child: Container(
              height: 0.5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Colors.white.withValues(alpha: 0.08),
                    Colors.white.withValues(alpha: 0.08),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.15, 0.85, 1.0],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PREMIUM TIMELINE TASK CARD
// ═══════════════════════════════════════════════════════════════════════════

class _PremiumTimelineTaskCard extends StatefulWidget {
  final RustTask task;
  final int index;
  final VoidCallback onToggle;

  const _PremiumTimelineTaskCard({
    required this.task,
    required this.index,
    required this.onToggle,
  });

  @override
  State<_PremiumTimelineTaskCard> createState() => _PremiumTimelineTaskCardState();
}

class _PremiumTimelineTaskCardState extends State<_PremiumTimelineTaskCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.task;
    final isDone = t.isCompleted;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onToggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutQuart,
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          transform: Matrix4.identity()..translate(0.0, _hovered && !isDone ? -1.0 : 0.0),
          decoration: BoxDecoration(
            color: isDone
                ? Colors.white.withValues(alpha: 0.02)
                : (_hovered
                    ? Colors.white.withValues(alpha: 0.06)
                    : Colors.white.withValues(alpha: 0.04)),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isDone
                  ? Colors.transparent
                  : (_hovered
                      ? AppTheme.electricBlue.withValues(alpha: 0.3)
                      : Colors.white.withValues(alpha: 0.08)),
              width: 0.5,
            ),
            boxShadow: _hovered && !isDone
                ? [
                    BoxShadow(
                      color: AppTheme.electricBlue.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 4),
                    )
                  ]
                : [],
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 2, right: 6),
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDone
                      ? Colors.white.withValues(alpha: 0.2)
                      : AppTheme.electricBlue.withValues(alpha: 0.8),
                ),
              ),
              Expanded(
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 200),
                  opacity: isDone ? 0.3 : 1.0,
                  child: Text(
                    t.title,
                    style: AppFonts.inter(
                      fontSize: 10,
                      fontWeight: isDone ? FontWeight.w400 : FontWeight.w500,
                      color: isDone ? Colors.white.withValues(alpha: 0.5) : Colors.white,
                      decoration: isDone ? TextDecoration.lineThrough : null,
                      height: 1.2,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// TIMELINE BLOCK LAYER — Absolute-positioned task blocks over the scroll area
//
// Architecture: A plain Stack (via Flow render trick) laid over the ListView.
// On every scroll tick, AnimatedBuilder rebuilds only the Positioned wrappers
// (not the task cards themselves), so cost is O(visible_allocated_tasks).
//
// Positioning math:
//   left = (task.startTime / 60) * colWidth - scrollOffset + hourCenter*colWidth
//   width = clamp(duration/60 * colWidth, minW, colWidth * 23)
//   top/height: fill the ribbon area with 6px vertical padding
//
// Ready for drag-and-drop: each block gets a ValueKey(task.id).
// Future DragTarget wrappers can wrap the ListView's hour columns
// to receive drags and compute new startTime from x position.
// ═══════════════════════════════════════════════════════════════════════════

class _TimelineBlockLayer extends StatefulWidget {
  final TaskState taskState;
  final DateTime selectedDate;
  /// The day that `hourCenter` is anchored to (the day the view was entered on).
  /// Block X-geometry is measured from here, so when the ribbon is scrolled to a
  /// DIFFERENT day (e.g. via the NOW button) we must offset by the day delta —
  /// otherwise cards render on the entry day's columns and fly off-screen (#F).
  final DateTime zeroDate;
  final double colWidth;
  final int hourCenter;
  final ScrollController scrollController;
  final ValueChanged<RustTask> onToggle;
  final SmartInputNotifier? smartNotifier;

  const _TimelineBlockLayer({
    required this.taskState,
    required this.selectedDate,
    required this.zeroDate,
    required this.colWidth,
    required this.hourCenter,
    required this.scrollController,
    required this.onToggle,
    this.smartNotifier,
  });

  @override
  State<_TimelineBlockLayer> createState() => _TimelineBlockLayerState();
}

class _TimelineBlockLayerState extends State<_TimelineBlockLayer> {
  // #4 — Render a 3-day WINDOW (prev / center / next), not just the centered day.
  // The viewport is < 24h but straddles midnight, so it shows TWO days at once.
  // Subscribing only to the centered day made the adjacent day's edge tasks (e.g.
  // 23:00 of the previous day) vanish the instant the centered day flipped. We now
  // key each day's tasks by its whole-day offset from zeroDate and position every
  // block by ITS OWN day, so edge tasks stay put as you scroll across midnight.
  final Map<int, ValueNotifier<List<RustTask>>> _notifiers = {};
  final Map<int, List<RustTask>> _tasksByOffset = {};
  String? _expandedTaskId;

  // ── Live edge-resize preview (commit happens on release only) ────────────
  RustTask? _resizingTask;
  int _resizeStart = 0;
  int _resizeEnd = 0;

  void _setResizePreview(RustTask task, int startMin, int endMin) {
    if (_resizingTask?.id == task.id &&
        _resizeStart == startMin &&
        _resizeEnd == endMin) {
      return;
    }
    setState(() {
      _resizingTask ??= task;
      _resizeStart = startMin;
      _resizeEnd = endMin;
    });
  }

  void _endResizePreview(bool commit) {
    final t = _resizingTask;
    if (t == null) return;
    final s = _resizeStart;
    final e = _resizeEnd;
    setState(() => _resizingTask = null);
    if (commit && (s != t.startTime || e != t.endTime)) {
      widget.taskState.updateTask(t.copyWith(startTime: s, endTime: e));
    }
  }

  @override
  void initState() {
    super.initState();
    _subscribeWindow();
    widget.smartNotifier?.addListener(_onSmartInputChanged);
    // Hide the task whose preview is mid-drag/settle (no double-vision).
    DragSession.instance.hiddenTaskId.addListener(_onHiddenTaskChanged);
  }

  void _onHiddenTaskChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(_TimelineBlockLayer old) {
    super.didUpdateWidget(old);
    if (old.selectedDate != widget.selectedDate || old.zeroDate != widget.zeroDate) {
      _unsubscribeAll();
      _subscribeWindow();
    }
    if (old.smartNotifier != widget.smartNotifier) {
      old.smartNotifier?.removeListener(_onSmartInputChanged);
      widget.smartNotifier?.addListener(_onSmartInputChanged);
    }
  }

  void _onSmartInputChanged() {
    if (mounted) setState(() {});
  }

  /// Whole-day offset of [day] from zeroDate (the hourCenter anchor).
  int _offsetOf(DateTime day) {
    final zeroDay = DateTime(widget.zeroDate.year, widget.zeroDate.month, widget.zeroDate.day);
    final d = DateTime(day.year, day.month, day.day);
    return (d.difference(zeroDay).inHours / 24).round();
  }

  void _subscribeWindow() {
    _expandedTaskId = null;
    final center = DateTime(
        widget.selectedDate.year, widget.selectedDate.month, widget.selectedDate.day);
    for (int delta = -1; delta <= 1; delta++) {
      final day = DateTime(center.year, center.month, center.day + delta);
      final offset = _offsetOf(day);
      final notifier = widget.taskState.tasksForDateNotifier(day.millisecondsSinceEpoch);
      _notifiers[offset] = notifier;
      _tasksByOffset[offset] =
          notifier.value.where((t) => t.startTime != null).toList();
      notifier.addListener(_onTasksChanged);
    }
  }

  void _unsubscribeAll() {
    for (final n in _notifiers.values) {
      n.removeListener(_onTasksChanged);
    }
    _notifiers.clear();
    _tasksByOffset.clear();
  }

  void _onTasksChanged() {
    if (!mounted) return;
    setState(() {
      _notifiers.forEach((offset, n) {
        _tasksByOffset[offset] = n.value.where((t) => t.startTime != null).toList();
      });
    });
  }

  @override
  void dispose() {
    DragSession.instance.hiddenTaskId.removeListener(_onHiddenTaskChanged);
    _unsubscribeAll();
    widget.smartNotifier?.removeListener(_onSmartInputChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // We must rebuild if there are tasks (in any windowed day) OR a ghost task
    final hasGhost = widget.smartNotifier?.result.hasTime == true;
    final hasTasks = _tasksByOffset.values.any((l) => l.isNotEmpty);
    if (!hasTasks && !hasGhost) {
      // Publish the empty truth too — a stale span list from the last day would
      // have the ghost dodging blocks that are no longer on screen.
      TimelineLayout.spans = const [];
      return const SizedBox.shrink();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // Block geometry lives in TimelineMath — the drop ghost is laid out by
        // the same numbers, so it cannot promise a row this layer won't give.
        const double blockH = TimelineMath.blockH;
        const double rowGap = TimelineMath.rowGap;
        const double topPad = TimelineMath.topPad;

        // ── Compute pixel geometry for each task across the 3-day window ──
        // Each task is positioned by ITS OWN day's offset from zeroDate (#F/#4),
        // so cards land on the correct columns whether the ribbon was scrolled
        // (NOW button) or is straddling midnight between two days.
        final List<_BlockGeometry> geoms = [];
        final hiddenId = DragSession.instance.hiddenTaskId.value;
        _tasksByOffset.forEach((dayOffset, tasks) {
          for (final task in tasks) {
            if (task.id == hiddenId) continue;
            // Live resize: geometry AND label come from the preview values.
            final resizing = task.id == _resizingTask?.id;
            final effTask = resizing
                ? task.copyWith(startTime: _resizeStart, endTime: _resizeEnd)
                : task;
            final startMins    = effTask.startTime!;
            final durationMins = effTask.endTime != null
                ? (effTask.endTime! - startMins).clamp(15, 23 * 60)
                : 60;
            final colIndex       = (startMins / 60).floor() + widget.hourCenter + dayOffset * 24;
            final minuteFraction = (startMins % 60) / 60.0;
            final left  = (colIndex + minuteFraction) * widget.colWidth;
            // The width it OCCUPIES, min-clamp included — packing and pixels
            // must be the same number, or short blocks share a row and then
            // overlap on screen.
            final width = TimelineMath.blockWidth(durationMins);
            geoms.add(_BlockGeometry(task: effTask, left: left, width: width, isGhost: false));
          }
        });

        // Phase 3: Inject Ghost Task (lands on the centered day)
        if (hasGhost) {
          final centerOffset = _offsetOf(widget.selectedDate);
          final ghostRes = widget.smartNotifier!.result;
          final startMins = ghostRes.startTime!;
          final durationMins = ghostRes.endTime != null
              ? (ghostRes.endTime! - startMins).clamp(15, 23 * 60)
              : 60;
          final colIndex = (startMins / 60).floor() + widget.hourCenter + centerOffset * 24;
          final minuteFraction = (startMins % 60) / 60.0;
          final left = (colIndex + minuteFraction) * widget.colWidth;
          final width = TimelineMath.blockWidth(durationMins);

          final ghostTask = RustTask(
            id: 'ghost',
            title: ghostRes.cleanTitle.isEmpty ? 'New Task' : ghostRes.cleanTitle,
            isCompleted: false,
            createdAt: widget.selectedDate.millisecondsSinceEpoch,
            startTime: startMins,
            endTime: ghostRes.endTime,
            priority: ghostRes.priority,
            tags: ghostRes.tags,
          );
          
          geoms.add(_BlockGeometry(task: ghostTask, left: left, width: width, isGhost: true));
        }

        // Lane assignment via the SHARED greedy packer. Order is STABLE and
        // duration-independent (left, then id) — a resize can no longer flip the
        // sort and swap two rows. gap:0 → blocks that merely TOUCH in time (A ends
        // when B starts) share a row instead of B wasting a new lane. During an
        // active edge-resize EVERY block (incl. the resized one) is FROZEN on the
        // row it already holds (pref): a block only leaves its row when that row
        // genuinely collides, so a block on row 3 never teleports up to row 1 just
        // because a longer duration made it the earliest — that re-tidy is deferred
        // to a smooth settle on release. At rest all pack compact (pref=null: lone
        // block on top, freed rows close up, no floating gaps).
        geoms.sort((a, b) {
          final byLeft = a.left.compareTo(b.left);
          return byLeft != 0 ? byLeft : a.task.id.compareTo(b.task.id);
        });
        final freeze = _resizingTask != null;
        final spans = [
          for (final g in geoms)
            LaneSpan(g.left, g.width,
                id: g.task.id,
                pref: g.isGhost ? null : TimelineLayout.of(g.task.id))
        ];

        int? pinnedIndex;
        if (freeze) {
          final resizingId = _resizingTask!.id;
          final idx = geoms.indexWhere((g) => g.task.id == resizingId);
          if (idx != -1) pinnedIndex = idx;
        }
        final rowIndex = TimelineMath.assignLanes(spans, gap: 0, pinnedIndex: pinnedIndex);
        // Remember each row so the next resize freezes from this compact layout;
        // prune tasks outside the window (row is layout, not data).
        final laneIds = <String>{};
        for (var i = 0; i < geoms.length; i++) {
          if (geoms[i].isGhost) continue;
          TimelineLayout.set(geoms[i].task.id, rowIndex[i]);
          laneIds.add(geoms[i].task.id);
        }
        TimelineLayout.retain(laneIds);
        // PUBLISH the layout, rows and all. The drop ghost reads exactly this —
        // it no longer derives a second picture from TaskState, so it cannot
        // disagree with what is on screen. The typing ghost is left out: it is
        // not a task and a drop must not dodge it.
        TimelineLayout.spans = [
          for (var i = 0; i < geoms.length; i++)
            if (!geoms[i].isGhost)
              LaneSpan(geoms[i].left, geoms[i].width,
                  id: geoms[i].task.id, pref: rowIndex[i])
        ];

        // ── Build Positioned widgets ───────────────────────────────────
        final widgets = <Widget>[];
        Widget? expandedWidget;

        for (int i = 0; i < geoms.length; i++) {
          final g    = geoms[i];
          final isExpanded = _expandedTaskId == g.task.id;
          final top  = topPad + rowIndex[i] * (blockH + rowGap);

          // g.width already carries the min-block clamp (TimelineMath.blockWidth),
          // which is why the packer above saw the same pixels this paints.
          final targetWidth = isExpanded ? math.max(g.width, 260.0) : g.width;
          final targetHeight = isExpanded ? 72.0 : blockH;
          final targetTop = isExpanded ? top - (72.0 - blockH) / 2 : top;

          // AnimatedPositioned so a displaced block SLIDES to its new row
          // instead of being thrown. The resized block eases too (its row change
          // must glide, not snap) — because resize is 15-min-SNAPPED the width
          // steps also ease, reading as a magnetic snap; the un-dragged edge stays
          // put since left+width interpolate together. The typing ghost tracks
          // parser output 1:1 → zero duration.
          final w = AnimatedPositioned(
            key: ValueKey('pos_${g.task.id}'),
            duration: g.isGhost
                ? Duration.zero
                : (g.task.id == _resizingTask?.id
                    ? const Duration(milliseconds: 150)
                    : const Duration(milliseconds: 190)),
            curve: Curves.easeOutCubic,
            left:   g.left,
            top:    targetTop,
            width:  targetWidth,
            height: targetHeight,
            child: RepaintBoundary(
              // A block that hides something (clipped title OR no room for the
              // time badge) gets the same hover-peek as week/month — spring-open,
              // interactive. Wide blocks show both already → canShow false.
              child: PeekHoverGate(
                maxWidth: 300,
                canShow: () =>
                    !g.isGhost &&
                    !isExpanded &&
                    _TaskBlockState.needsPeek(g.task, targetWidth),
                // Read-only: neat text + time. Strike/delete stay in the list.
                contentBuilder: (_) => PeekContent.readOnly(g.task),
                child: _TaskBlock(
                key:   ValueKey(g.task.id),
                task:  g.task,
                width: targetWidth,
                absoluteLeft: g.left,
                scrollController: widget.scrollController,
                onToggle: null,
                isGhost: g.isGhost,
                isExpanded: isExpanded,
                onResizePreview: g.isGhost
                    ? null
                    : (s, e) => _setResizePreview(g.task, s, e),
                onResizeDone: g.isGhost ? null : _endResizePreview,
                onExpandToggled: () {
                  setState(() {
                    if (_expandedTaskId == g.task.id) {
                      _expandedTaskId = null;
                    } else {
                      _expandedTaskId = g.task.id;
                    }
                  });
                },
              ),
              ),
            ),
          );

          if (isExpanded) {
            expandedWidget = w;
          } else {
            widgets.add(w);
          }
        }

        if (expandedWidget != null) {
          widgets.add(expandedWidget);
        }

        // Floating live «12:00–15:00» badge above the resizing block.
        if (_resizingTask != null) {
          final t = _resizingTask!;
          final dayOffset =
              _offsetOf(DateTime.fromMillisecondsSinceEpoch(t.createdAt));
          final left = (widget.hourCenter + dayOffset * 24) * widget.colWidth +
              _resizeStart * widget.colWidth / 60.0;
          widgets.add(Positioned(
            left: left,
            top: topPad - 27,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.72),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: Colors.white.withOpacity(0.14),
                  width: 0.5,
                ),
              ),
              child: Text(
                '${TimelineMath.fmtTime(_resizeStart)}–${TimelineMath.fmtTime(_resizeEnd)}',
                style: AppFonts.robotoMono(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withOpacity(0.92),
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ));
        }

        // ClipRect MUST wrap the Transform, not the other way around. Cards are
        // Positioned at ABSOLUTE left (e.g. 16:00 → ~241600px from the hour-center
        // origin); the Transform.translate(-scrollOffset) brings the viewed day's
        // cards back near the origin. If ClipRect sits INSIDE the Transform it
        // clips the Stack in its pre-translate local space ([0, viewportWidth]) and
        // throws away every card at those huge left values — that's why timed cards
        // never appeared on the timeline (#4/#13). Clipping in the FINAL translated
        // space keeps the on-screen cards and trims only the off-screen ones.
        return ClipRect(
          child: AnimatedBuilder(
            animation: widget.scrollController,
            builder: (context, child) {
              final scrollOffset = widget.scrollController.hasClients
                  ? widget.scrollController.offset
                  : 0.0;
              return Transform.translate(
                offset: Offset(-scrollOffset, 0),
                child: child,
              );
            },
            // NOT a plain Stack: RenderBox.hitTest gates on size.contains()
            // BEFORE hitTestChildren, and these children sit at huge absolute
            // lefts (an ancestor translate brings them on-screen) — a plain
            // Stack silently swallowed every pointer, so blocks could never
            // be clicked, hovered, dragged or resized. Bounds-free hit test;
            // the ancestor ClipRect still confines it to the viewport.
            child: _UnboundedHitStack(children: widgets),
          ),
        );
      },
    );
  }
}

// Simple geometry record used during lane-assignment
class _BlockGeometry {
  final RustTask task;
  final double left;
  final double width;
  final bool isGhost;
  const _BlockGeometry({required this.task, required this.left, required this.width, this.isGhost = false});
}

/// Stack that hit-tests children even when the pointer is outside its own
/// bounds — required because block children live at absolute ribbon offsets
/// and are brought on-screen by an ancestor Transform.translate.
class _UnboundedHitStack extends Stack {
  const _UnboundedHitStack({super.children})
      : super(clipBehavior: Clip.none);

  @override
  RenderStack createRenderObject(BuildContext context) {
    return _RenderUnboundedHitStack(
      alignment: alignment,
      textDirection: textDirection ?? Directionality.maybeOf(context),
      fit: fit,
      clipBehavior: clipBehavior,
    );
  }
}

class _RenderUnboundedHitStack extends RenderStack {
  _RenderUnboundedHitStack({
    super.alignment,
    super.textDirection,
    super.fit,
    super.clipBehavior,
  });

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (hitTestChildren(result, position: position) ||
        hitTestSelf(position)) {
      result.add(BoxHitTestEntry(this, position));
      return true;
    }
    return false;
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// DRAG & DROP — day-view drop zones + snapped ghost
// Zones read _zeroDate/_ribbonDate/scrollOffset LIVE at hover/drop time (they
// all mutate under the zone), never at registration.
// ═══════════════════════════════════════════════════════════════════════════

/// The timeline's ONE live layout model.
///
/// The block layer publishes what it is holding — every block's span WITH its
/// sticky row — at the end of each build; everything else (the drop ghost, the
/// drop itself) reads it instead of deriving a second, slightly different
/// picture from TaskState. Sharing the input is what makes the ghost's promise
/// and the block's landing the same computation rather than two that agree most
/// of the time.
///
/// Row is layout, not data — never persisted, pruned to the visible window.
class TimelineLayout {
  static final Map<String, int> _prefs = {};

  /// Rows a drop has PROMISED but that no build has seen yet. The dropped task
  /// is hidden until its preview finishes settling, so it misses the builds in
  /// between — and a plain `retain` would prune the promise before it was ever
  /// used, dropping the block onto "first free row" instead of the row the
  /// ghost showed.
  static final Set<String> _reserved = {};

  /// Spans exactly as the block layer laid them out this frame.
  static List<LaneSpan> spans = const [];

  static int? of(String taskId) => _prefs[taskId];
  static void set(String taskId, int lane) => _prefs[taskId] = lane;

  /// Hold [lane] for [taskId] until a build actually places it there.
  static void reserve(String taskId, int lane) {
    _prefs[taskId] = lane;
    _reserved.add(taskId);
  }

  static void retain(Set<String> ids) {
    _reserved.removeAll(ids); // these arrived — the promise has been kept
    _prefs.removeWhere((k, _) => !ids.contains(k) && !_reserved.contains(k));
  }

  @visibleForTesting
  static void debugReset() {
    _prefs.clear();
    _reserved.clear();
    spans = const [];
  }
}

class _TimelineRibbonZone extends DropZone {
  static const String zoneId = 'ribbon';
  final _DayFlowViewState state;
  _TimelineRibbonZone(this.state);

  @override
  String get id => zoneId;

  @override
  int get priority => 20;

  @override
  String get landingChrome => 'block';

  RenderBox? get _box {
    final box =
        state._ribbonKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box;
  }

  @override
  Rect? globalRect() {
    final box = _box;
    return box == null ? null : box.localToGlobal(Offset.zero) & box.size;
  }

  /// Snapped continuous minutes from zeroDate midnight; grab-aware for blocks
  /// so the ghost starts pixel-identical to the lifted block.
  int? _snappedMinutes(Offset globalPos, DragPayload p) {
    final box = _box;
    if (box == null || !state._flowScrollController.hasClients) return null;
    var px = box.globalToLocal(globalPos).dx + state._flowScrollController.offset;
    if (p.kind == DragSourceKind.timelineBlock) px -= p.grabOffset.dx;
    return TimelineMath.snap(TimelineMath.pxToMinutes(px));
  }

  /// The blocks the ribbon is ACTUALLY holding — read straight off the layout
  /// the block layer published this frame, with the dragged task removed.
  ///
  /// It used to re-derive these from TaskState, and without each block's sticky
  /// `pref`. Since the packer processes by `pref` first, the two pictures could
  /// come out mirrored: the ghost then measured room on the wrong row, drew
  /// itself over a real block, and the drop landed a row away from where the
  /// preview had flown. Reading the published layout makes agreement structural.
  List<LaneSpan> _existingSpans(DragPayload p) {
    final hidden = DragSession.instance.hiddenTaskId.value;
    return [
      for (final s in TimelineLayout.spans)
        if (s.id != hidden && s.id != p.task.id) s
    ];
  }

  /// The row the cursor's height is asking for (the packer decides what it can
  /// honour). Measured at the block's MIDDLE, so pointing at a row means it.
  int _desiredLane(Offset globalPos) {
    final box = _box;
    if (box == null) return 0;
    final localY = box.globalToLocal(globalPos).dy;
    final lane = ((localY - TimelineMath.topPad - TimelineMath.blockH / 2) /
            (TimelineMath.blockH + TimelineMath.rowGap))
        .round();
    return lane < 0 ? 0 : lane;
  }

  /// Probe carrying the payload's real footprint. Same id as the task it will
  /// become, so the packer's id tie-break resolves identically before and after
  /// the drop.
  LaneSpan _probe(int snapped, DragPayload p, int desiredLane) => LaneSpan(
        TimelineMath.minutesToPx(snapped),
        TimelineMath.blockWidth(p.durationMinutes),
        id: p.task.id,
        pref: desiredLane,
      );

  /// Lane the drop will land on — the answer of the SAME packer, over the SAME
  /// spans, that the block layer will run a frame later. gap:0 mirrors the layer:
  /// blocks that merely touch in time share a row.
  int _placementLane(int snapped, Offset globalPos, DragPayload p) {
    final desired = _desiredLane(globalPos);
    return TimelineMath.laneForDrop(
        _existingSpans(p), _probe(snapped, p, desired));
  }

  double _ghostTop(int lane) => TimelineMath.laneTop(lane);

  @override
  DropHover? hoverAt(Offset globalPos, DragPayload p) {
    final snapped = _snappedMinutes(globalPos, p);
    if (snapped == null) return null;
    final split = TimelineMath.splitDay(snapped);
    return DropHover(
      zoneId: id,
      targetDay: TimelineMath.dayFromOffset(state._zeroDate, split.dayOffset),
      snappedMinutesFromZero: snapped,
      ghostTop: _ghostTop(_placementLane(snapped, globalPos, p)),
      badgeText: TimelineMath.fmtTime(split.minuteOfDay),
    );
  }

  @override
  DropResult? onDrop(Offset globalPos, DragPayload p) {
    final ts = state.widget.taskState;
    final snapped = _snappedMinutes(globalPos, p);
    if (ts == null || snapped == null) return null;
    final split = TimelineMath.splitDay(snapped);
    final day = TimelineMath.dayFromOffset(state._zeroDate, split.dayOffset);
    final desired = _desiredLane(globalPos);
    final lane =
        TimelineMath.laneForDrop(_existingSpans(p), _probe(snapped, p, desired));

    final s = p.task.startTime;
    final e = p.task.endTime;
    final int? endMin;
    if (s != null && e != null) {
      endMin = split.minuteOfDay + (e - s); // preserve duration
    } else if (s == null) {
      endMin = split.minuteOfDay + 60; // fresh schedule → parser's default
    } else {
      endMin = null; // open-ended stays open — don't materialize a duration
    }
    // Hand the layer the SAME pref the ghost was resolved with, BEFORE the
    // mutation — so its very first pack reproduces the exact assignment the
    // preview just showed and the block appears under the settled card instead
    // of dropping onto whatever row came first. Reserved, not merely set: the
    // task stays hidden until the settle ends, so it misses the builds in
    // between and a plain retain() would prune the promise before it was used.
    //
    // The RESOLVED row, not the cursor's raw wish: handing back the wish would
    // let the layer place this block ahead of the ones already sitting there
    // (placement is pref-ordered) and shove them aside — the very thing
    // laneForDrop refused to do.
    TimelineLayout.reserve(p.task.id, lane);
    ts.scheduleAt(p.task, day, split.minuteOfDay, endMin);

    final box = _box;
    if (box == null) return const DropResult(refineToCard: false);
    final localX =
        TimelineMath.minutesToPx(snapped) - state._flowScrollController.offset;
    final width = TimelineMath.blockWidth(p.durationMinutes);
    return DropResult(
      // Lane-honest landing: the preview settles into the EXACT slot the block
      // layer will place the task in (same lane pref) — deterministic geometry,
      // not a wrapped list card, so no card-rect refinement.
      refineToCard: false,
      settleGlobalRect: box.localToGlobal(Offset(localX, _ghostTop(lane))) &
          Size(width, TimelineMath.blockH),
    );
  }
}

class _PlanningPaneZone extends DropZone {
  static const String zoneId = 'planning-pane';
  final _DayFlowViewState state;
  _PlanningPaneZone(this.state);

  @override
  String get id => zoneId;

  @override
  int get priority => 10;

  @override
  String get landingChrome => 'card';

  @override
  Rect? globalRect() {
    final box = state._planningPaneKey.currentContext?.findRenderObject()
        as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  bool canAccept(DragPayload p) =>
      p.kind == DragSourceKind.inboxCard ||
      p.kind == DragSourceKind.timelineBlock ||
      p.kind == DragSourceKind.dayCellCard ||
      // A scheduled card can be unscheduled; an already-unscheduled one has
      // nothing to offer the pane → rejected (spring back).
      (p.kind == DragSourceKind.planListCard && p.task.startTime != null);

  /// 'whole' (inbox → this day) · 'clear' (timed → Anytime) · 'reject'.
  ///
  /// No region split. The ribbon owns "at an hour", the pane owns "without
  /// one", so a card dropped here has exactly ONE possible outcome — there is
  /// nothing to aim at. The old keep/clear halves made the whole pane body a
  /// target that did nothing, and hung the boundary on a divider that mounts
  /// only when both sections are filled: on a day of only-scheduled tasks the
  /// line silently fell to 40% of the pane with nothing on screen saying so.
  String _modeFor(DragPayload p) {
    if (p.kind == DragSourceKind.inboxCard) return 'whole';
    return p.task.startTime == null ? 'reject' : 'clear';
  }

  @override
  DropHover? hoverAt(Offset globalPos, DragPayload p) => DropHover(
        zoneId: id,
        targetDay: state._ribbonDate.value,
        // Always a mode: DropFuture.forDate bails on a null one, and without it
        // the pane could never show what it is about to do.
        cellMode: _modeFor(p),
      );

  @override
  DropResult? onDrop(Offset globalPos, DragPayload p) {
    final ts = state.widget.taskState;
    if (ts == null) return null;
    final day = state._ribbonDate.value;
    final mode = _modeFor(p);
    if (mode == 'reject') return null; // spring back
    if (mode == 'whole') {
      ts.assignToDay(p.task, day); // inbox → this day, no time
    } else {
      ts.unschedule(p.task, day); // clear time → «ANYTIME»
    }
    final r = globalRect();
    if (r == null) return const DropResult();
    return DropResult(
      settleGlobalRect: Rect.fromLTWH(
          r.left + AppTheme.spacing24, _settleTop(r), r.width - 40, 44),
    );
  }

  /// Rest on the group it just joined, so the flight ends on the row it became.
  double _settleTop(Rect r) {
    final box =
        state._anytimeKey.currentContext?.findRenderObject() as RenderBox?;
    final y = box != null && box.attached && box.hasSize
        ? box.localToGlobal(Offset.zero).dy + box.size.height + 4
        : r.top + 118;
    return y.clamp(r.top, r.bottom - 44);
  }
}

/// Snapped drop preview inside the ribbon: a slot block + floating time badge.
/// Lives INSIDE the ribbon's ClipRect and subtracts scrollOffset itself, so it
/// stays glued to the grid during wheel- and auto-scroll.
class _TimelineGhostLayer extends StatelessWidget {
  final ScrollController scrollController;
  const _TimelineGhostLayer({required this.scrollController});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: IgnorePointer(
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge(
                [DragSession.instance.hover, scrollController]),
            builder: (context, _) {
              final h = DragSession.instance.hover.value;
              final payload = DragSession.instance.payload;
              if (h == null ||
                  h.zoneId != _TimelineRibbonZone.zoneId ||
                  h.snappedMinutesFromZero == null ||
                  payload == null ||
                  !scrollController.hasClients) {
                return const SizedBox.shrink();
              }
              final left =
                  TimelineMath.minutesToPx(h.snappedMinutesFromZero!) -
                      scrollController.offset;
              final width = TimelineMath.blockWidth(payload.durationMinutes);
              final top = h.ghostTop ?? TimelineMath.topPad;
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: left,
                    top: top,
                    width: width,
                    height: TimelineMath.blockH,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.09),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.32),
                          width: 1,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: left,
                    top: top - 28,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withOpacity(0.72),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: Colors.white.withOpacity(0.14),
                          width: 0.5,
                        ),
                      ),
                      child: Text(
                        h.badgeText ?? '',
                        style: AppFonts.robotoMono(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withOpacity(0.92),
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════════
// SINGLE TASK BLOCK — Timeline horizontal card
//
// Design spec (Slate v3.1 «Etalon»):
//   Shape  : borderRadius 6px — business-precise, not playful, not corporate.
//   Height : 36px resting / 68px expanded.
//   Layout : [3px accent bar] [8px] [time mono] [·] [title inter] → ellipsis
//   Colors : accent fill @ 0.14 top / 0.05 bottom — glass tint, NOT paint.
//            Border: accent @ 0.25 (hairline, reads as edge, not frame).
//   Ghost  : electricBlue tint + dashed-style border for pending-create state.
//
// Drag & drop:
//   • LMB + 5px of travel lifts the block into the global DragSession; the
//     block layer hides the original via hiddenTaskId while the ribbon ghost
//     shows the snapped landing slot.
//   • Expand/collapse fires on pointer-UP-without-drag (was pointer-down),
//     so starting a drag never toggles expansion.
// ═══════════════════════════════════════════════════════════════════════════

class _TaskBlock extends StatefulWidget {
  final RustTask task;
  final double width;
  final double absoluteLeft;
  final ScrollController scrollController;
  final VoidCallback? onToggle;
  final bool isGhost;
  final bool isExpanded;
  final VoidCallback? onExpandToggled;
  /// Edge-resize: live snapped times while dragging an edge / gesture end.
  final void Function(int startMin, int endMin)? onResizePreview;
  final void Function(bool commit)? onResizeDone;

  const _TaskBlock({
    super.key,
    required this.task,
    required this.width,
    required this.absoluteLeft,
    required this.scrollController,
    this.onToggle,
    this.isGhost = false,
    this.isExpanded = false,
    this.onExpandToggled,
    this.onResizePreview,
    this.onResizeDone,
  });

  @override
  State<_TaskBlock> createState() => _TaskBlockState();
}

class _TaskBlockState extends State<_TaskBlock> {
  bool _hovered   = false;
  Offset? _downGlobal;
  int _downPointer = -1;

  // ── Edge resize (local gesture, not the global drag session) ─────────────
  static const double _kEdgeZone = 10.0;
  int _edgeHover = 0;  // -1 left edge, 1 right edge, 0 none (affordance)
  int _resizeEdge = 0; // active resize edge
  double _resizeDownDx = 0;
  int _resizeOrigStart = 0;
  int _resizeOrigEnd = 0;
  int _resizeCurStart = 0;
  int _resizeCurEnd = 0;

  bool get _resizable =>
      !widget.isGhost &&
      !widget.isExpanded &&
      widget.onResizePreview != null &&
      widget.width >= 24;

  int _edgeAt(Offset globalPos) {
    if (!_resizable) return 0;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return 0;
    final dx = box.globalToLocal(globalPos).dx;
    if (dx <= _kEdgeZone) return -1;
    if (dx >= box.size.width - _kEdgeZone) return 1;
    return 0;
  }

  void _endResize({required bool commit}) {
    if (_resizeEdge == 0) return;
    _resizeEdge = 0;
    StaircaseState.isResizingBlock = false;
    HardwareKeyboard.instance.removeHandler(_resizeEscHandler);
    widget.onResizeDone?.call(commit);
  }

  bool _resizeEscHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (_resizeEdge == 0) return false;
    _endResize(commit: false);
    return true;
  }

  // ── Adaptive bar content ─────────────────────────────────────────────────
  // Below 48px the bar is a pure colour chip (Google Calendar). Above it the
  // TITLE ranks above the time: the time badge appears only when the whole
  // title already fits beside it, and it never truncates itself. A fixed width
  // threshold used to let an 11-char «14:30–16:00» eat half a bar and shove the
  // title into an ellipsis — the answer to "what is this?" lost to "when".
  static const double _kThresholdTitleOnly = 48.0;
  static const double _kBarHPadding = 16.0;  // symmetric(horizontal: 8)
  static const double _kTimeGap     = 14.5;  // dot 2.5 + symmetric(horizontal: 6)

  @override
  void initState() {
    super.initState();
    _measureText();
  }

  @override
  void didUpdateWidget(_TaskBlock old) {
    super.didUpdateWidget(old);
    final a = old.task, b = widget.task;
    if (a.title != b.title ||
        a.priority != b.priority ||
        a.isCompleted != b.isCompleted ||
        a.startTime != b.startTime ||
        a.endTime != b.endTime) {
      _measureText();
    }
  }

  @override
  void dispose() {
    if (_resizeEdge != 0) {
      StaircaseState.isResizingBlock = false;
      HardwareKeyboard.instance.removeHandler(_resizeEscHandler);
    }
    super.dispose();
  }

  // Edge grip — the visual resize affordance (cursor stays basic: hard rule).
  // Both grips surface softly on ANY block hover (discoverability); the one
  // under the pointer / mid-resize brightens to full.
  Widget _edgeGrip(int edge, Color accent) {
    final hot =
        _resizeEdge == edge || (_resizeEdge == 0 && _edgeHover == edge);
    final visible = hot || (_resizeEdge == 0 && _hovered);
    return Positioned(
      left: edge < 0 ? 0 : null,
      right: edge > 0 ? 0 : null,
      top: 0,
      bottom: 0,
      child: IgnorePointer(
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 100),
          opacity: hot ? 1.0 : (visible ? 0.45 : 0.0),
          child: Container(
            width: 5,
            color: accent.withOpacity(0.30),
            alignment: Alignment.center,
            child: Container(
              width: 1.5,
              height: 14,
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.85),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Priority → accent color ───────────────────────────────────────────────
  Color get _accent {
    switch (widget.task.priority) {
      case 2:  return AppTheme.priorityCritical;
      case 1:  return AppTheme.priorityHigh;
      default: return AppTheme.priorityNormal;
    }
  }

  static String _fmt(int mins) {
    final h = (mins ~/ 60) % 24; // endTime > 1440 = past midnight
    final m = mins % 60;
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// Compact bar label: an implicit 1-hour end is left off — the block's right
  /// edge already lands on that gridline. The peek always spells the span out.
  static String timeLabelFor(RustTask t) {
    final s = t.startTime!;
    final e = t.endTime;
    if (e != null && e != s + 60) return '${_fmt(s)}–${_fmt(e)}';
    return _fmt(s);
  }

  String get _timeLabel => timeLabelFor(widget.task);

  // ── Text metrics ─────────────────────────────────────────────────────────
  // Measured ONCE per task, not per frame: _stickyWrap re-runs on every scroll
  // tick and the fit decision reads these on each of them.
  double _titleW = 0;
  double _timeW = 0;

  // ONE weight for every task — same rule the week/month cards already follow
  // (see HoverTaskCard). Priority speaks through the honey accent and the wider
  // accent bar; bolding the title too made `!!` shout in a timeline that should
  // read as one calm voice.
  static TextStyle titleStyleFor(RustTask t) => AppFonts.inter(
        fontSize: 12.5,
        fontWeight: t.isCompleted ? FontWeight.w400 : FontWeight.w500,
        letterSpacing: 0.05,
      );

  static TextStyle get timeStyle => AppFonts.robotoMono(
      fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.1);

  static double _textWidth(String s, TextStyle style) => (TextPainter(
        text: TextSpan(text: s, style: style),
        maxLines: 1,
        textDirection: TextDirection.ltr,
      )..layout())
      .width;

  void _measureText() {
    _titleW = _textWidth(widget.task.title, titleStyleFor(widget.task));
    _timeW = widget.task.startTime == null
        ? 0
        : _textWidth(timeLabelFor(widget.task), timeStyle);
  }

  static double _accentBarWidth(RustTask t) =>
      (!t.isCompleted && t.priority == 2) ? 4.0 : 3.0;

  /// Does the time badge fit *beside the whole title*? The title never yields a
  /// pixel to it; when the answer is no the time simply steps aside and the
  /// hover-peek becomes where the hour lives.
  static bool _timeFits(RustTask t, double width, double pin, double titleW,
          double timeW) =>
      t.startTime != null &&
      titleW + _kTimeGap + timeW <=
          width - _accentBarWidth(t) - _kBarHPadding - pin;

  /// Should hovering this block open a peek? Only when the bar cannot say it
  /// itself: no room for the title, the title dissolves mid-word, or the time
  /// stepped aside. A bar showing a whole title AND its hour stays quiet —
  /// popovers must remain rare. Measured with pin 0 (the resting geometry).
  static bool needsPeek(RustTask task, double width) {
    if (width < _kThresholdTitleOnly) return true;
    final titleW = _textWidth(task.title, titleStyleFor(task));
    final timeW = task.startTime == null
        ? 0.0
        : _textWidth(timeLabelFor(task), timeStyle);
    if (!_timeFits(task, width, 0, titleW, timeW)) return true;
    return titleW > width - _accentBarWidth(task) - _kBarHPadding;
  }

  // Sticky label: while the card is partially off the viewport's left edge, pad
  // the content right so it stays visible. Padding participates in layout, so
  // the Flexible title re-fits and can never overflow the card. The builder
  // receives the pin because it eats into the width the fit decision divides.
  Widget _stickyWrap({
    required EdgeInsets padding,
    required Widget Function(double pin) builder,
  }) {
    return AnimatedBuilder(
      animation: widget.scrollController,
      builder: (context, _) {
        final scrollOffset = widget.scrollController.hasClients
            ? widget.scrollController.offset
            : 0.0;
        final leftOffset = widget.absoluteLeft - scrollOffset;
        final contentW = math.max(0.0, widget.width - 3);
        final pin = (leftOffset < 0)
            ? (-leftOffset).clamp(0.0, math.max(0.0, contentW - 24.0)).toDouble()
            : 0.0;
        return Padding(
          padding: padding.copyWith(left: padding.left + pin),
          child: builder(pin),
        );
      },
    );
  }

  /// A clipped title DISSOLVES into the bar's fill instead of ending in "…" —
  /// the same language as the day/week/month cards. On a filled bar whose right
  /// edge is a gridline, three dots collide with the resize grip and read as
  /// debris; a fade reads as "the text continues under the edge", which is what
  /// the peek then shows.
  Widget _titleText(bool clipped) {
    final text = Text(
      widget.task.title,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
      style: titleStyleFor(widget.task).copyWith(
        color: widget.task.isCompleted
            ? Colors.white.withOpacity(0.30)
            : Colors.white.withOpacity(0.92),
        decoration:
            widget.task.isCompleted ? TextDecoration.lineThrough : null,
        decorationColor: Colors.white.withOpacity(0.30),
      ),
    );
    if (!clipped) return text;
    return ShaderMask(
      blendMode: BlendMode.dstIn,
      shaderCallback: (rect) {
        final start = rect.width <= 20 ? 0.0 : (rect.width - 18) / rect.width;
        return LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [Colors.white, Colors.white, Colors.transparent],
          stops: [0.0, start, 1.0],
        ).createShader(rect);
      },
      child: text,
    );
  }

  // ── Resting layout: filled bar (Apple Calendar) ───────────────────────────
  // Title + time as ONE left-aligned unit, vertically centred, sticky to the
  // LEFT edge of the visible slice (so the label stays readable as a wide block
  // scrolls past). The block's own fill is what occupies the width — it reads as
  // a solid coloured event bar, not dead space.
  Widget _buildRestingLayout(Color accent, bool isDone) {
    return _stickyWrap(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      builder: (pin) {
        if (widget.width < _kThresholdTitleOnly) return const SizedBox.shrink();
        final avail =
            widget.width - _accentBarWidth(widget.task) - _kBarHPadding - pin;
        final showTime =
            _timeFits(widget.task, widget.width, pin, _titleW, _timeW);
        // Only reachable when the time already stepped aside: if it fits, the
        // whole title fits beside it by definition.
        final clipped = !showTime && _titleW > avail;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(child: _titleText(clipped)),
            if (showTime) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Container(
                  width: 2.5,
                  height: 2.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone
                        ? Colors.white.withOpacity(0.15)
                        : accent.withOpacity(0.60),
                  ),
                ),
              ),
              Text(
                _timeLabel,
                style: timeStyle.copyWith(
                  color: isDone
                      ? Colors.white.withOpacity(0.28)
                      : Colors.white.withOpacity(0.55),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  // ── Expanded layout: tall card with time header + large title ────────────
  Widget _buildExpandedLayout(Color accent, bool isDone) {
    return _stickyWrap(
      padding: const EdgeInsets.fromLTRB(8, 9, 8, 9),
        builder: (_) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            // Top row: time + accent dot + tags
            Row(
              children: [
                Text(
                  _timeLabel,
                  style: AppFonts.robotoMono(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: isDone
                        ? Colors.white.withOpacity(0.22)
                        : Colors.white.withOpacity(0.50),
                    letterSpacing: 0.1,
                  ),
                ),
                const SizedBox(width: 5),
                Container(
                  width: 3,
                  height: 3,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone
                        ? Colors.white.withOpacity(0.18)
                        : accent.withOpacity(0.80),
                  ),
                ),
                if (widget.task.tags.isNotEmpty) ...[
                  const SizedBox(width: 7),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: Row(
                        children: widget.task.tags.map((t) => Container(
                          margin: const EdgeInsets.only(right: 4),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1.5),
                          decoration: BoxDecoration(
                            color: AppTheme.tagColor.withOpacity(0.08),
                            borderRadius: BorderRadius.circular(100),
                            border: Border.all(
                              color: AppTheme.tagColor.withOpacity(0.18),
                              width: 0.5,
                            ),
                          ),
                          child: Text(
                            '#$t',
                            style: AppFonts.inter(
                              fontSize: 8,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.tagColor.withOpacity(0.70),
                            ),
                          ),
                        )).toList(),
                      ),
                    ),
                  ),
                ],
              ],
            ),
            // Bottom: title
            Expanded(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Text(
                  widget.task.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: isDone
                        ? Colors.white.withOpacity(0.22)
                        : Colors.white.withOpacity(0.95),
                    decoration: isDone ? TextDecoration.lineThrough : null,
                    decorationColor: Colors.white.withOpacity(0.28),
                    height: 1.25,
                  ),
                ),
              ),
            ),
          ],
        ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    final isDone = widget.task.isCompleted;

    // ── Glassmorphic fill: very light tint, NOT paint ─────────────────────
    // Ghost uses electric blue pulse; real tasks use priority accent at 14%/5%.
    // This keeps the timeline background (grid, time laser) visible THROUGH cards.
    // Denser than before to compensate for the removed frosting blur: the card now
    // reads as a solid premium block with the grid only faintly behind it (legible
    // labels), instead of a sharp grid showing straight through a near-clear fill.
    // Denser fill so a wide block reads as a solid coloured EVENT BAR, not an
    // empty void with a floating label (Apple Calendar). Done tasks stay faint.
    final fillTop = widget.isGhost
        ? AppTheme.electricBlue.withOpacity(0.20)
        : accent.withOpacity(isDone ? 0.10 : 0.30);
    final fillBot = widget.isGhost
        ? AppTheme.electricBlue.withOpacity(0.07)
        : accent.withOpacity(isDone ? 0.05 : 0.15);

    // ── Border: subtle hairline — reads as shape edge, NOT decoration ─────
    final borderColor = widget.isGhost
        ? AppTheme.electricBlue.withOpacity(0.50)
        : (_hovered || widget.isExpanded
            ? accent.withOpacity(0.42)
            : accent.withOpacity(isDone ? 0.10 : 0.22));

    // ── Elevation: hover lifts card, expanded floats above timeline ───────
    final List<BoxShadow> shadows = widget.isGhost
        ? [
            BoxShadow(
              color: AppTheme.electricBlue.withOpacity(0.22),
              blurRadius: 14,
              spreadRadius: -3,
            ),
          ]
        : (widget.isExpanded
            ? [
                BoxShadow(
                  color: Colors.black.withOpacity(0.40),
                  blurRadius: 20,
                  offset: const Offset(0, 8),
                ),
                BoxShadow(
                  color: accent.withOpacity(0.18),
                  blurRadius: 12,
                  offset: const Offset(0, 2),
                ),
              ]
            : (_hovered && !isDone
                ? [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.22),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                    BoxShadow(
                      color: accent.withOpacity(0.12),
                      blurRadius: 8,
                      spreadRadius: -2,
                    ),
                  ]
                : [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.10),
                      blurRadius: 4,
                      offset: const Offset(0, 1),
                    ),
                  ]));

    final targetH = widget.isExpanded ? 68.0 : 36.0;

    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.buttons != 1) return;
        final edge = _edgeAt(event.position);
        if (edge != 0) {
          _resizeEdge = edge;
          _resizeDownDx = event.position.dx;
          _resizeOrigStart = widget.task.startTime!;
          _resizeOrigEnd = widget.task.endTime ?? (_resizeOrigStart + 60);
          _resizeCurStart = _resizeOrigStart;
          _resizeCurEnd = _resizeOrigEnd;
          StaircaseState.isResizingBlock = true;
          HardwareKeyboard.instance.addHandler(_resizeEscHandler);
          return;
        }
        _downGlobal = event.position;
        _downPointer = event.pointer;
      },
      onPointerMove: (event) {
        if (_resizeEdge != 0) {
          final deltaMin =
              (event.position.dx - _resizeDownDx) * 60.0 / TimelineMath.colWidth;
          var s = _resizeOrigStart;
          var e = _resizeOrigEnd;
          if (_resizeEdge < 0) {
            s = TimelineMath.snap(_resizeOrigStart + deltaMin)
                .clamp(0, e - TimelineMath.snapStep)
                .toInt();
          } else {
            // Right edge may cross midnight (end > 1440 = next day, matches
            // the render clamp of 23h max duration).
            e = TimelineMath.snap(_resizeOrigEnd + deltaMin)
                .clamp(s + TimelineMath.snapStep, s + 23 * 60)
                .toInt();
          }
          if (s != _resizeCurStart || e != _resizeCurEnd) {
            _resizeCurStart = s;
            _resizeCurEnd = e;
            widget.onResizePreview?.call(s, e);
          }
          return;
        }
        final down = _downGlobal;
        if (down == null || event.pointer != _downPointer) return;
        if (widget.isGhost) return;
        if (DragSession.instance.phase != DragPhase.idle) return;
        if ((event.position - down).distance < 5.0) return;
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.attached || !box.hasSize) return;
        _downGlobal = null;
        final rect = box.localToGlobal(Offset.zero) & box.size;
        DragSession.instance.begin(
          DragPayload(
            task: widget.task,
            kind: DragSourceKind.timelineBlock,
            sourceGlobalRect: rect,
            grabOffset: down - rect.topLeft,
            sourceDay:
                DateTime.fromMillisecondsSinceEpoch(widget.task.createdAt),
          ),
          event.position,
        );
      },
      onPointerUp: (event) {
        if (_resizeEdge != 0) {
          _endResize(commit: true);
          return;
        }
        // Tap no longer expands the block in place (that widened right = ugly).
        // The reveal is now the spring hover-peek (narrow blocks) / sticky title.
        _downGlobal = null;
      },
      onPointerCancel: (_) {
        _endResize(commit: false);
        _downGlobal = null;
      },
      child: MouseRegion(
        onEnter: (_) {
          // A drag owns the pointer — don't light this block or its grips as
          // the payload sweeps across it. Hover feedback is the static lift +
          // brighter border on the AnimatedContainer below (no moving sheen).
          if (DragSession.hoverSuppressed) return;
          setState(() => _hovered = true);
        },
        onHover: (event) {
          if (DragSession.hoverSuppressed) return;
          final z = _edgeAt(event.position);
          if (z != _edgeHover) setState(() => _edgeHover = z);
        },
        onExit: (_) => setState(() {
          _hovered = false;
          _edgeHover = 0;
        }),
        cursor: SystemMouseCursors.basic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutQuart,
          width:  widget.width,
          height: targetH,
          transform: Matrix4.identity()
            ..translate(0.0, _hovered && !isDone && !widget.isExpanded ? -1.5 : 0.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),  // ← Etalon: 6px
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [fillTop, fillBot],
            ),
            border: Border.all(color: borderColor, width: 0.75),
            boxShadow: shadows,
          ),
          // Flat translucent block — per-card live BackdropFilter removed: it
          // sampled an empty backdrop under the entrance fade ("light→dark/blur"
          // flash) and re-sampled on every reflow. The fillTop/fillBot gradient is
          // the surface now; container-level glass lives behind the timeline zone.
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
                clipBehavior: Clip.hardEdge,
                children: [
                  // ── Main row: accent bar + content ──────────────────────
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Priority accent bar — wider for !!
                      Container(
                        width: (!isDone && widget.task.priority == 2) ? 4 : 3,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: isDone
                                ? [
                                    Colors.white.withOpacity(0.08),
                                    Colors.white.withOpacity(0.04),
                                  ]
                                : [
                                    accent.withOpacity(0.95),
                                    accent.withOpacity(0.60),
                                  ],
                          ),
                        ),
                      ),
                      // Content area (sticky-scrollable)
                      Expanded(
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 180),
                          switchInCurve: Curves.easeOut,
                          switchOutCurve: Curves.easeIn,
                          child: KeyedSubtree(
                            key: ValueKey(widget.isExpanded),
                            child: widget.isExpanded
                                ? _buildExpandedLayout(accent, isDone)
                                : _buildRestingLayout(accent, isDone),
                          ),
                        ),
                      ),
                    ],
                  ),

                  // ── Resize grips (hover near an edge reveals them) ──────
                  if (_resizable) ...[
                    _edgeGrip(-1, accent),
                    _edgeGrip(1, accent),
                  ],
                ],
              ),
            ),
          ),
        ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// HOVER DAY BUTTON
// ═══════════════════════════════════════════════════════════════════════════

class _HoverDayButton extends StatefulWidget {
  final VoidCallback onTap;

  const _HoverDayButton({required this.onTap});

  @override
  State<_HoverDayButton> createState() => _HoverDayButtonState();
}

class _HoverDayButtonState extends State<_HoverDayButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.03),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: _hovered
                  ? Colors.white.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.06),
              width: 0.5,
            ),
          ),
          child: Text(
            'DAY',
            style: AppTheme.mono.copyWith(
              color: _hovered ? Colors.white.withValues(alpha: 0.5) : Colors.white24,
              fontSize: 8,
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverIconButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;

  const _HoverIconButton({required this.icon, required this.onTap});

  @override
  State<_HoverIconButton> createState() => _HoverIconButtonState();
}

class _HoverIconButtonState extends State<_HoverIconButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            color: _hovered
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.white.withValues(alpha: 0.02),
            shape: BoxShape.circle,
            border: Border.all(
              color: _hovered
                  ? Colors.white.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.04),
              width: 0.5,
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            widget.icon,
            size: 13,
            color: _hovered ? Colors.white.withValues(alpha: 0.6) : Colors.white24,
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// SEGMENTED PROGRESS DOTS — replaces LinearProgressIndicator
// ═══════════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════════
// WARMUP SAMPLE — paints the real _TaskBlock recipe once (gradient fill,
// accent bar, mono time run) so Skia compiles its shaders during the startup
// warmup even on an empty first install. Never touches the DB.
// ═══════════════════════════════════════════════════════════════════════════

class TaskBlockWarmupSample extends StatefulWidget {
  const TaskBlockWarmupSample({super.key});
  @override
  State<TaskBlockWarmupSample> createState() => _TaskBlockWarmupSampleState();
}

class _TaskBlockWarmupSampleState extends State<TaskBlockWarmupSample> {
  final ScrollController _ctrl = ScrollController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 220,
      height: 36,
      child: _TaskBlock(
        task: RustTask(
          id: 'warmup',
          title: 'Warm up',
          isCompleted: false,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          startTime: 600,
          endTime: 720,
          priority: 2,
          tags: const ['warm'],
        ),
        width: 220,
        absoluteLeft: 0,
        scrollController: _ctrl,
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// GLASS BORDER PAINTER
// ═══════════════════════════════════════════════════════════════════════════

class GlassBorderPainter extends CustomPainter {
  final double radius;
  final List<Color> colors;
  final List<double>? stops;
  final double strokeWidth;

  GlassBorderPainter({
    required this.radius,
    required this.colors,
    this.stops,
    this.strokeWidth = 0.8,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
        stops: stops,
      ).createShader(rect);

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(GlassBorderPainter oldDelegate) =>
      oldDelegate.radius != radius ||
      oldDelegate.strokeWidth != strokeWidth ||
      // Compare list CONTENTS, not identity. The colors list is rebuilt fresh on
      // every parent rebuild (e.g. a task toggle re-runs the whole day view via the
      // riverpod Consumer), so identity `!=` was ALWAYS true → the date-card border
      // re-rasterised on every toggle/day-change and its anti-aliasing shifted = the
      // header's "tone shimmer / black↔grey flicker". listEquals → repaint only on a
      // real colour change.
      !listEquals(oldDelegate.colors, colors) ||
      !listEquals(oldDelegate.stops, stops);
}
