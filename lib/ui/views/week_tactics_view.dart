import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../../core/theme/app_theme.dart';
import '../../core/engine/slate_core_bridge.dart';
import '../../core/engine/spatial_zoom_engine.dart';
import '../../core/state/task_state.dart';
import '../../core/interaction/drag_session.dart';
import '../../core/interaction/delete_settle.dart';
import '../widgets/hover_task_card.dart';
import '../widgets/drag_source.dart';
import '../widgets/drop_future.dart';
import '../widgets/day_cell_drop_target.dart';
import '../widgets/desktop_scroll_wrapper.dart';
import '../widgets/quiet_progress_ring.dart';

/// Slate — Week Tactics View (Phase 12 — Performance Polish)
/// Magnetic snap scroll. Film grain. Edge highlights.
/// Each _DayColumn is an isolated StatefulWidget + RepaintBoundary for 120fps.
/// (Old _WeekSnapPhysics removed — the PageView runs NeverScrollableScrollPhysics
/// and DesktopScrollWrapper owns all wheel-driven paging.)

// ─────────────────────────────────────────────────────────────────────────────
// WEEK TACTICS VIEW
// ─────────────────────────────────────────────────────────────────────────────
class WeekTacticsView extends StatefulWidget {
  final SlateCore core;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<RustTask> onToggleTask;
  final ValueNotifier<DateTime?>? jumpToDateNotifier;
  final TaskState? taskState;
  /// Phase 4: Reports which date the mouse is over (null = empty space).
  final ValueChanged<DateTime?>? onDayHover;
  /// Mouse «+»: add a task to THIS day (opens the shell capture pill pinned to
  /// it). Separate from onDayTap (which zooms into the day).
  final ValueChanged<DateTime>? onDayAdd;

  const WeekTacticsView({
    super.key,
    required this.core,
    required this.onDayTap,
    required this.onToggleTask,
    this.jumpToDateNotifier,
    this.taskState,
    this.onDayHover,
    this.onDayAdd,
  });

  @override
  State<WeekTacticsView> createState() => WeekTacticsViewState();
}

class WeekTacticsViewState extends State<WeekTacticsView> {
  static const int _pageCenter = 500;
  late PageController _pageController;
  // ValueNotifier → page changes update ONLY the header label, never the PageView
  final ValueNotifier<int> _weekOffset = ValueNotifier(0);
  // Fix 3: GlobalKey to strictly bounds-check the Y-axis (Semantic Anchor Rule)
  final GlobalKey _ribbonKey = GlobalKey();

  /// Rule 1 & 2: Semantic Anchor & No Dead Zones Zoom.
  void selectHoveredDay(Offset globalPosition) {
    final RenderBox? ribbonBox = _ribbonKey.currentContext?.findRenderObject() as RenderBox?;
    if (ribbonBox == null) {
      StaircaseState.selectedDate = _today();
      return;
    }

    final localPos = ribbonBox.globalToLocal(globalPosition);

    // Rule 2: Semantic Anchor. If Y is outside the ribbon (in the header/nav), default to Today.
    if (localPos.dy < 0 || localPos.dy > ribbonBox.size.height) {
      StaircaseState.selectedDate = _today();
      return;
    }

    // Rule 1: Zero Dead Zones (X-Axis).
    const double kHorizPadding = 16.0; // AppTheme.spacing16
    final double columnAreaWidth = ribbonBox.size.width - (kHorizPadding * 2);
    
    // Map X to nearest column 0-6. Math naturally splits any "gaps" down the middle.
    final relativeX = localPos.dx - kHorizPadding;
    final columnWidth = columnAreaWidth / 7;
    int col = (relativeX / columnWidth).floor();
    
    // Clamp catches the extreme left/right margins extending to infinity.
    col = col.clamp(0, 6);

    // DST-safe date math
    final visibleMonday = _weekStartFor(_weekOffset.value);
    final hoveredDate = DateTime(
      visibleMonday.year,
      visibleMonday.month,
      visibleMonday.day + col,
    );
    StaircaseState.selectedDate = hoveredDate;
  }

