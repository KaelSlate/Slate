import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/state/local_prefs.dart';
import '../../core/theme/app_theme.dart';

import '../../core/engine/quick_capture_controller.dart';
import '../../core/engine/spatial_zoom_engine.dart';
import '../../core/interaction/drag_session.dart';
import '../../core/state/first_run.dart';
import '../../core/state/task_state.dart';
import '../../core/state/toast_bus.dart';
// year_strategy_view.dart removed — Phase 3 3-layer hierarchy
import '../views/month_grid_view.dart';
import '../views/week_tactics_view.dart' show WeekTacticsView, WeekTacticsViewState;
import '../views/day_flow_view.dart';
import '../overlays/drag_preview_layer.dart';
import '../overlays/task_peek_layer.dart';
import '../overlays/inbox_drawer.dart';
import '../overlays/welcome_overlay.dart';
import '../warmup/warmup_layer.dart';
import '../widgets/slate_toast.dart';

/// Slate — Pulse Layer
/// Minimal header: SLATE + level + New + Settings.
/// Ctrl+Scroll = zoom switch. Standard scroll otherwise.

import 'package:flutter_riverpod/flutter_riverpod.dart';

class PulseLayer extends ConsumerStatefulWidget {
  const PulseLayer({super.key});
  @override
  ConsumerState<PulseLayer> createState() => _PulseLayerState();
}

class _PulseLayerState extends ConsumerState<PulseLayer> with TickerProviderStateMixin {
  final FocusNode _focusNode = FocusNode();
  final ValueNotifier<DateTime?> _jumpToDateNotifier = ValueNotifier(null);

  // Fix 3: GlobalKey to reach WeekTacticsViewState for hover-based zoom targeting.
  // A fresh key is generated every time we *enter* weekTactics, so the AnimatedSwitcher
  // outgoing child never shares the same GlobalKey as the incoming child.
  GlobalKey<WeekTacticsViewState> _weekTacticsKey = GlobalKey<WeekTacticsViewState>();

  DateTime _lastZoomTime = DateTime.fromMillisecondsSinceEpoch(0);

  // Inbox drawer controller
  late AnimationController _inboxCtrl;
  bool _inboxOpen = false;

  /// First-run welcome overlay lives until its arc completes or Esc/click
  /// hides it for the session. Read from the static ONCE per mount so a
  /// mid-confirm rebuild can't yank the overlay out from under its own fade.
  bool _welcomeActive = false;

  // ── Startup warmup (see warmup_layer.dart) ───────────────────────────────
  // veiled: branded veil up, engine still loading. warming: heavy surfaces
  // render beneath the veil for a few frames (shader compile). revealing:
  // warmup children removed, veil fading. done: layer gone.
  _WarmupPhase _warmupPhase = _WarmupPhase.veiled;
  /// Process-wide: shaders warmed already (survives remounts via root swap).
  static bool _warmedOnce = false;
  Timer? _warmupWatchdog;

  /// Cached reference so InboxDrawer can call mutations directly.
  TaskState? _taskState;

  // ── Phase 4 additions ────────────────────────────────────────────────────
  /// The day the mouse is hovering over (Month or Week view). Null = empty space.
  DateTime? _hoveredDate;

  // Phase 4.1: Removed _keyboardCursorDate — no more visual cursor highlight.
  // Phase 4.1: Added month-scroll notifier — Up/Down in month view fires this.
  /// When incremented (+1 = forward, -1 = backward), MonthGridView snaps one month.
  final ValueNotifier<int> _monthScrollDelta = ValueNotifier(0);

  /// When incremented, DayFlowView auto-opens its inline add-task field.
  final ValueNotifier<int> _autoFocusAddNotifier = ValueNotifier(0);

  // ── Anchored depth-zoom (staircase view switch) ──────────────────────────
  // The view switch is a directional Z-depth zoom, anchored at the tapped day.
  // These drive the custom transitionBuilder live (read each frame).
  /// true = zooming INTO a deeper level (toward day); false = zooming OUT.
  bool _zoomForward = true;
  /// true = the current transition is the lateral WEEK↔MONTH toggle (fade-through),
  /// not a day depth-zoom.
  bool _isLateralSwitch = false;
  /// Scale pivot for the current transition — the tapped/hovered day's position
  /// on screen (Alignment(-1..1)). Falls back to center for keyboard/lateral nav.
  Alignment _zoomPivot = Alignment.center;
  /// The level rendered on the previous build — to derive zoom direction from
  /// the level ordinal change (month=0 → week=1 → day=2).
  StaircaseLevel? _prevRenderedLevel;
  /// Last pointer-down position (global). A tap's pointer-down precedes its
  /// onTap, so this is the tapped day cell when onDayTap fires → zoom origin.
  Offset _lastPointerDownGlobal = Offset.zero;
  /// Wraps the AnimatedSwitcher so we can map a global point → local Alignment.
  final GlobalKey _switcherKey = GlobalKey();

