import 'package:flutter/widgets.dart';

import '../engine/slate_core_bridge.dart';
import '../state/lesson_state.dart';

/// Slate — global drag & drop core.
/// One static session (StaircaseState pattern). Pointer move/up route through
/// PulseLayer's ROOT Listener — never the source widget, which may be disposed
/// mid-drag (receding drawer, page flip). Zones are hit-tested by global rects,
/// not Flutter hit-testing, so overlays/scrims never block a drop.

enum DragSourceKind { inboxCard, planListCard, timelineBlock, dayCellCard }

enum DragPhase { idle, active, settling, springingBack }

class DragPayload {
  final RustTask task;
  final DragSourceKind kind;
  final Rect sourceGlobalRect;
  /// Pointer offset inside the source at lift — keeps the card glued to the
  /// exact grab point.
  final Offset grabOffset;
  final DateTime? sourceDay;

  const DragPayload({
    required this.task,
    required this.kind,
    required this.sourceGlobalRect,
    required this.grabOffset,
    this.sourceDay,
  });

  /// Duration to preserve on timeline drops; 60 min when the task has none.
  int get durationMinutes {
    final s = task.startTime;
    final e = task.endTime;
    if (s == null || e == null) return 60;
    return (e - s).clamp(15, 23 * 60);
  }
}

/// What the hovered zone wants shown. Compared by == so the notifier fires
/// only on real changes (snapped minute / zone id), never raw pixels.
@immutable
class DropHover {
  final String zoneId;
  final DateTime? targetDay;
  /// Timeline only: snapped minutes from the ribbon's zero-date midnight.
  final int? snappedMinutesFromZero;
  /// Timeline only: ribbon-local top of the lane the block will land in.
  final double? ghostTop;
  final String? badgeText;
  /// Split zones (day pane / day cells) for a TIMED payload:
  /// 'keep' = land with its time, 'clear' = drop the time. null = whole-zone.
  final String? cellMode;

  const DropHover({
    required this.zoneId,
    this.targetDay,
    this.snappedMinutesFromZero,
    this.ghostTop,
    this.badgeText,
    this.cellMode,
  });

  @override
  bool operator ==(Object other) =>
      other is DropHover &&
      other.zoneId == zoneId &&
      other.targetDay == targetDay &&
      other.snappedMinutesFromZero == snappedMinutesFromZero &&
      other.ghostTop == ghostTop &&
      other.badgeText == badgeText &&
      other.cellMode == cellMode;

  @override
  int get hashCode => Object.hash(
      zoneId, targetDay, snappedMinutesFromZero, ghostTop, badgeText, cellMode);
}

class DropResult {
  /// Where the preview settles (global). null → fade out in place.
  final Rect? settleGlobalRect;
  /// When true, the session waits one frame after the mutation and retargets
  /// the settle onto the REAL card the drop produced (pixel-perfect landing).
  final bool refineToCard;

  /// Where to land when the card ISN'T in the tree — it sorted below a cell's
  /// «+N more» cap. Flying to an estimated row then would animate to a place
  /// the card is not: it froze mid-cell and vanished. The pile is where the
  /// task genuinely went, so the preview dissolves INTO the «+N more» label.
  final String? settleFallbackId;

  const DropResult({
    this.settleGlobalRect,
    this.refineToCard = true,
    this.settleFallbackId,
  });
}

/// Live card-rect providers keyed by task id (fed by DragSource wrappers) —
/// lets a settling preview land on the exact card its drop created.
class DragCardRegistry {
  static final Map<String, List<Rect? Function()>> _providers = {};

  static void register(String taskId, Rect? Function() provider) {
    (_providers[taskId] ??= []).add(provider);
  }

  static void unregister(String taskId, Rect? Function() provider) {
    final list = _providers[taskId];
    if (list == null) return;
    list.remove(provider);
    if (list.isEmpty) _providers.remove(taskId);
  }

  /// Key for a cell's «+N more» pile — the landing place for a card that sorts
  /// below the cap and so never gets a row of its own.
  static String pileId(DateTime d) => 'pile-${d.year}-${d.month}-${d.day}';

