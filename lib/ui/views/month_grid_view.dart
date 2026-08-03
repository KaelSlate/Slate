import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
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
  // True while a page has a day opened — freezes month paging so the popover
  // owns the wheel. A page writes it; the DesktopScrollWrapper above reads it.
  final ValueNotifier<bool> _dayOpen = ValueNotifier(false);

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
    _dayOpen.dispose();
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
                paused: _dayOpen, // an opened day owns the wheel
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
                            dayOpen: _dayOpen,
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

        // Pinned to a WHOLE number of pixels. Left free, the row took its
        // height from the "Today" pill (≈22.31 — font metrics + 0.5 borders),
        // which centred the 22.0 title at dy 0.157 and pushed every row below
        // onto a fractional y. A glyph on a fractional baseline is drawn one way
        // through the zoom's resampled raster and another way at rest — that one
        // pixel at the end of the transition was the title "sliding down".
        return SizedBox(
          height: 24,
          child: Row(
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

  Widget _buildWeekdayLabels() {
    const labels = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
    // Whole pixels, same reason as the header row: Inter@9 measures ≈10.9 and
    // that fraction lands on everything below it — including the grid, whose
    // bottom row then sits on a fractional edge against its clip.
    return SizedBox(
      height: 12,
      child: Row(
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
      ),
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
  // Shared with the parent's DesktopScrollWrapper: this page sets it true while
  // a day is opened so month paging freezes.
  final ValueNotifier<bool> dayOpen;
  final ValueChanged<DateTime> onDayTap;
  final ValueChanged<DateTime?>? onDayHover;
  final ValueChanged<DateTime>? onDayAdd;
  final ValueChanged<RustTask>? onToggleTask;
  final void Function(DateTime date, String title)? onCreateTask;

  const _MonthPage({
    required this.viewMonth,
    required this.core,
    this.taskState,
    required this.dayOpen,
    required this.onDayTap,
    this.onDayHover,
    this.onDayAdd,
    this.onToggleTask,
    this.onCreateTask,
  });

  @override
  State<_MonthPage> createState() => _MonthPageState();
}

class _MonthPageState extends State<_MonthPage>
    with SingleTickerProviderStateMixin {
  int _hoveredIndex = -1;

  // The cell whose full day is opened as a floating layer, or -1. A month cell
  // shows two rows and hides the rest behind «+N more»; without this a hidden
  // task could only be reached by hunting for it in the week view. Tapping the
  // pile opens the whole day over its neighbours; grabbing a card folds it away
  // again, so the reach-in affordance is gone the instant it has served.
  int _expandedIndex = -1;
  // The cell the popover is being PAINTED for — held one extra beat while the
  // close animation plays, so the panel eases out instead of snapping away.
  int _openIndex = -1;

  // Drives the open/close of the popover. Forward = unfold from the cell; the
  // reverse plays before the layer is removed. Curved per direction so it grows
  // with a soft settle and folds away a touch quicker.
  late final AnimationController _expandCtl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    reverseDuration: const Duration(milliseconds: 190),
  );
  late final Animation<double> _expand = CurvedAnimation(
    parent: _expandCtl,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void initState() {
    super.initState();
    DragSession.instance.addListener(_onDragPhase);
    _expandCtl.addStatusListener((s) {
      // Once folded shut, drop the painted layer.
      if (s == AnimationStatus.dismissed && mounted) {
        setState(() => _openIndex = -1);
      }
    });
  }

  // Single door for the open state so the shared paging-freeze flag, the painted
  // layer and the animation can never drift apart.
  void _setExpanded(int idx) {
    if (_expandedIndex == idx) return;
    _expandedIndex = idx;
    widget.dayOpen.value = idx != -1;
    if (idx != -1) {
      setState(() => _openIndex = idx);
      _expandCtl.forward(from: 0);
    } else {
      // Keep painting the old day through the fold-away; the status listener
      // clears _openIndex when the reverse lands.
      _expandCtl.reverse();
    }
  }

  void _onDragPhase() {
    if (!mounted) return;
    // A lift folds the expanded day away — you reached in, took the card, and
    // the month is clean underneath to drop it anywhere.
    if (_expandedIndex != -1 && DragSession.hoverSuppressed) {
      _setExpanded(-1);
    }
    setState(() {});
  }

  void _collapse() => _setExpanded(-1);

  @override
  void didUpdateWidget(_MonthPage old) {
    super.didUpdateWidget(old);
    // Paging to another month drops any open day at once (no fold-out).
    if (old.viewMonth != widget.viewMonth && _openIndex != -1) {
      _expandedIndex = -1;
      _openIndex = -1;
      _expandCtl.value = 0;
      widget.dayOpen.value = false;
    }
  }

  @override
  void dispose() {
    DragSession.instance.removeListener(_onDragPhase);
    _expandCtl.dispose();
    // Never leave paging frozen behind a disposed page.
    if (_expandedIndex != -1) widget.dayOpen.value = false;
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

    // Bottom gets more slack than the top on purpose — see the floor() below.
    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final w = constraints.maxWidth;
          final h = constraints.maxHeight;

          final cellW = (w - (7 - 1) * 3) / 7;
          // Floored so the last row always ENDS above the viewport edge. The
          // exact fit left it flush against the grid's clip, and while the zoom
          // holds filterQuality:low the whole view is rasterised and bilinearly
          // resampled — sampling at a layer edge pulls in transparent from
          // outside and eats a sliver off the bottom cards for the length of the
          // transition. Slack means the sampled edge is padding, not a card.
          final cellH = ((h - (rows - 1) * 3) / rows).floorToDouble();

          final grid = GridView.builder(
            physics: const NeverScrollableScrollPhysics(),
            // Nothing to clip: never scrollable, and the rows are sized to fit
            // with slack. No clip = no edge to sample across.
            clipBehavior: Clip.none,
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

          // The opened day floats above the grid in the SAME coordinate space,
          // so its panel lines up with the cell it grew from. Painted for
          // _openIndex (held through the fold-away), not _expandedIndex.
          final exDayIndex = _openIndex - leadingSlots;
          final expanded = _openIndex >= 0 &&
                  exDayIndex >= 0 &&
                  exDayIndex < daysInMonth
              ? DateTime(
                  widget.viewMonth.year, widget.viewMonth.month, exDayIndex + 1)
              : null;

          return Stack(
            clipBehavior: Clip.none,
            children: [
              grid,
              if (expanded != null)
                AnimatedBuilder(
                  animation: _expand,
                  builder: (context, _) {
                    final t = _expand.value.clamp(0.0, 1.0);
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        // Click-away closes it. A whisper scrim lifts the panel
                        // off the grid — it fades with the same curve, so open
                        // and close feel like one gesture.
                        Positioned.fill(
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: _collapse,
                            child: ColoredBox(
                                color:
                                    Colors.black.withValues(alpha: 0.28 * t)),
                          ),
                        ),
                        _expandedDayLayer(expanded, _openIndex, leadingSlots,
                            cellW, cellH, h, t),
                      ],
                    );
                  },
                ),
            ],
          );
        }),
    );
  }

  /// The floating "opened day": the whole day's tasks, each draggable, anchored
  /// to the cell it grew from and kept fully on-screen. Purely a reach-in
  /// affordance — grabbing a card folds it away (see [_onDragPhase]).
  Widget _expandedDayLayer(DateTime date, int gridIndex, int leadingSlots,
      double cellW, double cellH, double gridH, double t) {
    final col = gridIndex % 7;
    final row = gridIndex ~/ 7;
    final left = col * (cellW + 3);
    final top = row * (cellH + 3);

    return ValueListenableBuilder<List<RustTask>>(
      valueListenable: widget.taskState!
          .tasksForDateNotifier(date.millisecondsSinceEpoch),
      builder: (context, dayTasks, _) {
        final allocated = dayTasks.where((t) => t.startTime != null).toList()
          ..sort((a, b) => (a.startTime ?? 0).compareTo(b.startTime ?? 0));
        final unallocated = TaskState.orderUnallocated(
            dayTasks.where((t) => t.startTime == null).toList());

        // Grouped and labelled — timed under SCHEDULED (each carries its 09:30),
        // untimed under ANYTIME. No count: the opened day shows everything, so a
        // denominator is just noise (and, per the compass, a whiff of debt).
        final rows = <Widget>[];
        var sections = 0;
        if (allocated.isNotEmpty) {
          rows.add(const _ExpandedSectionLabel('SCHEDULED'));
          rows.addAll(allocated.map((t) => _dragCard(t, date)));
          sections++;
        }
        if (unallocated.isNotEmpty) {
          rows.add(const _ExpandedSectionLabel('ANYTIME'));
          rows.addAll(unallocated.map((t) => _dragCard(t, date)));
          sections++;
        }
        final taskCount = allocated.length + unallocated.length;

        // Height from content, floored to the cell and capped to the grid so it
        // never runs off; if the day is long the list scrolls inside.
        const headerH = 30.0, rowH = 30.0, labelH = 22.0, vPad = 14.0;
        final desired =
            headerH + taskCount * rowH + sections * labelH + vPad;
        final maxH = gridH - 8;
        final panelH = desired.clamp(cellH, maxH).toDouble();
        // Prefer to grow down from the cell; near the bottom it shifts up to
        // stay on-screen, floating over the rows above.
        final panelTop = top.clamp(0.0, (gridH - panelH).clamp(0.0, gridH));

        // Grows from the cell's top edge with a soft settle, driven by the
        // shared open/close controller so the fold-away runs in reverse.
        return Positioned(
          left: left,
          top: panelTop,
          width: cellW,
          height: panelH,
          child: Opacity(
            opacity: t,
            child: Transform.scale(
              scale: 0.94 + 0.06 * t,
              alignment: Alignment.topCenter,
              // §7: filterQuality non-null WHILE scaling, null at rest, or the
              // titles hop a pixel on the last frame.
              filterQuality: t < 1.0 ? FilterQuality.low : null,
              child: _ExpandedDayCard(date: date, rows: rows),
            ),
          ),
        );
      },
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

  /// One draggable task row — the same in a cell and in an opened day, so a card
  /// lifted from either behaves identically. KEY by task id: without it the
  /// Column reconciles by POSITION, so deleting the top of two made the survivor
  /// reuse the deleted card's dying element and vanish until a full rebuild.
  Widget _dragCard(RustTask task, DateTime date) => Padding(
        key: ValueKey('m-${task.id}'),
        padding: const EdgeInsets.only(bottom: 2),
        child: DragSource(
          task: task,
          kind: DragSourceKind.dayCellCard,
          sourceDay: date,
          sourceInsets: const EdgeInsets.only(bottom: 4),
          child: HoverTaskCard(
            task: task,
            compact: true,
            enablePeek: false,
            onTap: () {
              widget.onToggleTask?.call(task);
              setState(() {});
            },
            onDelete: () => widget.taskState?.deleteTask(task),
            onEditTitle: (val) =>
                widget.taskState?.updateTask(task.copyWith(title: val)),
          ),
        ),
      );

  /// The month cell's task area: the rows (timed → divider → untimed) stepping
  /// aside for the "Anytime" rail, with «+N more» floated into the bottom-right
  /// corner as a button — an overlay, so it costs no row and two cards stay
  /// whole. It stays a SettleAnchor, so a drop that sorts below the cap still
  /// dissolves into it.
  Widget _buildMonthTaskList(List<RustTask> dayTasks, DateTime date,
      GlobalKey dividerKey, int gridIndex, double availH,
      ValueListenable<double> railInset) {
    return ValueListenableBuilder<DropHover?>(
      valueListenable: DragSession.instance.hover,
      builder: (context, _, _) {
        return ValueListenableBuilder<Set<String>>(
          valueListenable: DeleteSettle.deleting,
          builder: (context, dying, _) {
            final (cards, hiddenCount) =
                _monthTaskColumn(dayTasks, date, dividerKey, dying, availH);
            return Stack(
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(
                  child: ClipRect(
                    // Bottom rows slide under this clip; the corner button is
                    // OUTSIDE it, so it is never the thing that gets cut.
                    child: ValueListenableBuilder<double>(
                      valueListenable: railInset,
                      builder: (_, inset, child) => TweenAnimationBuilder<double>(
                        tween: Tween<double>(end: inset),
                        duration: const Duration(milliseconds: 180),
                        curve: Curves.easeOutCubic,
                        builder: (_, v, c) =>
                            Transform.translate(offset: Offset(0, v), child: c),
                        child: child,
                      ),
                      child: SingleChildScrollView(
                        physics: const NeverScrollableScrollPhysics(),
                        child: cards,
                      ),
                    ),
                  ),
                ),
                Positioned(
                  right: 2,
                  bottom: 1,
                  child: IgnorePointer(
                    ignoring: hiddenCount == 0,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 160),
                      curve: Curves.easeOut,
                      opacity: hiddenCount > 0 ? 1.0 : 0.0,
                      child: hiddenCount > 0
                          ? SettleAnchor(
                              id: DragCardRegistry.pileId(date),
                              child: _MoreChip(
                                count: hiddenCount,
                                onTap: () => _setExpanded(gridIndex),
                              ),
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  (Widget, int) _monthTaskColumn(List<RustTask> dayTasks, DateTime date,
      GlobalKey dividerKey, Set<String> dying, double availH) {
        final preview = DropFuture.forDate(date);
        // Keep the dragged card in the list (it dims + restores itself and stays
        // in DragCardRegistry so the flight lands on it). Splice the honey
        // preview in ONLY for a cross-day drop, where the task isn't here yet.
        final showPreview = preview != null &&
            !dayTasks.any((t) => t.id == preview.projected.id);

        // Append the incoming card FIRST, then order the whole lot with the
        // same function the list uses after the drop — inserting it at 0 showed
        // it above a «!!» task and then dropped it below, a preview promising a
        // place the drop would not honour.
        final rawUntimed =
            dayTasks.where((t) => t.startTime == null).toList();
        final allocated = dayTasks.where((t) => t.startTime != null).toList();

        if (showPreview) {
          if (preview.keepsTime) {
            allocated.add(preview.projected);
          } else {
            rawUntimed.add(preview.projected);
          }
        }
        allocated.sort((a, b) => (a.startTime ?? 0).compareTo(b.startTime ?? 0));
        final unallocated = TaskState.orderUnallocated(rawUntimed);
        // A collapsing row is already gone for CAPACITY — that is what promotes
        // the next card DURING the collapse instead of popping it in after, and
        // it is what stops «+N more» from sitting for a beat in the slot the
        // promoted card is about to take.
        bool isDying(RustTask t) => dying.contains(t.id);
        final dyingHere = [...allocated, ...unallocated].where(isDying).length;
        final total = unallocated.length + allocated.length - dyingHere;

        // «+N more» is a CORNER OVERLAY now, not a row — so it costs no height
        // and the cards keep the full area. Always show at least TWO (what the
        // cell always showed before it started measuring — the last may clip a
        // few px at the floor, exactly as before), and MORE where a taller cell
        // has room. The divider between groups eats one slot when both show.
        const rowH = 38.0, dividerH = 13.0;
        final bothGroups = unallocated.isNotEmpty && allocated.isNotEmpty;
        final floor2 = total < 2 ? total : 2;
        var fit = ((availH - (bothGroups ? dividerH : 0)) / rowH)
            .floor()
            .clamp(floor2, total == 0 ? 0 : total);
        // The incoming card must always be visible during a drag.
        if (showPreview) fit = (fit + 1).clamp(0, total);
        final cap = fit;

        bool isPreview(RustTask t) =>
            showPreview && identical(t, preview.projected);

        Widget emit(RustTask t) => isPreview(t)
            ? preview!.card(margin: const EdgeInsets.only(bottom: 2))
            : _dragCard(t, date);

        final items = <Widget>[];
        var count = 0;
        for (final t in allocated) {
          if (isDying(t)) {
            items.add(emit(t)); // collapsing — costs no slot
            continue;
          }
          if (count >= cap) break;
          items.add(emit(t));
          count++;
        }
        if (unallocated.isNotEmpty && allocated.isNotEmpty && count < cap) {
          items.add(KeyedSubtree(
              key: dividerKey, child: const _PremiumMiniDivider()));
        }
        for (final t in unallocated) {
          if (isDying(t)) {
            items.add(emit(t));
            continue;
          }
          if (count >= cap) break;
          items.add(emit(t));
          count++;
        }
        final hiddenCount = total - count;

        // AnimatedSize: the promoted card GLIDES into the freed slot instead of
        // snapping (manifest §7 — collapse + fade, the rest pulls up smoothly).
        // Cards ONLY — «+N more» is placed by the caller as a corner overlay.
        final cards = AnimatedSize(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: items,
          ),
        );
        return (cards, hiddenCount);
  }

  Widget _buildDayCell(int gridIndex, int day, DateTime date, bool isToday,
      bool isPast, List<RustTask> dayTasks) {
    final isHovered =
        _hoveredIndex == gridIndex && !DragSession.hoverSuppressed;
    final totalTasks = dayTasks.length;
    final completedTasks = dayTasks.where((t) => t.isCompleted).length;
    final dayOpacity = isPast && !isToday ? 0.45 : 1.0;
    // Month is an OVERVIEW — no hover peek (a floating "second day" read as
    // clutter). To see/act on a full day, click it → zoom in.
    return DayCellDropTarget(
      date: date,
      taskState: widget.taskState,
      // The head is a fixed height (day number + the always-reserved dots row),
      // so this lands the rail's top EXACTLY on the task list's top: 10 + 15
      // (number) + 4 + 3 (dots slot) + 4 = 36. One number, honest on every day.
      settleTopOffset: 36,
      settleHeight: 24,
      // Shorter rail — a month cell is ~90px wide. It overlays the «+N more»
      // line, which means nothing mid-drag anyway.
      railHeight: 15,
      highlightRadius: BorderRadius.circular(AppTheme.radiusXLarge),
      builder: (dividerKey, railInset) => MouseRegion(
      onEnter: (_) {
        // ALWAYS record it, even mid-drag: discarding the enter here is why the
        // cell stayed dead after a drop — the pointer never left, so no second
        // enter ever came. Only the PAINT is suppressed (isHovered below).
        setState(() => _hoveredIndex = gridIndex);
        if (!DragSession.hoverSuppressed) widget.onDayHover?.call(date);
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
                        // Completion dots — the slot is ALWAYS reserved, empty
                        // day or not. The "Anytime" rail hangs off a constant
                        // offset from the cell's top (settleTopOffset), so a
                        // head that shrank by these 7px on an empty day landed
                        // the rail inside the card list. Same law as the week's
                        // progress ring: the day's head is a FIXED height.
                        const SizedBox(height: 4),
                        SizedBox(
                          height: 3,
                          child: IgnorePointer(
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
                        ),

                        // Phase 5: Task list
                        if (showTitles) ...[
                          const SizedBox(height: 4),
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 5),
                              // Measure the real room so the card cap fits it —
                              // «+N more» is a corner overlay inside, costing no
                              // row, so two cards stay whole even on short cells.
                              child: LayoutBuilder(
                                builder: (context, listBox) => _buildMonthTaskList(
                                    dayTasks,
                                    date,
                                    dividerKey,
                                    gridIndex,
                                    listBox.maxHeight,
                                    railInset),
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

// ═══════════════════════════════════════════════════════════════════════════
// EXPANDED DAY — the whole day, lifted off the grid so a hidden task is reachable
// ═══════════════════════════════════════════════════════════════════════════
class _ExpandedDayCard extends StatelessWidget {
  final DateTime date;
  final List<Widget> rows;
  const _ExpandedDayCard({required this.date, required this.rows});

  static const _weekdays = [
    'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN' //
  ];

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppTheme.radiusXLarge),
        // Opaque, a touch above the cell's own fill, so the rows beneath never
        // read through it.
        color: const Color(0xFF20232C),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 9, 6, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 5, bottom: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    '${date.day}',
                    style: const TextStyle(
                      fontFamily: 'InterTight',
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      height: 1.0,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _weekdays[date.weekday - 1],
                    style: TextStyle(
                      fontFamily: 'Inter',
                      fontSize: 8.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 1.0,
                      color: Colors.white.withValues(alpha: 0.30),
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: rows,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The «+N more» pile as a button. It reads as clickable on hover — a brighter
/// label on a soft pill — without a cursor change (manifest §7: the cursor stays
/// basic everywhere; the affordance is visual). Its own tap opens the day.
class _MoreChip extends StatefulWidget {
  final int count;
  final VoidCallback onTap;
  const _MoreChip({required this.count, required this.onTap});

  @override
  State<_MoreChip> createState() => _MoreChipState();
}

class _MoreChipState extends State<_MoreChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(7),
            // A dark pill cuts the chip out from the card corner it floats over,
            // so the count stays legible; hover lifts it a touch further.
            color: Colors.black.withValues(alpha: _hover ? 0.55 : 0.35),
            border: Border.all(
              color: Colors.white.withValues(alpha: _hover ? 0.20 : 0.08),
              width: 0.5,
            ),
          ),
          child: Text(
            '+${widget.count} more',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 8.5,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: _hover ? 0.85 : 0.45),
            ),
          ),
        ),
      ),
    );
  }
}

/// SCHEDULED / ANYTIME header inside the opened day — the day view's vocabulary,
/// so the whole app names the two groups the same way.
class _ExpandedSectionLabel extends StatelessWidget {
  final String label;
  const _ExpandedSectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 3, top: 8, bottom: 3),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'Inter',
          fontSize: 8.5,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
          color: Colors.white.withValues(alpha: 0.30),
        ),
      ),
    );
  }
}