  /// Convert a global screen point to an Alignment inside the switcher box.
  Alignment _pivotFromGlobal(Offset g) {
    final box = _switcherKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return Alignment.center;
    final p = box.globalToLocal(g);
    return Alignment(
      ((p.dx / box.size.width) * 2 - 1).clamp(-1.0, 1.0),
      ((p.dy / box.size.height) * 2 - 1).clamp(-1.0, 1.0),
    );
  }

  // Depth-zoom tuning — one place to tweak the feel.
  static const Duration _zoomDuration = Duration(milliseconds: 360);
  static const double _zoomEnterFrom = 0.92; // incoming starts here (zoom-in)
  static const double _zoomExitTo = 1.08;    // outgoing ends here (zoom-in)
  static const double _zoomFadeInStart = 0.35; // incoming opacity ramps from here
  static const double _zoomFadeOutEnd = 0.45;  // outgoing gone by this exit progress

  @override
  void initState() {
    super.initState();
    _inboxCtrl = AnimationController(
      // Unified drawer (#I): the whole panel slides in from the right edge as
      // one piece (see inbox_drawer.dart). Open glides 420ms (easeOutQuint),
      // close exits 320ms (easeInCubic) — decisive but not abrupt.
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 320),
      vsync: this,
    );
    HardwareKeyboard.instance.addHandler(_globalKeyHandler);
    _welcomeActive = StaircaseState.showWelcome;