  static Rect? rectFor(String taskId) {
    final list = _providers[taskId];
    if (list == null) return null;
    for (final p in list) {
      final r = p();
      if (r != null) return r;
    }
    return null;
  }
}

abstract class DropZone {
  String get id;

  /// Higher wins when rects overlap (ribbon 20 > planning pane 10 > cells 0).
  int get priority => 0;

  /// null while detached/unlaid — the zone is skipped.
  Rect? globalRect();

  bool canAccept(DragPayload payload) => true;

  /// What the preview un-morphs into when it lands here ('card' | 'block').
  String get landingChrome => 'card';

  DropHover? hoverAt(Offset globalPos, DragPayload payload);

  /// Commit the mutation. null → treated as a cancel (spring-back).
  DropResult? onDrop(Offset globalPos, DragPayload payload);
}

class DropZoneRegistry {
  final List<DropZone> _zones = [];

  void register(DropZone zone) {
    if (!_zones.contains(zone)) _zones.add(zone);
    DragSession.instance.scheduleHoverRefresh();
  }

  void unregister(DropZone zone) {
    _zones.remove(zone);
    DragSession.instance.scheduleHoverRefresh();
  }

  DropZone? hitTest(Offset globalPos, DragPayload payload) {
    DropZone? best;
    for (final z in _zones) {
      if (!z.canAccept(payload)) continue;
      final r = z.globalRect();
      if (r == null || !r.contains(globalPos)) continue;
      if (best == null || z.priority > best.priority) best = z;
    }
    return best;
  }
}

class DragSession extends ChangeNotifier {
  DragSession._();
  static final DragSession instance = DragSession._();

  DragPhase _phase = DragPhase.idle;
  DragPhase get phase => _phase;
  bool get isActive => _phase == DragPhase.active;

  /// While a drag is in flight, resting UI must stay quiet — cards/cells gate
  /// their MouseRegion onEnter on this so nothing "hovers" under the payload.
  static bool get hoverSuppressed => instance._phase != DragPhase.idle;

  DragPayload? _payload;
  DragPayload? get payload => _payload;

  Rect? _settleTarget;
  /// Global rect the preview animates to while settling / springing back.
  Rect? get settleTarget => _settleTarget;

  bool _retargetLive = false;
  /// Frame-fresh settle target: while the destination card is registered (and
  /// possibly still MOVING — a drawer sliding back, a list reflowing) the
  /// preview chases its live rect instead of a stale snapshot.
  Rect? get liveSettleTarget {
    if (_retargetLive) {
      final id = _payload?.task.id;
      if (id != null) {
        final live = DragCardRegistry.rectFor(id);
        if (live != null) return live;
      }
    }
    return _settleTarget;
  }

  /// Width of one card in the current overview, published by the day cells.
  /// The flight preview is carried at the size of what it BECOMES, not the size
  /// it came from — otherwise a wide inbox card flies wide and jolts on landing.
  double? _overviewCardWidth;
  double? get overviewCardWidth => _overviewCardWidth;
  void noteOverviewCardWidth(double w) => _overviewCardWidth = w;

  /// Chrome the preview un-morphs into while landing: 'block' after a ribbon
  /// drop, 'card' everywhere else.
  String _landingChrome = 'card';
  String get landingChrome => _landingChrome;

  /// Begin-suppression window (view zoom transitions). Timestamp — no timers.
  DateTime _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
  void suppressBeginsFor(Duration d) {
    final until = DateTime.now().add(d);
    if (until.isAfter(_suppressUntil)) _suppressUntil = until;
  }

  // High-frequency channels — ValueNotifiers only, so per-move updates repaint
  // just the preview layer / hovered zone, never the whole tree.
  final ValueNotifier<Offset> pointerGlobal = ValueNotifier(Offset.zero);
  final ValueNotifier<DropHover?> hover = ValueNotifier(null);
  /// Task suppressed at its resting place: dimmed while dragging, invisible
  /// while the preview settles into its new slot.
  final ValueNotifier<String?> hiddenTaskId = ValueNotifier(null);

  final DropZoneRegistry registry = DropZoneRegistry();

