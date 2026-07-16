import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import '../../core/theme/app_theme.dart';
import '../../core/engine/slate_core_bridge.dart';
import '../../core/engine/spatial_zoom_engine.dart';
import '../../core/state/task_state.dart';
import '../../core/interaction/drag_session.dart';
import '../widgets/hover_task_card.dart';
import '../widgets/drag_source.dart';
import '../widgets/day_cell_drop_target.dart';
import '../widgets/desktop_scroll_wrapper.dart';

/// Phase 6 — Month Grid View (Unified Discrete Snap Scrolling)
/// Scroll: DesktopScrollWrapper(pageController) — 1 tick = 1 month, 400ms easeInOutCubic.
/// Ctrl+Scroll passthrough preserved for zoom. Animation-lock prevents double-trigger.
/// Day cells: premium top-left padding, 10px task text, ClipRect overflow guard.
/// Inline task creation: '+' opens in-cell TextField — no navigation.
/// (Old _MonthSnapPhysics removed — the PageView runs NeverScrollableScrollPhysics
/// and DesktopScrollWrapper owns all wheel-driven paging.)

// ─────────────────────────────────────────────────────────────────────────────
// MONTH GRID VIEW — PageView-based infinite scroll (same as Week view)
// ─────────────────────────────────────────────────────────────────────────────
class MonthGridView extends StatefulWidget {
  final SlateCore core;
  final ValueChanged<DateTime> onDayTap;
  final DateTime? focusDate;
  final TaskState? taskState;
  /// Fires +1/-1 increments to scroll forward/back one month (arrow key / keyboard).
  final ValueNotifier<int>? scrollDeltaNotifier;
  /// Reports which date the mouse is over (null = ghost/empty cell).
  final ValueChanged<DateTime?>? onDayHover;
  /// Mouse «+»: add a task to THIS day (opens the shell capture pill pinned to
  /// it). Separate from onDayTap (which zooms into the day).
  final ValueChanged<DateTime>? onDayAdd;

  const MonthGridView({
    super.key,
    required this.core,
    required this.onDayTap,
    this.focusDate,
    this.taskState,
    this.scrollDeltaNotifier,
    this.onDayHover,
    this.onDayAdd,
  });

  @override
  State<MonthGridView> createState() => _MonthGridViewState();
}

class _MonthGridViewState extends State<MonthGridView> {
  static const int _pageCenter = 500;
  static int _savedMonthOffset = 0;

  late final PageController _pageController;
  final ValueNotifier<int> _monthOffset = ValueNotifier(0);

  // Tracks the last scroll delta to detect new increments from keyboard
  int _lastScrollDelta = 0;

  @override
  void initState() {
    super.initState();
    int initialOffset = _savedMonthOffset;
    if (widget.focusDate != null) {
      final now = DateTime.now();
      initialOffset = (widget.focusDate!.year - now.year) * 12 +
          (widget.focusDate!.month - now.month);
    }
    _monthOffset.value = initialOffset;
    _pageController = PageController(initialPage: _pageCenter + initialOffset);
    // #E — normalise the shared anchor to the visible month ON ENTRY so a
    // MONTH→WEEK toggle (without scrolling) lands on a week inside this month.
    final m0 = _monthForOffset(initialOffset);
    final now0 = DateTime.now();
    StaircaseState.selectedDate = (now0.year == m0.year && now0.month == m0.month)
        ? DateTime(now0.year, now0.month, now0.day)
        : DateTime(m0.year, m0.month, 1);
    widget.scrollDeltaNotifier?.addListener(_onScrollDelta);
    if (widget.scrollDeltaNotifier != null) {
      _lastScrollDelta = widget.scrollDeltaNotifier!.value;
    }
    DragSession.instance.addListener(_onDragPhaseDwell);
    DragSession.instance.pointerGlobal.addListener(_onDragPointerDwell);
  }

  // ── Edge-dwell page flip (vertical): hold a dragged card at the grid's
  // top/bottom edge ~650ms → previous/next month (repeats while held). ──────
  Timer? _dwellTimer;
  int _dwellArmed = 0;
  final ValueNotifier<int> _dwellGlow = ValueNotifier(0);
  final GlobalKey _gridKey = GlobalKey();

  void _onDragPhaseDwell() {
    if (!DragSession.instance.isActive) _cancelDwell();
  }

