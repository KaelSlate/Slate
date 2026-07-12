/// SLATE — True Spatial Hierarchy (Phase 3.0)
/// 3-Level Z-Axis Depth: day → weekTactics | monthGrid
///
/// The three physical depths of the Staircase navigation.
/// Year is gone. Day+Flow are unified into a single level.
enum StaircaseLevel {
  /// Level 3: Traditional Calendar Grid of the month's days
  monthGrid,

  /// Level 2: 7 Vertical Day Cards side-by-side (default hub)
  weekTactics,

  /// Level 1: Unified dual-pane Day view (task list + 24h ribbon)
  day,
}

/// Global navigation state (simple, static)
class StaircaseState {
  static StaircaseLevel currentLevel = StaircaseLevel.weekTactics;
  static DateTime selectedDate = DateTime.now();

  // Persistent toggle routing preference
  static bool isWeekPreference = true;

  /// True while the day-view command pill (add-task input) is open. Global key
  /// handlers (pulse_layer Esc / nav) check this so the pill stays fully modal
  /// even if its text field momentarily loses focus.
  static bool isComposingTask = false;

  /// True while a timeline block edge-resize is in flight. Esc then cancels
  /// the resize (handled by the block itself) — pulse_layer must not zoom out,
  /// and Ctrl+wheel zoom must not remount the day view under the gesture.
  static bool isResizingBlock = false;

  // ── First-run experience ────────────────────────────────────────────────
  /// True until the user's first successful capture. Governs the gentle
  /// console invite / empty-state hints. Persisted as 'slate_onboarded'.
  static bool isFirstRun = false;

  /// True until the welcome greeting overlay has been seen once. Separate from
  /// [isFirstRun]: the big greeting shows ONLY once, while the lighter invite
  /// persists until first capture. Persisted as 'slate_welcomed'.
  static bool showWelcome = false;

  /// True only while the welcome overlay is actually on screen. The other global
  /// key handlers (pulse_layer nav, day_flow_view 'C') stand down while this is
  /// set, so the FIRST keypress cleanly dismisses the welcome with no side
  /// effect (no view-toggle, no double-open).
  static bool isWelcoming = false;

  /// True while the startup warmup veil is up (shader pre-render). Global key
  /// handlers stand down so keys can't act on the invisible warming surfaces.
  static bool isWarmingUp = false;

  /// Navigate to a specific day (enters unified day level)
  static void enterDay(DateTime date) {
    selectedDate = DateTime(date.year, date.month, date.day);
    currentLevel = StaircaseLevel.day;
  }

  /// Zoom in one level (Ctrl+ScrollUp): month|week → day
  static bool zoomIn() {
    switch (currentLevel) {
      case StaircaseLevel.monthGrid:
        currentLevel = StaircaseLevel.day;
        return true;
      case StaircaseLevel.weekTactics:
        currentLevel = StaircaseLevel.day;
        return true;
      case StaircaseLevel.day:
        return false; // Already at deepest level
    }
  }

  /// Zoom out one level (Ctrl+ScrollDown): day → week|month
  static bool zoomOut() {
    switch (currentLevel) {
      case StaircaseLevel.monthGrid:
      case StaircaseLevel.weekTactics:
        return false; // Already at highest level
      case StaircaseLevel.day:
        currentLevel =
            isWeekPreference ? StaircaseLevel.weekTactics : StaircaseLevel.monthGrid;
        return true;
    }
  }

  /// Get level name for display
  static String get levelName {
    switch (currentLevel) {
      case StaircaseLevel.monthGrid:
        return 'MONTH';
      case StaircaseLevel.weekTactics:
        return 'WEEK';
      case StaircaseLevel.day:
        return 'DAY';
    }
  }
}