  DropZone? _activeZone;

  void begin(DragPayload payload, Offset globalPos) {
    if (_phase != DragPhase.idle) return;
    if (DateTime.now().isBefore(_suppressUntil)) return;
    _payload = payload;
    pointerGlobal.value = globalPos;
    hiddenTaskId.value = payload.task.id;
    _setPhase(DragPhase.active);
    _updateHover(globalPos);
  }

  void update(Offset globalPos) {
    if (_phase != DragPhase.active) return;
    pointerGlobal.value = globalPos;
    _updateHover(globalPos);
  }

  /// Re-hit-test under a static pointer (a zone scrolled / page flipped).
  void refreshHover() {
    if (_phase != DragPhase.active) return;
    _updateHover(pointerGlobal.value);
  }

  bool _refreshScheduled = false;

  /// Post-frame refresh — zones register/unregister mid-layout (page flips),
  /// so re-hit-test only once their rects are real.
  void scheduleHoverRefresh() {
    if (_phase != DragPhase.active || _refreshScheduled) return;
    _refreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refreshScheduled = false;
      refreshHover();
    });
  }

  void drop() {
    if (_phase != DragPhase.active) return;
    final payload = _payload;
    if (payload == null) return;
    final zone = _activeZone;
    final result = zone?.onDrop(pointerGlobal.value, payload);
    _landingChrome = result != null
        ? zone!.landingChrome
        : (payload.kind == DragSourceKind.timelineBlock ? 'block' : 'card');
    hover.value = null;
    if (result == null) {
      // Spring back — chase the SOURCE card's live rect (it may be riding a
      // returning drawer), falling back to the lift-time snapshot.
      _settleTarget = payload.sourceGlobalRect;
      _retargetLive = true;
      _setPhase(DragPhase.springingBack);
      return;
    }
    // A drop that actually landed — the drag invite has served its purpose and
    // retires here, whether or not it was ever shown.
    LessonState.instance.learn(Lessons.drag.id);
    _settleTarget = result.settleGlobalRect;
    _retargetLive = result.refineToCard;
    if (result.refineToCard) {
      // The mutation is committed; give the target lists ONE frame to
      // rebuild, then land on the real card's live rect.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_phase != DragPhase.active || _payload != payload) return;
        final fb = result.settleFallbackId;
        _settleTarget = DragCardRegistry.rectFor(payload.task.id) ??
            (fb == null ? null : DragCardRegistry.rectFor(fb)) ??
            _settleTarget;
        _setPhase(DragPhase.settling);
      });
      WidgetsBinding.instance.scheduleFrame();
    } else {
      _setPhase(DragPhase.settling);
    }
  }

  void cancel() {
    if (_phase != DragPhase.active) return;
    hover.value = null;
    _settleTarget = _payload?.sourceGlobalRect;
    _retargetLive = true;
    _landingChrome =
        _payload?.kind == DragSourceKind.timelineBlock ? 'block' : 'card';
    _setPhase(DragPhase.springingBack);
  }

  /// Called by the preview layer when its settle/spring animation lands.
  void finishTransition() {
    if (_phase != DragPhase.settling && _phase != DragPhase.springingBack) {
      return;
    }
    _payload = null;
    _settleTarget = null;
    _retargetLive = false;
    _activeZone = null;
    hiddenTaskId.value = null;
    _setPhase(DragPhase.idle);
  }

  void _updateHover(Offset globalPos) {
    final payload = _payload;
    if (payload == null) return;
    final zone = registry.hitTest(globalPos, payload);
    _activeZone = zone;
    final h = zone?.hoverAt(globalPos, payload);
    if (hover.value != h) hover.value = h;
  }

  void _setPhase(DragPhase p) {
    if (_phase == p) return;
    _phase = p;
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() {
    _payload = null;
    _settleTarget = null;
    _retargetLive = false;
    _landingChrome = 'card';
    _activeZone = null;
    _suppressUntil = DateTime.fromMillisecondsSinceEpoch(0);
    hover.value = null;
    hiddenTaskId.value = null;
    _setPhase(DragPhase.idle);
  }
}