  /// Returns today stripped to calendar midnight (no hours).
  DateTime _today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  @override
  void initState() {
    super.initState();
    // Shared anchor (#E): derive the visible week from StaircaseState.selectedDate
    // so WEEK & MONTH always agree. Every entry path funnels through the same
    // anchor — zoom-out from a day (selectedDate = that day), a MONTH→WEEK toggle
    // (selectedDate = the visible month), and app start (selectedDate = today) —
    // and plain week scroll keeps the anchor current via onPageChanged.
    final weekOffset = _weekOffsetForDate(StaircaseState.selectedDate);
    final initialPage = _pageCenter + weekOffset;

    _pageController = PageController(initialPage: initialPage);
    _weekOffset.value = weekOffset;
    // #E — normalise the shared anchor to THIS week ON ENTRY (not just on scroll),
    // so a WEEK→MONTH toggle without any scroll still lands on the right month.
    // This was the actual miss: onPageChanged only fires on scroll, so opening the
    // week and toggling straight to month used a stale selectedDate (e.g. a July
    // day from a prior visit) → month showed July while you're in the June week.
    StaircaseState.selectedDate = _anchorForWeek(weekOffset);
    widget.jumpToDateNotifier?.addListener(_onJumpToDate);
    DragSession.instance.addListener(_onDragPhaseDwell);
    DragSession.instance.pointerGlobal.addListener(_onDragPointerDwell);
  }

  // ── Edge-dwell page flip: hold a dragged card at the week's edge ~650ms →
  // the ribbon pages to the prev/next week (repeats while held). ────────────
  Timer? _dwellTimer;
  int _dwellArmed = 0;
  final ValueNotifier<int> _dwellGlow = ValueNotifier(0);

  void _onDragPhaseDwell() {
    if (!DragSession.instance.isActive) _cancelDwell();
  }