  void _onDragPointerDwell() {
    if (!mounted || !DragSession.instance.isActive) return;
    final ctx = _gridKey.currentContext ?? context;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) {
      _cancelDwell();
      return;
    }
    final local = box.globalToLocal(DragSession.instance.pointerGlobal.value);
    int dir = 0;
    if ((Offset.zero & box.size).contains(local)) {
      const band = 40.0;
      if (local.dy <= band) {
        dir = -1;
      } else if (local.dy >= box.size.height - band) {
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
      _flipMonth(dir);
      _dwellArmed = 0; // pointer is static → re-arm for repeat flips
      _onDragPointerDwell();
    });
  }

  void _flipMonth(int dir) {
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

  /// Soft edge glow while a dragged card is armed over a dwell band.
  Widget _dwellGlowEdge(int dir) {
    return Positioned(
      top: dir < 0 ? 0 : null,
      bottom: dir > 0 ? 0 : null,
      left: 0,
      right: 0,
      height: 48,
      child: IgnorePointer(
        child: ValueListenableBuilder<int>(
          valueListenable: _dwellGlow,
          builder: (_, glow, __) => AnimatedOpacity(
            duration: const Duration(milliseconds: 160),
            opacity: glow == dir ? 1.0 : 0.0,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: dir < 0 ? Alignment.topCenter : Alignment.bottomCenter,
                  end: dir < 0 ? Alignment.bottomCenter : Alignment.topCenter,
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

  @override
  void didUpdateWidget(MonthGridView old) {
    super.didUpdateWidget(old);
    if (old.scrollDeltaNotifier != widget.scrollDeltaNotifier) {
      old.scrollDeltaNotifier?.removeListener(_onScrollDelta);
      widget.scrollDeltaNotifier?.addListener(_onScrollDelta);
      if (widget.scrollDeltaNotifier != null) {
        _lastScrollDelta = widget.scrollDeltaNotifier!.value;
      }
    }
  }

  void _onScrollDelta() {
    final delta = widget.scrollDeltaNotifier?.value ?? _lastScrollDelta;
    final diff = delta - _lastScrollDelta;
    if (diff == 0 || !_pageController.hasClients) return;
    _lastScrollDelta = delta;
    final currentPage = _pageController.page?.round() ?? (_pageCenter + _monthOffset.value);
    _pageController.animateToPage(
      (currentPage + diff).clamp(0, _pageCenter * 2 - 1),
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutQuart,
    );
  }

  @override
  void dispose() {
    DragSession.instance.removeListener(_onDragPhaseDwell);
    DragSession.instance.pointerGlobal.removeListener(_onDragPointerDwell);
    _dwellTimer?.cancel();
    _dwellGlow.dispose();
    widget.scrollDeltaNotifier?.removeListener(_onScrollDelta);
    _pageController.dispose();
    _monthOffset.dispose();
    super.dispose();
  }

  DateTime _monthForOffset(int offset) {
    final now = DateTime.now();
    final totalMonths = now.year * 12 + (now.month - 1) + offset;
    final year = totalMonths ~/ 12;
    final month = (totalMonths % 12) + 1;
    return DateTime(year, month, 1);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppTheme.spacing24, vertical: AppTheme.spacing16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 16),
          _buildWeekdayLabels(),
          const SizedBox(height: 8),
          // Subtle separator
          Container(
            height: 0.5,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.white.withOpacity(0.0),
                  Colors.white.withOpacity(0.06),
                  Colors.white.withOpacity(0.06),
                  Colors.white.withOpacity(0.0),
                ],
                stops: const [0.0, 0.15, 0.85, 1.0],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Stack(
              key: _gridKey,
              children: [
                ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
              child: DesktopScrollWrapper(
                pageController: _pageController,
                baseDurationMs: 400, // Ускорили для уверенного финиша
                child: PageView.builder(
                  controller: _pageController,
                  scrollDirection: Axis.vertical,
                  pageSnapping: true,
                  physics: const NeverScrollableScrollPhysics(), // БЛОКИРУЕМ БАРЬЕРЫ НА 100%
                  onPageChanged: (page) {
                    final offset = page - _pageCenter;
                    _monthOffset.value = offset;
                    _savedMonthOffset = offset;
                    // Shared anchor (#E): park selectedDate on the visible month so a
                    // MONTH→WEEK toggle follows the month you're looking at. Use today
                    // if it falls in this month, else the 1st.
                    final m = _monthForOffset(offset);
                    final now = DateTime.now();
                    StaircaseState.selectedDate =
                        (now.year == m.year && now.month == m.month)
                            ? DateTime(now.year, now.month, now.day)
                            : DateTime(m.year, m.month, 1);
                  },
                  itemCount: _pageCenter * 2,
                  itemBuilder: (context, pageIndex) {
                    final offset = pageIndex - _pageCenter;
                    final month = _monthForOffset(offset);
                    return Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerSignal: (event) {
                        if (event is PointerScrollEvent) {
                          // Prevent native Scrollable from stealing vertical wheel ticks
                          // This guarantees DesktopScrollWrapper wins and achieves 1-tick=1-page
                          GestureBinding.instance.pointerSignalResolver.register(event, (e) {});
                        }
                      },
                      child: Container(
                        color: Colors.transparent, // Абсолютная защита от "дыр" при анимации
                        child: RepaintBoundary( // Кэшируем страницу целиком (макс FPS при скролле)
                          child: _MonthPage(
                            viewMonth: month,
                            core: widget.core,
                            taskState: widget.taskState,
                            onDayTap: widget.onDayTap,
                            onDayHover: widget.onDayHover,
                            onDayAdd: widget.onDayAdd,
                            onToggleTask: (task) {
                              widget.taskState?.toggleTask(task);
                            },
                            onCreateTask: (date, title) {
                              widget.taskState?.createTask(title, date.millisecondsSinceEpoch);
                            },
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
                _dwellGlowEdge(-1),
                _dwellGlowEdge(1),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── HEADER — ValueListenableBuilder (only this rebuilds on scroll) ──
  Widget _buildHeader() {
    return ValueListenableBuilder<int>(
      valueListenable: _monthOffset,
      builder: (context, offset, _) {
        final month = _monthForOffset(offset);
        final now = DateTime.now();
        final isCurrentMonth =
            month.year == now.year && month.month == now.month;

        const months = [
          'January', 'February', 'March', 'April', 'May', 'June',
          'July', 'August', 'September', 'October', 'November', 'December'
        ];

        return Row(
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              switchInCurve: Curves.easeOutQuart,
              child: Text(
                '${months[month.month - 1]} ${month.year}',
                key: ValueKey('${month.month}-${month.year}'),
                style: TextStyle(
                  fontFamily: 'InterTight',
                  fontSize: 22,
                  fontWeight: FontWeight.w300,
                  letterSpacing: -0.5,
                  color: Colors.white.withOpacity(isCurrentMonth ? 0.85 : 0.6),
                  height: 1.0,
                ),
              ),
            ),
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

  Widget _buildWeekdayLabels() {
    const labels = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    return Row(
      children: labels
          .map((l) => Expanded(
                child: Center(
                  child: Text(
                    l,
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.8,
                      color: Colors.white.withOpacity(0.2),
                    ),
                  ),
                ),
              ))
          .toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MONTH PAGE — A single month grid (7-col, 5-6 rows)
// ─────────────────────────────────────────────────────────────────────────────
class _MonthPage extends StatefulWidget {
  final DateTime viewMonth;
  final SlateCore core;
  final TaskState? taskState;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<DateTime?>? onDayHover;
  final ValueChanged<DateTime>? onDayAdd;
  final ValueChanged<RustTask>? onToggleTask;
  final void Function(DateTime date, String title)? onCreateTask;

  const _MonthPage({
    required this.viewMonth,
    required this.core,
    this.taskState,
    required this.onDayTap,
    this.onDayHover,
    this.onDayAdd,
    this.onToggleTask,
    this.onCreateTask,
  });

  @override
  State<_MonthPage> createState() => _MonthPageState();
}

class _MonthPageState extends State<_MonthPage> {
  int _hoveredIndex = -1;
  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final daysInMonth = DateUtils.getDaysInMonth(
        widget.viewMonth.year, widget.viewMonth.month);
    final firstWeekday =
        DateTime(widget.viewMonth.year, widget.viewMonth.month, 1).weekday;
    final leadingSlots = firstWeekday - 1;
    final totalSlots = leadingSlots + daysInMonth;
    final rows = (totalSlots / 7).ceil();

    // Previous month for ghost days
    final prevMonth =
        DateTime(widget.viewMonth.year, widget.viewMonth.month - 1, 1);
    final daysInPrevMonth =
        DateUtils.getDaysInMonth(prevMonth.year, prevMonth.month);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          final cellW = (w - (7 - 1) * 3) / 7;
          final cellH = (h - (rows - 1) * 3) / rows;

          return GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 7,
              mainAxisSpacing: 3,
              crossAxisSpacing: 3,
              childAspectRatio: cellW / cellH,
            ),
            itemCount: rows * 7,
            itemBuilder: (context, gridIndex) {
              final dayIndex = gridIndex - leadingSlots;

              // Leading ghost days
              if (dayIndex < 0) {
                final ghostDay = daysInPrevMonth + dayIndex + 1;
                return MouseRegion(
                  onEnter: (_) => widget.onDayHover?.call(null),
                  child: _buildGhostCell(ghostDay),
                );
              }

              // Trailing ghost days
              if (dayIndex >= daysInMonth) {
                final ghostDay = dayIndex - daysInMonth + 1;
                return MouseRegion(
                  onEnter: (_) => widget.onDayHover?.call(null),
                  child: _buildGhostCell(ghostDay),
                );
              }

              // Current month day
              final day = dayIndex + 1;
              final date = DateTime(
                  widget.viewMonth.year, widget.viewMonth.month, day);
              final isToday = date.isAtSameMomentAs(today);
              final isPast = date.isBefore(today);
              if (widget.taskState == null) {
                final dayTasks = widget.core.tasksForDate(date.millisecondsSinceEpoch);
                return _buildDayCell(gridIndex, day, date, isToday, isPast, dayTasks);
              }

              return ValueListenableBuilder<List<RustTask>>(
                valueListenable: widget.taskState!.tasksForDateNotifier(date.millisecondsSinceEpoch),
                builder: (context, dayTasks, child) {
                  return _buildDayCell(gridIndex, day, date, isToday, isPast, dayTasks);
                },
              );
            },
          );
        }),
    );
  }

  Widget _buildGhostCell(int day) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: Colors.white.withOpacity(0.005),
      ),
      child: Padding(
        padding: const EdgeInsets.only(top: 10, left: 14),
        child: Text(
          '$day',
          style: TextStyle(
            fontFamily: 'InterTight',
            fontSize: 13,
            fontWeight: FontWeight.w300,
            color: Colors.white.withOpacity(0.08),
            height: 1.0,
          ),
        ),
      ),
    );
  }

  Widget _buildDayCell(int gridIndex, int day, DateTime date, bool isToday,
      bool isPast, List<RustTask> dayTasks) {
    final isHovered = _hoveredIndex == gridIndex;
    final totalTasks = dayTasks.length;
    final completedTasks = dayTasks.where((t) => t.isCompleted).length;
    final dayOpacity = isPast && !isToday ? 0.45 : 1.0;
    // Month is an OVERVIEW — no hover peek (a floating "second day" read as
    // clutter). To see/act on a full day, click it → zoom in.
    return DayCellDropTarget(
      date: date,
      taskState: widget.taskState,
      settleTopOffset: 34,
      settleHeight: 24,
      highlightRadius: BorderRadius.circular(AppTheme.radiusXLarge),
      builder: (dividerKey) => MouseRegion(
      onEnter: (_) {
        // Mid-drag the cell shows the drop wash instead — no hover chrome.
        if (DragSession.hoverSuppressed) return;
        setState(() => _hoveredIndex = gridIndex);
        widget.onDayHover?.call(date);
      },
      onExit: (_) => setState(() {
        if (_hoveredIndex == gridIndex) _hoveredIndex = -1;
        widget.onDayHover?.call(null);
      }),
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: () => widget.onDayTap(date),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppTheme.radiusXLarge),
            gradient: isToday
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: isHovered
                        ? const [Color(0xFF252834), Color(0xFF181A20)] // Elevated Today Grid cell
                        : const [Color(0xFF1E2028), Color(0xFF14161A)],
                  )
                : null,
            color: isToday
                ? null
                : (isHovered
                    ? Colors.white.withOpacity(0.09)
                    : Colors.white.withOpacity(0.045)),
            border: Border.all(
              color: isToday
                  ? (isHovered ? Colors.white.withOpacity(0.4) : Colors.white.withOpacity(0.22))
                  : (isHovered
                      ? Colors.white.withOpacity(0.22)
                      : Colors.white.withOpacity(0.12)),
              width: (isToday || isHovered) ? 1.0 : 0.5,
            ),
            boxShadow: [
              if (isToday) ...[
                BoxShadow(
                  color: const Color(0xFF64C8FF).withOpacity(isHovered ? 0.15 : 0.05),
                  blurRadius: isHovered ? 24 : 16,
                  spreadRadius: isHovered ? 2 : -2,
                ),
                BoxShadow(
                  color: Colors.white.withOpacity(0.015),
                  blurRadius: 8,
                  offset: const Offset(0, -1),
                ),
              ],
              if (isHovered && !isToday) ...[
                BoxShadow(
                  color: Colors.black.withOpacity(0.5),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ],
          ),
          child: Opacity(
            opacity: dayOpacity,
            child: LayoutBuilder(
              builder: (context, box) {
                final showTitles = box.maxHeight > 68;
                return Stack(
                  children: [
                    // ── Main cell content ──────────────────────────────────
                    Column(
                      mainAxisAlignment: MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Day number — premium top-left padding
                        Padding(
                          padding: const EdgeInsets.only(top: 10, left: 14),
                          child: IgnorePointer(
                            child: Text(
                              '$day',
                              style: TextStyle(
                                fontFamily: 'InterTight',
                                fontSize: 15,
                                fontWeight: isToday ? FontWeight.w700 : FontWeight.w400,
                                color: isToday
                                    ? Colors.white.withOpacity(0.95)
                                    : Colors.white.withOpacity(0.55),
                                height: 1.0,
                              ),
                            ),
                          ),
                        ),
                        // Completion dots
                        if (totalTasks > 0) ...[
                          const SizedBox(height: 4),
                          IgnorePointer(
                            child: Padding(
                              padding: const EdgeInsets.only(left: 14),
                              child: Row(
                                children: List.generate(
                                  totalTasks.clamp(0, 4),
                                  (i) => AnimatedContainer(
                                    duration: const Duration(milliseconds: 200),
                                    width: 3,
                                    height: 3,
                                    margin: const EdgeInsets.only(right: 2),
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: i < completedTasks
                                          ? Colors.green.withOpacity(0.5)
                                          : (isToday
                                              ? Colors.white.withOpacity(0.35)
                                              : Colors.white.withOpacity(0.18)),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],

                        // Phase 5: Task list
                        if (showTitles) ...[
                          const SizedBox(height: 4),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 5),
                              child: ClipRect(
                                child: SingleChildScrollView(
                                  physics: const NeverScrollableScrollPhysics(),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      ...() {
                                        // Timed first (earliest on top), then the unscheduled pool.
                                        final unallocated = TaskState.orderUnallocated(
                                            dayTasks.where((t) => t.startTime == null).toList());
                                        final allocated = dayTasks.where((t) => t.startTime != null).toList()
                                          ..sort((a, b) => (a.startTime ?? 0).compareTo(b.startTime ?? 0));
                                        final List<Widget> items = [];

                                        Widget buildCard(RustTask task) => Padding(
                                              padding: const EdgeInsets.only(bottom: 2),
                                              child: DragSource(
                                                task: task,
                                                kind: DragSourceKind.dayCellCard,
                                                sourceDay: date,
                                                sourceInsets: const EdgeInsets.only(bottom: 4),
                                                child: HoverTaskCard(
                                                  task: task,
                                                  compact: true,
                                                  // Cell-level day peek covers the full titles here.
                                                  enablePeek: false,
                                                  onTap: () {
                                                    widget.onToggleTask?.call(task);
                                                    setState(() {});
                                                  },
                                                  onDelete: () => widget.taskState?.deleteTask(task),
                                                  onEditTitle: (val) => widget.taskState?.updateTask(task.copyWith(title: val)),
                                                ),
                                              ),
                                            );

                                        int count = 0;
                                        for (final t in allocated) {
                                          if (count >= 2) break;
                                          items.add(buildCard(t));
                                          count++;
                                        }

                                        if (unallocated.isNotEmpty && allocated.isNotEmpty && count < 2) {
                                          items.add(KeyedSubtree(
                                              key: dividerKey,
                                              child: const _PremiumMiniDivider()));
                                        }

                                        for (final t in unallocated) {
                                          if (count >= 2) break;
                                          items.add(buildCard(t));
                                          count++;
                                        }

                                        return items;
                                      }(),
                                      if (dayTasks.length > 2)
                                        IgnorePointer(
                                          child: Text(
                                            '+${dayTasks.length - 2} more',
                                            style: TextStyle(
                                              fontFamily: 'Inter',
                                              fontSize: 8.5,
                                              color: Colors.white.withOpacity(0.22),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ] else
                          const Spacer(),
                        const SizedBox(height: 6),
                      ],
                    ),
                    // Mouse «+» — the calm way for a mouse user to add to THIS
                    // day. Fades in on hover; its own tap is absorbed so it adds
                    // instead of zooming in. Hidden mid-drag (hoverSuppressed).
                    if (widget.onDayAdd != null)
                      Positioned(
                        top: 9,
                        right: 9,
                        child: IgnorePointer(
                          ignoring: !isHovered,
                          child: AnimatedOpacity(
                            duration: const Duration(milliseconds: 140),
                            opacity: isHovered && !DragSession.hoverSuppressed
                                ? 1.0
                                : 0.0,
                            child: _DayAddButton(
                              onTap: () => widget.onDayAdd!(date),
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
      ),
    ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DAY ADD BUTTON — the quiet mouse «+» that appears on a day-cell hover. Its own
// tap is absorbed (opaque) so it adds to the day instead of zooming in. Basic
// cursor (manifest law: no I-beam outside a text field).
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
          width: 20,
          height: 20,
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
            size: 13,
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