    // Shaders warm once per process. On remounts (e.g. returning from the
    // global quick-capture overlay) skip the veil entirely — no re-warm flash.
    if (_warmedOnce) {
      _warmupPhase = _WarmupPhase.done;
    } else {
      StaircaseState.isWarmingUp = true;
      // Watchdog: if the engine (or frame pump) ever stalls, reveal anyway —
      // the veil must never be able to strand the user.
      _warmupWatchdog = Timer(const Duration(milliseconds: 4000), _beginReveal);
    }
  }

  /// Pump exactly three painted frames of the warmup stage, then reveal.
  /// Post-frame fires after scene submission (raster follows), so three
  /// scheduled frames guarantee the shaders actually compiled.
  void _scheduleWarmupFrames() {
    int n = 0;
    void tick(Duration _) {
      if (!mounted) return;
      if (++n >= 3) {
        _beginReveal();
        return;
      }
      WidgetsBinding.instance.addPostFrameCallback(tick);
      WidgetsBinding.instance.scheduleFrame();
    }

    WidgetsBinding.instance.addPostFrameCallback(tick);
    WidgetsBinding.instance.scheduleFrame();
  }

  /// Drop the warmup children FIRST, then fade the veil — nothing with a live
  /// BackdropFilter may sit beneath the animating opacity (flicker gotcha).
  void _beginReveal() {
    _warmupWatchdog?.cancel();
    if (!mounted ||
        _warmupPhase == _WarmupPhase.revealing ||
        _warmupPhase == _WarmupPhase.done) {
      return;
    }
    setState(() => _warmupPhase = _WarmupPhase.revealing);
  }

  void _finishWarmup() {
    StaircaseState.isWarmingUp = false;
    _warmedOnce = true;
    if (mounted) setState(() => _warmupPhase = _WarmupPhase.done);
  }

  /// Global key handler — registered directly on HardwareKeyboard, bypassing
  /// the Flutter Focus tree. Guard: do NOT intercept 'I' when a text field is
  /// focused (the user may be typing). Only intercept when no text input is active.
  /// Bulletproof text-field check — covers TextField, TextFormField, and any
  /// widget that hosts an EditableText, regardless of focus node hierarchy.
  bool _isTextFieldFocused() {
    final primaryFocus = FocusManager.instance.primaryFocus;
    if (primaryFocus == null) return false;
    final ctx = primaryFocus.context;
    if (ctx == null) return false;
    // EditableTextState is the canonical indicator that a text input is active.
    return ctx.findAncestorStateOfType<EditableTextState>() != null;
  }

  bool _globalKeyHandler(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // While the welcome overlay is showing it owns every key — the first one
    // dismisses it. Stand down so a stray key can't toggle views behind it.
    if (StaircaseState.isWelcoming) return false;

    // Warmup veil is up — keys must not act on the invisible warming surfaces.
    if (StaircaseState.isWarmingUp) return false;

    // Drag in flight: Esc cancels, every other shortcut is swallowed — the
    // view must never swap or zoom under a live drag.
    if (DragSession.instance.isActive) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        DragSession.instance.cancel();
      }
      return true;
    }

    // While the day-view command pill is open it is fully modal: stand down so
    // every key flows to its text field and only day_flow_view handles C/Esc.
    // (Robust even if the field momentarily loses focus.)
    if (StaircaseState.isComposingTask) return false;

    final noModifiers = !HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isMetaPressed &&
        !HardwareKeyboard.instance.isAltPressed;

    // ── Ctrl+Z — undo the last checkbox toggle / delete ────────────────────
    // (Shift left free for a future redo; text fields keep their own Ctrl+Z.)
    if (event.logicalKey == LogicalKeyboardKey.keyZ &&
        HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isShiftPressed) {
      if (_isTextFieldFocused()) return false;
      final undone = _taskState?.undoLast();
      SlateToasts.instance.show(
        undone != null ? 'Undone' : 'Nothing to undo',
        detail: undone,
        icon: Icons.undo_rounded,
      );
      return true;
    }

    // ── 'C' — capture from WEEK/MONTH too (day view opens its own pill) ──
    // Same summon as the global hotkey, so the "C — capture" hint is honest
    // on every view, not only inside a day.
    if (event.logicalKey == LogicalKeyboardKey.keyC && noModifiers) {
      if (_isTextFieldFocused()) return false;
      if (StaircaseState.currentLevel == StaircaseLevel.day) return false;
      QuickCaptureController.instance.summon();
      return true;
    }

    // ── 'I' — Inbox toggle ────────────────────────────────────────────────
    if (event.logicalKey == LogicalKeyboardKey.keyI && noModifiers) {
      if (_isTextFieldFocused()) return false;
      _toggleInbox();
      return true;
    }

    // ── 'V' — Toggle WEEK ↔ MONTH view ──────────────────────────────────────
    if (event.logicalKey == LogicalKeyboardKey.keyV && noModifiers) {
      if (_isTextFieldFocused()) return false;
      // Lateral WEEK↔MONTH switch → neutral centered zoom (no day origin).
      _zoomPivot = Alignment.center;
      if (mounted) setState(() {
        final level = StaircaseState.currentLevel;
        if (level == StaircaseLevel.monthGrid) {
          StaircaseState.currentLevel = StaircaseLevel.weekTactics;
          // Bug 2 fix: fresh key when entering weekTactics
          _weekTacticsKey = GlobalKey<WeekTacticsViewState>();
        } else if (level == StaircaseLevel.weekTactics) {
          StaircaseState.currentLevel = StaircaseLevel.monthGrid;
        }
        // 'V' is a no-op when in Day view — user must Esc back first.
      });
      return true;
    }

    // ── Arrow Keys — Spatial canvas scrolling ────────────────────────────────
    if (noModifiers && !_isTextFieldFocused()) {
      final level = StaircaseState.currentLevel;

      // MONTH view: Left/Right move selected date ±1 day (for Ctrl+Scroll target);
      // Up/Down snap to prev/next month.
      if (level == StaircaseLevel.monthGrid) {
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _monthScrollDelta.value += 1;  // forward one month
          return true;
        } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _monthScrollDelta.value -= 1;  // back one month
          return true;
        }
        // Left/Right: nudge hover target without visual cursor
        return false;
      }

      // WEEK view: Up/Down navigate to prev/next week via existing page animation.
      if (level == StaircaseLevel.weekTactics) {
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          final base = StaircaseState.selectedDate; // non-nullable static
          final next = DateTime(base.year, base.month, base.day + 7);
          StaircaseState.selectedDate = next;
          _jumpToDateNotifier.value = next;
          return true;
        } else if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          final base = StaircaseState.selectedDate;
          final next = DateTime(base.year, base.month, base.day - 7);
          StaircaseState.selectedDate = next;
          _jumpToDateNotifier.value = next;
          return true;
        }
        return false;
      }
    }

    // ── Esc — Priority: close inbox → unfocus text → zoom out ─────────────
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      // A block edge-resize owns Esc (cancels the resize in the block itself).
      if (StaircaseState.isResizingBlock) return false;
      if (_inboxOpen) {
        if (_isTextFieldFocused()) {
          FocusManager.instance.primaryFocus?.unfocus();
        }
        _toggleInbox();
        return true;
      }
      if (_isTextFieldFocused()) return false;
      if (mounted) setState(() {
        final wasDay = StaircaseState.currentLevel == StaircaseLevel.day;
        StaircaseState.zoomOut();
        // Bug 2 fix: zoomOut from day may land on weekTactics
        if (wasDay && StaircaseState.currentLevel == StaircaseLevel.weekTactics) {
          _weekTacticsKey = GlobalKey<WeekTacticsViewState>();
        }
      });
      return true;
    }

    return false;
  }

  void _toggleInbox() {
    _inboxOpen = !_inboxOpen;
    if (_inboxOpen) {
      _inboxCtrl.forward();
    } else {
      _inboxCtrl.reverse();
    }
    // Defer the heavy PulseLayer rebuild so the animation starts at 0ms instantly
    Future.microtask(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _warmupWatchdog?.cancel();
    StaircaseState.isWarmingUp = false;
    HardwareKeyboard.instance.removeHandler(_globalKeyHandler);
    _focusNode.dispose();
    _jumpToDateNotifier.dispose();
    _monthScrollDelta.dispose();
    _autoFocusAddNotifier.dispose();
    _inboxCtrl.dispose();
    super.dispose();
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      if (!HardwareKeyboard.instance.isControlPressed) return;
      if (DragSession.instance.isActive) return; // no zoom mid-drag
      if (StaircaseState.isResizingBlock) return; // no zoom mid-resize
      final now = DateTime.now();
      if (now.difference(_lastZoomTime).inMilliseconds < 200) return;
      _lastZoomTime = now;

      if (event.scrollDelta.dy < 0) {
        // Zooming IN — resolve the target date precisely + anchor the zoom at
        // the cursor so the day grows out from under the pointer. Zoom OUT keeps
        // the last pivot → the day collapses back into the same spot.
        _zoomPivot = _pivotFromGlobal(event.position);
        final n = DateTime.now();
        final today = DateTime(n.year, n.month, n.day);

        if (StaircaseState.currentLevel == StaircaseLevel.weekTactics) {
          // Seed today first; selectHoveredDay overrides if cursor is on a real column.
          StaircaseState.selectedDate = today;
          _weekTacticsKey.currentState?.selectHoveredDay(event.position);
        } else if (StaircaseState.currentLevel == StaircaseLevel.monthGrid) {
          // Phase 4: Use the tracked hovered date. Ghost/empty cells report null → today.
          StaircaseState.selectedDate = _hoveredDate ?? today;
        }
      }

      setState(() {
        final wasWeekTactics = StaircaseState.currentLevel == StaircaseLevel.weekTactics;
        if (event.scrollDelta.dy < 0) {
          StaircaseState.zoomIn();
        } else {
          StaircaseState.zoomOut();
        }
        // Bug 2 fix: if we just transitioned INTO weekTactics, mint a fresh key
        // so AnimatedSwitcher's outgoing widget never shares _weekTacticsKey.
        if (!wasWeekTactics && StaircaseState.currentLevel == StaircaseLevel.weekTactics) {
          _weekTacticsKey = GlobalKey<WeekTacticsViewState>();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // Derive zoom direction from the level ordinal change (month=0 → week=1 →
    // day=2). Deeper index = zooming IN. Also flag the WEEK↔MONTH toggle: it's a
    // LATERAL sibling switch (same days, different layout), NOT a depth zoom, so
    // it gets its own calmer fade-through instead of the day zoom.
    final lvl = StaircaseState.currentLevel;
    if (_prevRenderedLevel != null && lvl != _prevRenderedLevel) {
      _zoomForward = lvl.index > _prevRenderedLevel!.index;
      _isLateralSwitch = lvl != StaircaseLevel.day &&
          _prevRenderedLevel != StaircaseLevel.day;
      // No lifts while two views are mid-transition (stale rects, dying zones).
      DragSession.instance
          .suppressBeginsFor(_zoomDuration + const Duration(milliseconds: 80));
    }
    _prevRenderedLevel = lvl;

    // Engine ready → start the warmup pass beneath the veil (once). Rebuilds
    // exactly once per launch: `loaded` only ever flips false→true.
    final engineLoaded =
        ref.watch(taskStateProvider.select((t) => t.loaded));
    if (engineLoaded && _warmupPhase == _WarmupPhase.veiled) {
      _warmupPhase = _WarmupPhase.warming;
      _scheduleWarmupFrames();
    }

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        // Record the last pointer-down so a click into a day knows its origin
        // cell (pointer-down precedes the GestureDetector onTap) → zoom anchor.
        onPointerDown: (e) => _lastPointerDownGlobal = e.position,
        // Drag events route through THIS root Listener: it is on every pointer's
        // hit path, so a drag survives even if its source widget is disposed
        // mid-flight (receding drawer, page flip).
        onPointerMove: (e) {
          if (DragSession.instance.isActive) DragSession.instance.update(e.position);
        },
        onPointerUp: (e) {
          if (DragSession.instance.isActive) DragSession.instance.drop();
        },
        onPointerCancel: (e) {
          if (DragSession.instance.isActive) DragSession.instance.cancel();
        },
        child: Stack(
          children: [
            // ── RepaintBoundary isolates the calendar from drawer animation ──
            // The drawer's SlideTransition lives in the same Stack. Without this
            // boundary every drawer frame would invalidate the calendar's layer,
            // causing full-scene rasterization on every animation tick.
            RepaintBoundary(
              child: Container(
                color: AppTheme.background,
                child: Column(
                  children: [
                    _buildHeader(),
                    Expanded(
                      key: _switcherKey,
                      child: AnimatedSwitcher(
                        duration: _zoomDuration,
                        // Curves are applied by hand inside transitionBuilder — keep
                        // the driving animation linear so they're not double-applied.
                        switchInCurve: Curves.linear,
                        switchOutCurve: Curves.linear,
                        transitionBuilder: (child, animation) {
                          // Anchored directional depth-zoom (Apple depth-nav /
                          // shared-axis Z "scaled"). Everything is read LIVE per
                          // frame inside the AnimatedBuilder: `currentLevel` is a
                          // global and `child.key` is fixed, so "am I entering or
                          // leaving" is reliable every frame (unlike the old
                          // build-time isIncoming, which froze on the leaving child).
                          return AnimatedBuilder(
                            animation: animation,
                            child: child,
                            builder: (context, c) {
                              final entering =
                                  child.key == ValueKey(StaircaseState.currentLevel);
                              final t = animation.value; // enter 0→1, exit 1→0

                              // ── Lateral WEEK↔MONTH toggle: calm fade-through ──
                              // Same days, different layout → not a depth zoom. A
                              // gentle scale (0.97) + offset fade timing (incoming
                              // fades in late, outgoing fades out early) so the two
                              // dissimilar layouts never muddy each other. Centered.
                              if (_isLateralSwitch) {
                                // Etalon (#I): "quiet cross-dissolve + micro-depth".
                                // Pure opacity crossfade + a barely-there 0.985→1.0
                                // scale, centered, NO directional slide. Incoming
                                // resolves just past the midpoint, outgoing leaves
                                // early — so two dissimilar layouts never muddy.
                                double s, o;
                                if (entering) {
                                  s = 0.985 + 0.015 * Curves.easeOutCubic.transform(t);
                                  o = Curves.easeOut
                                      .transform(((t - 0.35) / 0.65).clamp(0.0, 1.0));
                                } else {
                                  final u = 1.0 - t;
                                  s = 1.0 - 0.015 * Curves.easeIn.transform(u);
                                  o = (1.0 - (u / 0.40)).clamp(0.0, 1.0);
                                }
                                return Opacity(
                                  opacity: o,
                                  child: Transform.scale(
                                    scale: s,
                                    alignment: Alignment.center,
                                    // Mid-flight: rasterise once at identity and
                                    // scale the RASTER (ImageFilter.matrix path in
                                    // RenderTransform) — glyphs never re-hint under
                                    // fractional scale, so text can't "hop" when the
                                    // paint path switches at exactly 1.0. At rest:
                                    // null → plain crisp direct paint (matters on
                                    // fractional-DPR displays). Same matrix, same
                                    // curves — only the rasterisation path changes.
                                    filterQuality:
                                        t < 1.0 ? FilterQuality.low : null,
                                    child: IgnorePointer(ignoring: !entering, child: c),
                                  ),
                                );
                              }

                              final forward = _zoomForward;
                              double scale, opacity;
                              if (entering) {
                                // Incoming swims up from depth, anchored at the day,
                                // and lands. Pure Transform.scale = PAINT scale (no
                                // re-layout): the whole view scales as one uniform
                                // unit. NO snapshot — the snapshot only froze PART of
                                // the view (the scrollable card content escaped it and
                                // scaled live), so card text drifted relative to the
                                // frozen labels and "redrew" at release. Scaling the
                                // live tree uniformly reads as one clean zoom.
                                final from = forward ? _zoomEnterFrom : _zoomExitTo;
                                scale =
                                    from + (1.0 - from) * Curves.easeOutCubic.transform(t);
                                opacity = Curves.easeOut.transform(
                                  ((t - _zoomFadeInStart) / (1.0 - _zoomFadeInStart))
                                      .clamp(0.0, 1.0),
                                );
                              } else {
                                // Outgoing recedes / flies past from the anchored
                                // pivot and fades out EARLY (gone by 45%) so it's
                                // never a pixel-aligned ghost.
                                final u = 1.0 - t; // exit progress 0→1
                                final to = forward ? _zoomExitTo : _zoomEnterFrom;
                                scale =
                                    1.0 + (to - 1.0) * Curves.easeIn.transform(u);
                                opacity = (1.0 - (u / _zoomFadeOutEnd)).clamp(0.0, 1.0);
                              }
                              return Opacity(
                                opacity: opacity,
                                child: Transform.scale(
                                  scale: scale,
                                  alignment: _zoomPivot, // emanate from the tapped day
                                  // Same raster-scaling as the lateral branch (see
                                  // comment there): kills the end-of-zoom text hop
                                  // AND the "card text drifts separately from cards"
                                  // on the timeline — the whole view flies as ONE
                                  // identity-hinted raster. Feel is untouched.
                                  filterQuality:
                                      t < 1.0 ? FilterQuality.low : null,
                                  child: IgnorePointer(
                                    ignoring: !entering,
                                    child: c,
                                  ),
                                ),
                              );
                            },
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(StaircaseState.currentLevel),
                          child: Consumer(
                            builder: (context, ref, _) {
                              // P4: watch ONLY the loaded flag. Watching the whole
                              // ChangeNotifier re-built the entire active view
                              // (week/month/day) on EVERY task mutation. All task
                              // data reaches widgets through the granular per-date
                              // ValueNotifiers + TaskState.mutationTick instead.
                              final loaded = ref.watch(
                                  taskStateProvider.select((t) => t.loaded));
                              final taskState = ref.read(taskStateProvider);
                              _taskState = taskState;
                              // Bug 1 fix: gate the spatial views behind engine-ready.
                              // Until Rust's TASK_STORE is hydrated, show a zero-cost
                              // loading indicator so generateWeekCells/generateMonthCells
                              // never query an empty store.
                              if (!loaded) {
                                return const Center(
                                  child: SizedBox(
                                    width: 18, height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      color: Color(0x33FFFFFF),
                                    ),
                                  ),
                                );
                              }
                              return _buildCurrentLevel(taskState);
                            },
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Inbox drawer — highest Z-order, floats above everything
            if (_taskState != null)
              InboxDrawer(
                animationController: _inboxCtrl,
                onClose: _toggleInbox,
                taskState: _taskState!,
              ),
            // Lifted drag card — above the drawer's blur, below the warmup veil.
            const DragPreviewLayer(),
            // Hover-peek popover — full title / month-day list. IgnorePointer,
            // so it never steals hover. Above cards, below the warmup veil.
            const TaskPeekLayer(),
            // Quiet first-run chord hints (C / V / I) — ghost line, week/month
            // only (the day view teaches C in its own empty state). Gone
            // forever at the first capture.
            if (StaircaseState.currentLevel != StaircaseLevel.day)
              const _FirstRunHints(),
            // Calm self-dismissing toasts (undo etc.) — above the drawer.
            const SlateToastLayer(),
            // First-run welcome — teaches the one hotkey, confirms the first
            // capture, then never returns.
            if (_welcomeActive && _warmupPhase == _WarmupPhase.done)
              Positioned.fill(
                child: WelcomeOverlay(onGone: () {
                  StaircaseState.showWelcome = false;
                  if (mounted) setState(() => _welcomeActive = false);
                }),
              ),
            // ── Startup warmup: heavy surfaces render under an opaque veil ──
            if (_warmupPhase == _WarmupPhase.warming)
              Positioned.fill(
                child: WarmupStage(taskState: ref.read(taskStateProvider)),
              ),
            if (_warmupPhase != _WarmupPhase.done)
              Positioned.fill(
                child: WarmupVeil(
                  revealing: _warmupPhase == _WarmupPhase.revealing,
                  onRevealed: _finishWarmup,
                ),
              ),
          ],
        ),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // Esc and 'I' are both handled in _globalKeyHandler.
    // This Focus node is kept for autofocus / scroll capture only.
    return KeyEventResult.ignored;
  }

  Widget _buildCurrentLevel(TaskState taskState) {
    switch (StaircaseState.currentLevel) {
      case StaircaseLevel.monthGrid:
        return MonthGridView(
          core: taskState.core,
          taskState: taskState,
          focusDate: StaircaseState.selectedDate,
          scrollDeltaNotifier: _monthScrollDelta,
          onDayTap: (date) {
            // Anchor the zoom at the tapped cell (pointer-down precedes onTap).
            _zoomPivot = _pivotFromGlobal(_lastPointerDownGlobal);
            setState(() {
              StaircaseState.selectedDate = date;
              StaircaseState.currentLevel = StaircaseLevel.day;
            });
          },
          onDayHover: (date) => _hoveredDate = date,
        );
      case StaircaseLevel.weekTactics:
        return WeekTacticsView(
          key: _weekTacticsKey,
          core: taskState.core,
          taskState: taskState,
          jumpToDateNotifier: _jumpToDateNotifier,
          onDayTap: (date) {
            // Anchor the zoom at the tapped column (pointer-down precedes onTap).
            _zoomPivot = _pivotFromGlobal(_lastPointerDownGlobal);
            setState(() {
              StaircaseState.selectedDate = date;
              StaircaseState.currentLevel = StaircaseLevel.day;
            });
          },
          onDayHover: (date) => _hoveredDate = date,
          onToggleTask: taskState.toggleTask,
        );
      case StaircaseLevel.day:
        return DayFlowView(
          selectedDate: StaircaseState.selectedDate,
          core: taskState.core,
          taskState: taskState,
          onToggleTask: taskState.toggleTask,
          autoFocusAddNotifier: _autoFocusAddNotifier,
        );
    }
  }

  // ── HEADER — Frameless integrated title bar ─────────────────────

  Widget _buildHeader() {
    return Container(
      height: 48,
      decoration: const BoxDecoration(
        // Warm chrome tone from the same graphite ramp as the body — the old
        // neutral #0E0E0E read cooler/darker than the warm body and made the top
        // look like a separate strip (#5). A hairline separator keeps it defined.
        color: AppTheme.backgroundAlt,
        border: Border(
          bottom: BorderSide(color: Color(0x0DFFFFFF), width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // DragToMoveArea spans only the drag space, isolating buttons from event interception
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(child: DragToMoveArea(child: Container(color: Colors.transparent))),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // ← Back — only shown in Day view
                        if (StaircaseState.currentLevel == StaircaseLevel.day)
                          _headerBtn(Icons.arrow_back_rounded, onTap: () {
                            setState(() {
                              final wasDay = StaircaseState.currentLevel == StaircaseLevel.day;
                              StaircaseState.zoomOut();
                              // Bug 2 fix: zoomOut from day may land on weekTactics
                              if (wasDay && StaircaseState.currentLevel == StaircaseLevel.weekTactics) {
                                _weekTacticsKey = GlobalKey<WeekTacticsViewState>();
                              }
                            });
                          }, marginRight: 12),

                        // Brand
                        Text('SLATE', style: AppTheme.headlineMedium.copyWith(
                            fontWeight: FontWeight.w700, letterSpacing: 2.5, fontSize: 12,
                            color: Colors.white.withOpacity(0.4))),
                        const SizedBox(width: 12),

                        // Level pill
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            color: Colors.white.withOpacity(0.03),
                          ),
                          child: Text(StaircaseState.levelName, style: AppTheme.bodyMedium.copyWith(
                              color: Colors.grey[600], fontSize: 10, letterSpacing: 0.3)),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          
          // Interactions placed perfectly OUTSIDE DragToMoveArea for immediate 0ms response
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Inbox toggle
              _headerBtn(
                Icons.inbox_rounded,
                label: 'Inbox',
                onTap: _toggleInbox,
                marginRight: 10,
                isActive: _inboxOpen,
              ),

              // WEEK / MONTH toggle
              if (StaircaseState.currentLevel == StaircaseLevel.weekTactics ||
                  StaircaseState.currentLevel == StaircaseLevel.monthGrid)
                _buildViewToggle(),
              const SizedBox(width: 8),
            ],
          ),

          // Custom window controls — native size and position
          const _WindowControls(),
        ],
      ),
    );
  }


  Widget _buildViewToggle() {
    final isWeek = StaircaseState.currentLevel == StaircaseLevel.weekTactics;
    return Container(
      height: 28,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(7),
        color: Colors.white.withOpacity(0.04),
        border: Border.all(color: Colors.white.withOpacity(0.08), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _toggleSegment('WEEK', active: isWeek, onTap: () {
            if (!isWeek) {
              // Fire-and-forget prefs write (plain JSON) — the old awaited DPAPI
              // write added disk+decrypt latency to the view switch itself.
              LocalPrefs.instance.viewPref = 'week';
              StaircaseState.isWeekPreference = true;
              _zoomPivot = Alignment.center; // lateral switch → centered zoom
              setState(() {
                _weekTacticsKey = GlobalKey<WeekTacticsViewState>(); // Bug 2 fix
                StaircaseState.currentLevel = StaircaseLevel.weekTactics;
              });
            }
          }),
          Container(width: 0.5, height: 16, color: Colors.white.withOpacity(0.08)),
          _toggleSegment('MONTH', active: !isWeek, onTap: () {
            if (isWeek) {
              LocalPrefs.instance.viewPref = 'month';
              StaircaseState.isWeekPreference = false;
              _zoomPivot = Alignment.center; // lateral switch → centered zoom
              setState(() { StaircaseState.currentLevel = StaircaseLevel.monthGrid; });
            }
          }),
        ],
      ),
    );
  }

  Widget _toggleSegment(String label, {required bool active, required VoidCallback onTap}) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: active ? Colors.white.withOpacity(0.08) : Colors.transparent,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'Inter', fontSize: 10,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              letterSpacing: 0.5,
              color: active
                  ? Colors.white.withOpacity(0.75)
                  : Colors.white.withOpacity(0.28),
            ),
          ),
        ),
      ),
    );
  }

  Widget _headerBtn(IconData icon, {String? label, VoidCallback? onTap, double marginRight = 0, bool isActive = false}) {
    return Padding(
      padding: EdgeInsets.only(right: marginRight),
      child: MouseRegion(
        cursor: SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            padding: EdgeInsets.symmetric(horizontal: label != null ? 12 : 8, vertical: 7),
            decoration: BoxDecoration(
              color: isActive
                  ? Colors.white.withOpacity(0.08)
                  : Colors.white.withOpacity(0.03),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isActive
                    ? Colors.white.withOpacity(0.14)
                    : Colors.white.withOpacity(0.06),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.15),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: isActive ? Colors.white.withOpacity(0.7) : Colors.grey[400]),
                if (label != null) ...[
                  const SizedBox(width: 6),
                  Text(label, style: AppTheme.bodyMedium.copyWith(
                      color: isActive ? Colors.white.withOpacity(0.6) : Colors.grey[400],
                      fontSize: 11, fontWeight: FontWeight.w500,
                      letterSpacing: 0.2)),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

}

// ───────────────────────────────────────────────────────────────────────────────
// WINDOW CONTROLS — Minimize / Maximize / Close (macOS-inspired)
// ───────────────────────────────────────────────────────────────────────────────
class _WindowControls extends StatefulWidget {
  const _WindowControls();
  @override
  State<_WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<_WindowControls> with WindowListener {
  bool _minHover = false;
  bool _maxHover = false;
  bool _closeHover = false;
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _init();
  }

  void _init() async {
    _isMaximized = await windowManager.isMaximized();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _isMaximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _isMaximized = false);
  }

  @override
  Widget build(BuildContext context) {
    // Fitts's Law: Controls flush with top-right edge
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _btn(
          icon: Icons.minimize_rounded,
          hovered: _minHover,
          hoverColor: AppTheme.surfaceLight,
          iconColor: Colors.white.withOpacity(0.6),
          onEnter: (_) => setState(() => _minHover = true),
          onExit: (_) => setState(() => _minHover = false),
          onTap: () async => await windowManager.minimize(),
          isClose: false,
        ),
        _btn(
          icon: _isMaximized ? Icons.filter_none_rounded : Icons.crop_square_rounded,
          iconSize: _isMaximized ? 11 : 14,
          hovered: _maxHover,
          hoverColor: AppTheme.surfaceLight,
          iconColor: Colors.white.withOpacity(0.6),
          onEnter: (_) => setState(() => _maxHover = true),
          onExit: (_) => setState(() => _maxHover = false),
          onTap: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
          isClose: false,
        ),
        _btn(
          icon: Icons.close_rounded,
          hovered: _closeHover,
          hoverColor: const Color(0xFFE81123),
          iconColor: _closeHover ? Colors.white : Colors.white.withOpacity(0.6),
          onEnter: (_) => setState(() => _closeHover = true),
          onExit: (_) => setState(() => _closeHover = false),
          onTap: () async => await windowManager.close(),
          isClose: true,
        ),
      ],
    );
  }

  Widget _btn({
    required IconData icon,
    double iconSize = 14,
    required bool hovered,
    required Color hoverColor,
    required Color iconColor,
    required Function(PointerEnterEvent) onEnter,
    required Function(PointerExitEvent) onExit,
    required VoidCallback onTap,
    required bool isClose,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: onEnter,
      onExit: onExit,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 48,
          decoration: BoxDecoration(
            color: hovered ? hoverColor : Colors.transparent,
            // Native flush edges, no border radius to fit top right optimally
          ),
          child: Center(
            child: isClose
                ? Icon(icon, size: iconSize + 2, color: iconColor)
                : Icon(icon, size: iconSize, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// Startup warmup lifecycle (see WarmupStage/WarmupVeil in warmup_layer.dart).
enum _WarmupPhase { veiled, warming, revealing, done }

// ───────────────────────────────────────────────────────────────────────────────
// FIRST-RUN HINTS — one ghost line, bottom center, until the first capture.
// Empty-state guidance, not a tutorial: C / V / I as whisper chords.
// ───────────────────────────────────────────────────────────────────────────────
class _FirstRunHints extends StatelessWidget {
  const _FirstRunHints();

  @override
  Widget build(BuildContext context) {
    final vTarget = StaircaseState.currentLevel == StaircaseLevel.weekTactics
        ? 'month'
        : 'week';
    return Positioned(
      left: 0,
      right: 0,
      bottom: 16,
      child: ValueListenableBuilder<bool>(
        valueListenable: FirstRunController.instance.hintsActive,
        builder: (context, active, child) => IgnorePointer(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOut,
            opacity: active ? 1.0 : 0.0,
            child: child,
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _chord('C', 'capture'),
            _dot(),
            _chord('V', vTarget),
            _dot(),
            _chord('I', 'inbox'),
          ],
        ),
      ),
    );
  }

  Widget _chord(String key, String word) {
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: key,
          style: AppFonts.inter(
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            color: Colors.white.withValues(alpha: 0.30),
            letterSpacing: 0.5,
          ),
        ),
        TextSpan(
          text: '  $word',
          style: AppFonts.inter(
            fontSize: 10.5,
            color: Colors.white.withValues(alpha: 0.17),
            letterSpacing: 0.3,
          ),
        ),
      ]),
    );
  }

  Widget _dot() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Text('·',
          style: AppFonts.inter(
            fontSize: 10.5,
            color: Colors.white.withValues(alpha: 0.12),
          )),
    );
  }
}