  void _onDragPointerDwell() {
    if (!mounted || !DragSession.instance.isActive) return;
    final ctx = _ribbonKey.currentContext ?? context;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) {
      _cancelDwell();
      return;
    }
    final local = box.globalToLocal(DragSession.instance.pointerGlobal.value);
    int dir = 0;
    if ((Offset.zero & box.size).contains(local)) {
      const band = 40.0;
      if (local.dx <= band) {
        dir = -1;
      } else if (local.dx >= box.size.width - band) {
        dir = 1;
      }
    }
    if (dir == _dwellArmed) return;
    _cancelDwell();
    if (dir == 0) return;
    _dwellArmed = dir;
    _dwellGlow.value = dir;
    _dwellTimer = Timer(const Duration(milliseconds: 650), () {
      if (!mounted || !DragSession.instance.isActive) {
        _cancelDwell();
        return;
      }
      _flipWeek(dir);
      _dwellArmed = 0; // pointer is static → re-arm for repeat flips
      _onDragPointerDwell();
    });
  }

  void _flipWeek(int dir) {
    if (!_pageController.hasClients) return;
    final target =
        (_pageController.page ?? _pageCenter.toDouble()).round() + dir;
    _pageController.animateToPage(
      target,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  void _cancelDwell() {
    _dwellTimer?.cancel();
    _dwellTimer = null;
    _dwellArmed = 0;
    if (_dwellGlow.value != 0) _dwellGlow.value = 0;
  }

  /// Whole-week offset from THIS week's Monday to the Monday of [date]'s week.
  /// UTC-based diff to stay DST-safe (mirrors [_onJumpToDate]).
  int _weekOffsetForDate(DateTime? date) {
    final d = date ?? _today();
    final todayMonday = _weekStartFor(0);
    final targetMonday =
        DateTime(d.year, d.month, d.day - (d.weekday - 1));
    final diffDays =
        targetMonday.toUtc().difference(todayMonday.toUtc()).inDays;
    return (diffDays / 7).round();
  }

  /// The anchor day for the visible week — drives which MONTH a toggle shows.
  /// If TODAY falls inside the visible week, anchor on today (so "I'm in this
  /// week" keeps my real month, e.g. today 30 Jun → June even though the week
  /// spills into July). Otherwise anchor on the week's Monday.
  DateTime _anchorForWeek(int offset) {
    final monday = _weekStartFor(offset);
    final today = _today();
    final diff = today.difference(monday).inHours ~/ 24;
    return (diff >= 0 && diff < 7) ? today : monday;
  }

  void _onJumpToDate() {
    final date = widget.jumpToDateNotifier?.value;
    if (date == null || !_pageController.hasClients) return;

    // Strip hours — use UTC midnight for diff calculation to avoid DST rounding
    final todayMonday = _weekStartFor(0);
    final targetDay = DateTime(date.year, date.month, date.day);
    // weekday: Mon=1, so subtract (weekday-1) days to reach that week's Monday
    final targetMonday = DateTime(
        targetDay.year, targetDay.month, targetDay.day - (targetDay.weekday - 1));

    // Compute exact week offset using UTC-based difference to eliminate DST drift
    final diffDays = targetMonday.toUtc()
        .difference(todayMonday.toUtc())
        .inDays;
    final weekOffset = (diffDays / 7).round();
    final targetPage = _pageCenter + weekOffset;

    _pageController.animateToPage(
      targetPage,
      duration: const Duration(milliseconds: 600),
      curve: Curves.easeOutQuart,
    );
  }

  @override
  void dispose() {
    DragSession.instance.removeListener(_onDragPhaseDwell);
    DragSession.instance.pointerGlobal.removeListener(_onDragPointerDwell);
    _dwellTimer?.cancel();
    _dwellGlow.dispose();
    widget.jumpToDateNotifier?.removeListener(_onJumpToDate);
    _pageController.dispose();
    _weekOffset.dispose();
    super.dispose();
  }

  /// Soft edge glow while a dragged card is armed over a dwell band.
  Widget _dwellGlowEdge(int dir) {
    return Positioned(
      left: dir < 0 ? 0 : null,
      right: dir > 0 ? 0 : null,
      top: 0,
      bottom: 0,
      width: 48,
      child: IgnorePointer(
        child: ValueListenableBuilder<int>(
          valueListenable: _dwellGlow,
          builder: (_, glow, __) => AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: glow == dir ? 1.0 : 0.0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: dir < 0 ? Alignment.centerLeft : Alignment.centerRight,
                  end: dir < 0 ? Alignment.centerRight : Alignment.centerLeft,
                  colors: [
                    Colors.white.withOpacity(0.07),
                    Colors.white.withOpacity(0.0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  // NOTE: build() itself NEVER calls setState during scrolling.
  // _weekOffset is ValueNotifier — only _buildHeader's ValueListenableBuilder
  // rebuilds when the page changes.
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        const SizedBox(height: 4),
        Expanded(
          key: _ribbonKey,
          child: _buildWeekRibbon()
        ),
      ],
    );
  }

  // ── LABEL HELPERS ──────────────────────────────────────────────
  // ── COMPUTED HELPERS — all read from _weekOffset.value, NOT setState
  String _weekLabelFor(int offset) {
    if (offset == 0) return 'This Week';
    if (offset > 0) return 'In $offset week${offset > 1 ? "s" : ""}';
    return '${-offset} week${offset < -1 ? "s" : ""} ago';
  }

  /// DST-safe week start calculation.
  /// Uses DateTime(y, m, d + offset*7) instead of .add(Duration) which
  /// can cross DST transitions and land on the wrong calendar day.
  DateTime _weekStartFor(int offset) {
    final now = DateTime.now();
    final todayMonday = DateTime(now.year, now.month, now.day - (now.weekday - 1));
    // Dart's DateTime(y, m, d + n) constructor handles month/year overflow correctly
    return DateTime(todayMonday.year, todayMonday.month, todayMonday.day + offset * 7);
  }

  String _dateRangeFor(int offset) {
    final start = _weekStartFor(offset);
    final end = start.add(const Duration(days: 6));
    const m = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    if (start.month == end.month) return '${m[start.month - 1]} ${start.day}–${end.day}';
    return '${m[start.month - 1]} ${start.day} – ${m[end.month - 1]} ${end.day}';
  }

  /// Total + completed task counts for the visible week in ONE pass.
  /// The header rebuilds on every task toggle, so the old two-method version did
  /// 14 FFI calls (each allocating a CTaskList); this does 7.
  (int, int) _weekCounts(DateTime ws) {
    int total = 0, done = 0;
    for (int d = 0; d < 7; d++) {
      final dayTasks =
          widget.core.tasksForDate(ws.add(Duration(days: d)).millisecondsSinceEpoch);
      total += dayTasks.length;
      done += dayTasks.where((t) => t.isCompleted).length;
    }
    return (total, done);
  }

  // ── HEADER — rebuilds ONLY on page change or a task mutation ──────────────
  // P4: mutationTick replaces the old "whole view rebuilds via the top Consumer"
  // path — the done/total counter stays live while the rest of the view is
  // untouched by a toggle.
  Widget _buildHeader() {
    return AnimatedBuilder(
      animation: Listenable.merge([
        _weekOffset,
        if (widget.taskState != null) widget.taskState!.mutationTick,
      ]),
      builder: (context, _) {
        final offset = _weekOffset.value;
        final weekStart = _weekStartFor(offset);
        final (weekCount, weekDone) = _weekCounts(weekStart);
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacing24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 200),
                    child: Text(
                      _weekLabelFor(offset),
                      key: ValueKey(offset),
                      style: AppTheme.headlineLarge.copyWith(
                          fontSize: 24, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(_dateRangeFor(offset), style: AppTheme.bodyMedium.copyWith(
                      color: Colors.grey[500], fontSize: 12)),
                  const SizedBox(width: 12),
                  // Quiet progress: the ring fills with what's done — no
                  // "4/13" reproach. Exact count appears only on hover.
                  QuietProgressRing(
                      completed: weekDone, total: weekCount,
                      size: 14, revealLabel: true),
                  const Spacer(),
                  Visibility(
                    visible: offset != 0,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: _buildPill('Today', onTap: () {
                      if (_pageController.hasClients) {
                        _pageController.animateToPage(
                          _pageCenter,
                          duration: const Duration(milliseconds: 600),
                          curve: Curves.easeOutQuart,
                        );
                      }
                    }),
                  ),
                  const SizedBox(width: 8),
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPill(String label, {required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            color: Colors.white.withOpacity(0.04),
            border: Border.all(color: Colors.white.withOpacity(0.08), width: 0.5),
          ),
          child: Text(label,
              style: TextStyle(
                fontFamily: 'Inter', fontSize: 11, fontWeight: FontWeight.w400,
                color: Colors.white.withOpacity(0.5),
              )),
        ),
      ),
    );
  }

  // ── WEEK RIBBON — Adaptive snap physics ─────────────────────────
  Widget _buildWeekRibbon() {
    return Stack(
      children: [
        DesktopScrollWrapper(
      pageController: _pageController,
      baseDurationMs: 400, // Ускорили для уверенного финиша без рывков
      child: PageView.builder(
        controller: _pageController,
        pageSnapping: true,
        physics: const NeverScrollableScrollPhysics(), // БЛОКИРУЕМ БАРЬЕРЫ НА 100%
        onPageChanged: (page) {
          _weekOffset.value = page - _pageCenter;
          // Keep the shared anchor on the visible week (#E) so a WEEK→MONTH toggle
          // lands on the right month, and the week restores on the way back.
          StaircaseState.selectedDate = _anchorForWeek(_weekOffset.value);
        },
        itemBuilder: (context, pageIndex) {
          final offset = pageIndex - _pageCenter;
          // DST-safe: use DateTime constructor, not DateTime.now().add(Duration)
          final now = DateTime.now();
          final baseDate = DateTime(now.year, now.month, now.day + offset * 7);
          // ffi_generate_week_cells already hydrates task_count/completed_count, and
          // each _DayColumn recomputes its own live count from its per-date notifier —
          // so the old Dart re-count loop here (7× tasksForDate FFI + CTaskList alloc
          // on every page build) was pure dead work. Dropped.
          final cells = widget.core.generateWeekCells(baseDate.millisecondsSinceEpoch);
          return RepaintBoundary( // Кэшируем всю неделю для максимального FPS при скролле
            child: _buildWeekPage(cells),
          );
        },
      ),
        ),
        _dwellGlowEdge(-1),
        _dwellGlowEdge(1),
      ],
    );
  }

  Widget _buildWeekPage(List<DayCell> cells) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerSignal: (event) {
        if (event is PointerScrollEvent) {
          GestureBinding.instance.pointerSignalResolver.register(event, (e) {});
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppTheme.spacing12),
        child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: cells.asMap().entries.map((e) {
          final cellDate = DateTime.fromMillisecondsSinceEpoch(e.value.dateTimestamp);
          return Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: RepaintBoundary(
                child: DayCellDropTarget(
                  date: cellDate,
                  taskState: widget.taskState,
                  settleTopOffset: 96,
                  settleHeight: 32,
                  // Match _HoverGlowBackground's visible frame exactly —
                  // margin + radius — so the wash never pokes past the card.
                  highlightInsets:
                      const EdgeInsets.symmetric(horizontal: 1, vertical: 6),
                  highlightRadius:
                      BorderRadius.circular(AppTheme.radiusXLarge),
                  builder: (dividerKey) => _DayColumn(
                  dividerKey: dividerKey,
                  cell: e.value,
                  index: e.key,
                  core: widget.core,
                  onDayTap: widget.onDayTap,
                  onToggleTask: widget.onToggleTask,
                  onDeleteTask: (t) => widget.taskState?.deleteTask(t),
                  // No per-column entrance: the parent depth-zoom (pulse_layer
                  // AnimatedSwitcher) is the SINGLE coherent entrance motion. A
                  // staggered fade here ran AFTER the zoom finished and read as a
                  // cheap "second phase" on every zoom-in/out into the week.
                  animateEntrance: false,
                  taskState: widget.taskState,
                  onHover: (hovered) {
                    widget.onDayHover?.call(hovered ? cellDate : null);
                  },
                  onDayAdd: widget.onDayAdd,
                ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
      ),
    );
  }
}


// ─────────────────────────────────────────────────────────────────────────────
// DAY COLUMN — StatefulWidget with LOCAL hover isolation (Phase 12 Fix A)
// ─────────────────────────────────────────────────────────────────────────────
class _DayColumn extends StatefulWidget {
  final DayCell cell;
  final int index;
  final SlateCore core;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<RustTask> onToggleTask;
  final ValueChanged<RustTask> onDeleteTask;
  final bool animateEntrance;
  final TaskState? taskState;
  /// Phase 4: Reports mouse enter/exit for hover-date tracking.
  final ValueChanged<bool>? onHover;
  /// Mouse «+»: add a task to this day (opens the shell capture pill pinned here).
  final ValueChanged<DateTime>? onDayAdd;
  /// Attached to the timed/untimed divider — the drop wash splits on it.
  final GlobalKey dividerKey;

  const _DayColumn({
    required this.cell,
    required this.index,
    required this.core,
    required this.onDayTap,
    required this.onToggleTask,
    required this.onDeleteTask,
    required this.dividerKey,
    this.animateEntrance = false,
    this.taskState,
    this.onHover,
    this.onDayAdd,
  });

  @override
  State<_DayColumn> createState() => _DayColumnState();
}

class _DayColumnState extends State<_DayColumn> {
  bool _isHovered = false; // Phase 4.1: local hover for _HoverGlowBackground

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.taskState == null) {
      final dayTasks = widget.core.tasksForDate(widget.cell.dateTimestamp);
      return _buildColumnContent(dayTasks);
    }

    return ValueListenableBuilder<List<RustTask>>(
      valueListenable: widget.taskState!.tasksForDateNotifier(widget.cell.dateTimestamp),
      builder: (context, dayTasks, child) => _buildColumnContent(dayTasks),
    );
  }

  Widget _buildColumnContent(List<RustTask> dayTasks) {
    final taskCount = dayTasks.length;
    final completedCount = dayTasks.where((t) => t.isCompleted).length;
    // Past days recede like in the month view — the week reads as "now and
    // ahead", yesterday is a quiet record, not a competing surface.
    final now = DateTime.now();
    final isPast = !widget.cell.isToday &&
        DateTime.fromMillisecondsSinceEpoch(widget.cell.dateTimestamp)
            .isBefore(DateTime(now.year, now.month, now.day));

    // Single MouseRegion at column root drives ALL hover states.
    // No nested MouseRegions on the background — eliminates flicker.
    Widget col = MouseRegion(
      onEnter: (_) {
        // Mid-drag the cell shows the drop wash instead — no hover chrome.
        if (DragSession.hoverSuppressed) return;
        setState(() => _isHovered = true);
        widget.onHover?.call(true);
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        widget.onHover?.call(false);
      },
      child: SizedBox.expand(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => widget.onDayTap(DateTime.fromMillisecondsSinceEpoch(widget.cell.dateTimestamp)),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Bottom layer: hover background driven by parent state — no flicker
              _HoverGlowBackground(
                isToday: widget.cell.isToday,
                isHovered: _isHovered,
              ),
              // Top layer: content
              Positioned.fill(
                child: Opacity(
                  opacity: isPast ? 0.5 : 1.0,
                  child: Column(
                  children: [
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => widget.onDayTap(DateTime.fromMillisecondsSinceEpoch(widget.cell.dateTimestamp)),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                        child: Column(
                          children: [
                          Text(
                            ['MON','TUE','WED','THU','FRI','SAT','SUN'][widget.cell.dayOfWeek],
                            style: TextStyle(
                              fontFamily: 'InterTight',
                              fontSize: 9,
                              fontWeight: FontWeight.w500,
                              letterSpacing: 1.2,
                              color: widget.cell.isToday
                                  ? Colors.white.withOpacity(0.6)
                                  : Colors.white.withOpacity(0.3),
                            ),
                          ),
                          const SizedBox(height: 6),
                          Container(
                            width: 32, height: 32,
                            decoration: widget.cell.isToday ? BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white.withOpacity(0.12),
                              border: Border.all(
                                color: Colors.white.withOpacity(0.2), width: 0.5),
                            ) : null,
                            alignment: Alignment.center,
                            child: Text(
                              '${widget.cell.dayOfMonth}',
                              style: TextStyle(
                                fontFamily: 'InterTight',
                                fontWeight: widget.cell.isToday ? FontWeight.w700 : FontWeight.w400,
                                color: widget.cell.isToday
                                    ? Colors.white.withOpacity(0.95)
                                    : Colors.white.withOpacity(0.5),
                                fontSize: 18,
                                height: 1.0,
                              ),
                            ),
                          ),
                          if (taskCount > 0) ...[
                            const SizedBox(height: 7),
                            QuietProgressRing(
                                completed: completedCount,
                                total: taskCount,
                                size: 10),
                          ],
                        ],
                      ),
                    ),
                    ), // Close GestureDetector
                    Container(
                      height: 0.5,
                      color: Colors.white.withOpacity(widget.cell.isToday ? 0.08 : 0.04),
                    ),
                    Expanded(
                      child: _buildTaskList(context, dayTasks),
                    ),
                  ],
                  ),
                ),
              ),
              // Mouse «+» — the calm way for a mouse user to add to THIS day.
              // Fades in on hover; its own tap is absorbed so it never zooms the
              // day in. Hidden mid-drag (hoverSuppressed).
              if (widget.onDayAdd != null)
                Positioned(
                  top: 13,
                  right: 12,
                  child: IgnorePointer(
                    ignoring: !_isHovered,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 140),
                      opacity:
                          _isHovered && !DragSession.hoverSuppressed ? 1.0 : 0.0,
                      child: _DayAddButton(
                        onTap: () => widget.onDayAdd!(
                            DateTime.fromMillisecondsSinceEpoch(
                                widget.cell.dateTimestamp)),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    // Staggered FADE only — NO slideY. The vertical slide here stacked on top of the
    // parent zoom (ScaleTransition+Fade) and made every column's text "settle"
    // downward on zoom-in. A pure opacity stagger gives a premium ripple with zero
    // positional movement. Stable tree shape (always wrapped, durations→0 when idle)
    // so flipping `animateEntrance` never restructures the subtree / resets cards.
    final dur = widget.animateEntrance ? 250.ms : Duration.zero;
    final delay = widget.animateEntrance
        ? Duration(milliseconds: 50 * widget.index)
        : Duration.zero;
    return col.animate().fadeIn(duration: dur, delay: delay);
  }

  // Capacity is measured, not hard-coded: the column shows as many cards as
  // actually FIT its height; «+N more» appears only on real overflow (the
  // cell is a preview — click zooms into the day for the full list).
  // Timed tasks come FIRST, earliest on top (your next thing is what you see),
  // then the divider, then the unscheduled pool.
  Widget _buildTaskList(BuildContext context, List<RustTask> dayTasks) {
    // Rebuild as the drag crosses this cell's divider / moves between days, so
    // the incoming card reflows to its true landing spot in real time.
    // Listens to the session ITSELF as well as to hover: the rail (and the room
    // reserved for it) must appear the instant a timed card is lifted, before
    // the cursor has crossed any cell.
    return AnimatedBuilder(
      animation: DragSession.instance,
      builder: (context, _) => ValueListenableBuilder<DropHover?>(
      valueListenable: DragSession.instance.hover,
      builder: (context, _, _) {
        final cellDate =
            DateTime.fromMillisecondsSinceEpoch(widget.cell.dateTimestamp);
        final preview = DropFuture.forDate(cellDate);
        return ValueListenableBuilder<Set<String>>(
          valueListenable: DeleteSettle.deleting,
          builder: (context, dying, _) =>
              LayoutBuilder(builder: (context, constraints) {
          const itemH = 38.0; // compact HoverTaskCard: fixed 34 + 4 bottom margin
          const dividerH = 17.0; // _PremiumMiniDivider: 8 pad + '◇' glyph row
          const moreH = 18.0;

          // The dragged card is hidden at its source — drop it from the base so
          // DO NOT filter the dragged task out. It stays as its own DragSource,
          // which dims itself to 0 during the settle AND restores itself when the
          // drop finishes (it listens to hiddenTaskId) — and it keeps its entry
          // in DragCardRegistry so the flight lands ON it. Filtering it broke all
          // three: the flight fell back to a wrong rect, and the card vanished
          // until an unrelated rebuild.
          //
          // Splice the honey preview in ONLY when the task isn't already here —
          // i.e. a cross-day drop. Same-day, the real (dimmed) card is the show.
          final showPreview = preview != null &&
              !dayTasks.any((t) => t.id == preview.projected.id);

          final unallocated = TaskState.orderUnallocated(
              dayTasks.where((t) => t.startTime == null).toList());
          final allocated = dayTasks.where((t) => t.startTime != null).toList()
            ..sort((a, b) => (a.startTime ?? 0).compareTo(b.startTime ?? 0));

          if (showPreview) {
            if (preview.keepsTime) {
              allocated
                ..add(preview.projected)
                ..sort((a, b) => (a.startTime ?? 0).compareTo(b.startTime ?? 0));
            } else {
              unallocated.insert(0, preview.projected);
            }
          }
          // A row playing its collapse is already gone as far as CAPACITY goes:
          // that's what promotes the next card DURING the collapse instead of
          // popping it in after. It is still emitted, so the collapse plays.
          bool isDying(RustTask t) => dying.contains(t.id);
          final dyingHere =
              [...allocated, ...unallocated].where(isDying).length;
          final total = unallocated.length + allocated.length - dyingHere;

          // An empty column is calm — blank, with the hover «+» as its quiet
          // affordance. The anatomy (timed / untimed / the divider) is taught by
          // the REAL seeded tasks a new user can touch, not by grey fake rows.
          if (total == 0 && dyingHere == 0) return const SizedBox.shrink();
          final bothGroups = unallocated.isNotEmpty && allocated.isNotEmpty;

          // While the Anytime rail is up it owns the bottom strip — give it the
          // room instead of letting it cover the last card. This reflows ONCE
          // per drag (at lift and at drop), never per cursor move, so it can't
          // become a feedback loop.
          final railRoom = DragSession.instance.isActive &&
                  DragSession.instance.payload?.task.startTime != null
              ? 26.0
              : 0.0;
          final avail = constraints.maxHeight - 12 - railRoom;
          var fit = ((avail - (bothGroups ? dividerH : 0)) / itemH)
              .floor()
              .clamp(0, total);
          if (fit < total) {
            fit = ((avail - moreH - (bothGroups ? dividerH : 0)) / itemH)
                .floor()
                .clamp(0, total);
          }
          // The incoming card must always be visible — never let the cap hide
          // the very thing the cursor is placing.
          if (showPreview) fit = (fit + 1).clamp(0, total);

          bool isPreview(RustTask t) =>
              showPreview && identical(t, preview.projected);

          Widget realCard(RustTask task) => DragSource(
                key: ValueKey(task.id),
                task: task,
                kind: DragSourceKind.dayCellCard,
                sourceDay: cellDate,
                sourceInsets: const EdgeInsets.only(bottom: 4),
                child: HoverTaskCard(
                  task: task,
                  compact: true,
                  // Week is an overview — no hover peek; click the day to act.
                  enablePeek: false,
                  onTap: () => widget.onToggleTask(task),
                  onDelete: () => widget.onDeleteTask(task),
                  onEditTitle: (val) {
                    widget.taskState?.updateTask(task.copyWith(title: val));
                  },
                ),
              );

          Widget emit(RustTask t) =>
              isPreview(t) ? preview!.card() : realCard(t);

          final items = <Widget>[];
          var count = 0;
          for (final t in allocated) {
            if (isDying(t)) {
              items.add(emit(t)); // collapsing — costs no slot
              continue;
            }
            if (count >= fit) break;
            items.add(emit(t));
            count++;
          }
          if (bothGroups && count < fit) {
            items.add(KeyedSubtree(
                key: widget.dividerKey, child: const _PremiumMiniDivider()));
          }
          for (final t in unallocated) {
            if (isDying(t)) {
              items.add(emit(t));
              continue;
            }
            if (count >= fit) break;
            items.add(emit(t));
            count++;
          }
          final hiddenCount = total - count;

          // ClipRect: belt-and-braces — whatever happens to card heights in the
          // future, nothing may ever bleed past the day card's frame again.
          return ClipRect(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ...items,
                  // Fades rather than cuts: on a delete the label reaches its
                  // final value while the promoted card is still gliding up, so
                  // the two cross instead of swapping in one frame.
                  AnimatedOpacity(
                    key: const ValueKey('more'),
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                    opacity: hiddenCount > 0 ? 1.0 : 0.0,
                    child: hiddenCount > 0
                        ? Padding(
                            padding: const EdgeInsets.only(top: 4, bottom: 2),
                            child: Text('+$hiddenCount more',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontFamily: 'Inter', fontSize: 9,
                                  color: Colors.white.withOpacity(0.3),
                                )),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          );
        }),
        );
      },
      ),
    );
  }
}


// V2.4: HOVER GLOW BACKGROUND — Driven by parent via isHovered prop.
// No internal MouseRegion — parent's single MouseRegion controls the state.
// This eliminates the hover-flicker caused by stacked hit-test regions.
// ─────────────────────────────────────────────────────────────────────────────
class _HoverGlowBackground extends StatelessWidget {
  final bool isToday;
  final bool isHovered;
  const _HoverGlowBackground({required this.isToday, required this.isHovered});
  @override
  Widget build(BuildContext context) {
    final borderOpacity = isToday
        ? (isHovered ? 0.30 : 0.14)
        : (isHovered ? 0.14 : 0.05);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: 1, vertical: 6),
      decoration: BoxDecoration(
        gradient: isToday
            ? const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF1E2024),
                  Color(0xFF151618),
                  Color(0xFF0D0D0F),
                ],
                stops: [0.0, 0.3, 1.0],
              )
            : (isHovered
                ? LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.white.withOpacity(0.03),
                      Colors.white.withOpacity(0.01),
                      Colors.white.withOpacity(0.005),
                    ],
                  )
                : null),
        color: (!isToday && !isHovered) ? AppTheme.surface : null,
        borderRadius: BorderRadius.circular(AppTheme.radiusXLarge),
        border: Border.all(
          color: Colors.white.withOpacity(borderOpacity),
          width: isToday ? 1.0 : 0.5,
        ),
        boxShadow: [
          // Ambient base shadow
          BoxShadow(
            color: Colors.black.withOpacity(0.25),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
          if (isToday) ...[
            BoxShadow(
              color: const Color(0xFF64C8FF).withOpacity(0.06),
              blurRadius: 16,
              spreadRadius: -2,
              offset: const Offset(0, -3),
            ),
            BoxShadow(
              color: Colors.white.withOpacity(0.015),
              blurRadius: 1,
              spreadRadius: -1,
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 12,
              offset: const Offset(0, 6),
            ),
          ],
          if (isHovered && !isToday) ...[
            BoxShadow(
              color: Colors.black.withOpacity(0.55),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.2),
              blurRadius: 24,
              offset: const Offset(0, 16),
            ),
          ],
          if (isHovered && isToday) ...[
            BoxShadow(
              color: const Color(0xFF64C8FF).withOpacity(0.08),
              blurRadius: 20,
              spreadRadius: -4,
              offset: const Offset(0, -4),
            ),
            BoxShadow(
              color: Colors.black.withOpacity(0.5),
              blurRadius: 20,
              offset: const Offset(0, 10),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DAY ADD BUTTON — the quiet mouse «+» that appears on a day-cell hover.
// Its own tap is absorbed (opaque) so clicking it adds to the day instead of
// zooming in. Basic cursor (manifest law: no I-beam outside a text field).
// ─────────────────────────────────────────────────────────────────────────────
class _DayAddButton extends StatefulWidget {
  final VoidCallback onTap;
  const _DayAddButton({required this.onTap});

  @override
  State<_DayAddButton> createState() => _DayAddButtonState();
}

class _DayAddButtonState extends State<_DayAddButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: _hovered ? 0.14 : 0.06),
            border: Border.all(
              color: Colors.white.withValues(alpha: _hovered ? 0.28 : 0.12),
              width: 0.5,
            ),
          ),
          child: Icon(
            Icons.add_rounded,
            size: 14,
            color: Colors.white.withValues(alpha: _hovered ? 0.8 : 0.45),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// PREMIUM MINI DIVIDER
// ═══════════════════════════════════════════════════════════════════════════
class _PremiumMiniDivider extends StatelessWidget {
  const _PremiumMiniDivider();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Container(
              height: 0.5,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    Colors.white.withOpacity(0.08),
                    Colors.white.withOpacity(0.08),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.15, 0.85, 1.0],
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(
              '◇',
              style: TextStyle(
                fontFamily: 'Inter',
                fontSize: 6,
                color: Colors.white.withOpacity(0.12),
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
                    Colors.white.withOpacity(0.08),
                    Colors.white.withOpacity(0.08),
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
