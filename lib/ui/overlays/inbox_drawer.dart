import 'dart:ui';
import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../../core/state/task_state.dart';
import '../../core/engine/slate_core_bridge.dart';
import '../../core/interaction/drag_session.dart';
import '../widgets/drag_source.dart';

/// Slate — Inbox Drawer (Phase 3)
/// Right-side glassmorphic overlay panel.
/// Phase 4: Items are tasks with is_inbox == true (explicit Rust flag).
///   Add/Edit/Delete all go through TaskState → Rust → SQLite → Supabase sync.
/// Kinetics: 420ms spring open, easeInQuart reverse.

// ─────────────────────────────────────────────────────────────────────────────
// INBOX DRAWER — Glassmorphic right-side overlay
// ─────────────────────────────────────────────────────────────────────────────
class InboxDrawer extends StatefulWidget {
  final AnimationController animationController;
  final VoidCallback onClose;
  final TaskState taskState;

  const InboxDrawer({
    super.key,
    required this.animationController,
    required this.onClose,
    required this.taskState,
  });

  @override
  State<InboxDrawer> createState() => _InboxDrawerState();
}

class _InboxDrawerState extends State<InboxDrawer>
    with SingleTickerProviderStateMixin {
  final TextEditingController _inputController = TextEditingController();
  // Escape is handled ONCE, centrally, by PulseLayer's _globalKeyHandler
  // (priority: close inbox → unfocus text → zoom out) via HardwareKeyboard —
  // it fires regardless of Flutter focus, text field or not. This drawer used
  // to ALSO handle Escape itself (both here and via its own hardware handler),
  // so a single press fired both handlers and the two toggles cancelled out —
  // Escape looked like it did nothing. Do not re-add Escape handling here.
  final FocusNode _inputFocusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  late Animation<double> _fadeAnimation;
  late Animation<double> _contentFade;
  late Animation<Offset> _slide;

  // ── Drag recede ──────────────────────────────────────────────────────────
  // A drag that leaves the drawer slides the panel away (subtree stays MOUNTED
  // — reusing _inboxCtrl would dismiss it and kill the in-flight drag preview).
  // Returns on drag end → chaining several inbox drops feels seamless.
  // No Opacity over the BackdropFilter (flicker gotcha) — slide only.
  late final AnimationController _recedeCtrl;
  late final Animation<double> _recede;
  late final Animation<Offset> _recedeSlide;

  // Fix 3: Cached inbox list — computed once on state change, never inside build().
  // The AnimatedBuilder runs at 120 Hz during the spring animation; an O(N) .where()
  // inside build() would waste ~12ms per second on list allocations.
  List<RustTask> _cachedInboxItems = const [];

  // Glass is not water: while the panel is up it must BLOCK the zones behind
  // it (rect-math hit-testing ignores overlays), so a payload held over the
  // inbox never aims at the day underneath. Drops on the panel spring back.
  final GlobalKey _panelKey = GlobalKey();
  late final _DrawerBlockerZone _blockerZone;

  /// Recompute the inbox cache. Called from initState() and _onTaskStateChanged().
  void _refreshInboxCache() {
    _cachedInboxItems = TaskState.orderInbox(
        widget.taskState.tasks.where((t) => t.isInbox).toList());
  }

  @override
  void initState() {
    super.initState();
    // Prime the cache before the first build — avoids empty-state flash
    _refreshInboxCache();

    // Etalon (#I), final: "unified drawer" — the WHOLE panel (blur + tint +
    // border + content) slides in from behind the right edge as ONE piece.
    // Every previous "trail" complaint traced to the layers moving on
    // DIFFERENT schedules (static blur under sliding/fading content, or sigma
    // animating against opacity). One panel, one motion — nothing can smear,
    // nothing lingers. Open: full off-screen → in, easeOutQuint (fast launch,
    // silk deceleration). Close: easeInCubic back behind the edge — decisive,
    // not abrupt. Durations live on _inboxCtrl in pulse_layer.dart (420/320ms).

    _slide = Tween<Offset>(
      begin: const Offset(1.0, 0.0),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(
        parent: widget.animationController,
        curve: Curves.easeOutQuint,
        reverseCurve: Curves.easeInCubic,
      ),
    );

    // Scrim — fades with the panel both ways.
    _fadeAnimation = CurvedAnimation(
      parent: widget.animationController,
      curve: Curves.easeOut,
      reverseCurve: Curves.easeIn,
    );

    // Content settles a beat behind the panel on open. On CLOSE it stays fully
    // opaque and simply rides out with the panel (Threshold(0.0) = constant 1.0
    // during reverse) — fading it while it moves is what read as a smear.
    _contentFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: widget.animationController,
        curve: const Interval(0.2, 1.0, curve: Curves.easeOut),
        reverseCurve: const Threshold(0.0),
      ),
    );

    // Reactive rebuilds when Rust store changes (sync, external mutations)
    widget.taskState.addListener(_onTaskStateChanged);

    _recedeCtrl = AnimationController(
      duration: const Duration(milliseconds: 240),
      reverseDuration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _recede = CurvedAnimation(
      parent: _recedeCtrl,
      curve: Curves.easeInCubic,
      reverseCurve: Curves.easeOutQuint,
    );
    _recedeSlide = Tween<Offset>(begin: Offset.zero, end: const Offset(1.06, 0))
        .animate(_recede);
    _blockerZone = _DrawerBlockerZone(this);
    DragSession.instance.registry.register(_blockerZone);
    DragSession.instance.addListener(_onDragPhase);
    DragSession.instance.pointerGlobal.addListener(_onDragPointer);
  }

  void _onDragPhase() {
    if (!mounted) return;
    // Come back the moment the payload is RELEASED (settling/spring-back),
    // not at idle — a missed drop's preview then flies toward its inbox slot
    // while the panel slides home under it, and the two meet.
    if (DragSession.instance.phase != DragPhase.active &&
        _recedeCtrl.value > 0) {
      _recedeCtrl.reverse();
    }
  }

  void _onDragPointer() {
    if (!mounted) return;
    final s = DragSession.instance;
    if (!s.isActive || s.payload?.kind != DragSourceKind.inboxCard) return;
    if (_recedeCtrl.status == AnimationStatus.forward || _recedeCtrl.value > 0) {
      return;
    }
    if (widget.animationController.isDismissed) return;
    final screenW = MediaQuery.of(context).size.width;
    final drawerW = screenW * 0.28 < AppTheme.drawerWidth
        ? AppTheme.drawerWidth
        : screenW * 0.28;
    if (s.pointerGlobal.value.dx < screenW - drawerW - 8) {
      _recedeCtrl.forward();
    }
  }

  /// Fix 3: Cache is recomputed here — outside build() — so the AnimatedBuilder
  /// hot path is a pure O(1) reference read during the 120Hz spring animation.
  void _onTaskStateChanged() {
    if (mounted) {
      _refreshInboxCache();
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(InboxDrawer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.taskState != widget.taskState) {
      oldWidget.taskState.removeListener(_onTaskStateChanged);
      widget.taskState.addListener(_onTaskStateChanged);
    }
  }

  @override
  void dispose() {
    DragSession.instance.registry.unregister(_blockerZone);
    DragSession.instance.removeListener(_onDragPhase);
    DragSession.instance.pointerGlobal.removeListener(_onDragPointer);
    _recedeCtrl.dispose();
    widget.taskState.removeListener(_onTaskStateChanged);
    _inputController.dispose();
    _inputFocusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  // ── MUTATIONS → all delegated to Rust via TaskState ──────────────────────

  void _addItem(String text) {
    if (text.trim().isEmpty) return;
    // Parse #tags / !! importance out of the typed thought (time is ignored —
    // an inbox item stays untimed). createInboxTask sets is_inbox=true in Rust.
    final r = widget.taskState.core.parseInput(text.trim());
    final title =
        r.cleanTitle.trim().isEmpty ? text.trim() : r.cleanTitle.trim();
    widget.taskState
        .createInboxTask(title, priority: r.priority, tags: r.tags);
    _inputController.clear();
    _inputFocusNode.requestFocus();
  }

  void _deleteItem(RustTask task) {
    widget.taskState.deleteTask(task);
  }

  void _updateItem(RustTask task, String newText) {
    if (newText.trim().isEmpty) return;
    widget.taskState.updateTask(
      task.copyWith(
        title: newText.trim(),
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final drawerWidth = screenWidth * 0.28 < AppTheme.drawerWidth
        ? AppTheme.drawerWidth
        : screenWidth * 0.28;

    return AnimatedBuilder(
      animation: Listenable.merge([widget.animationController, _recedeCtrl]),
      builder: (context, child) {
        if (widget.animationController.isDismissed) {
          return const SizedBox.shrink();
        }

        return IgnorePointer(
          // Receded during a drag: reveal + let drops reach the board behind.
          ignoring: _recedeCtrl.value > 0.02,
          child: Stack(
          children: [
            // Scrim — subtle dark overlay behind drawer
            FadeTransition(
              opacity: _fadeAnimation,
              child: FadeTransition(
                opacity: ReverseAnimation(_recede),
                child: GestureDetector(
                  onTap: widget.onClose,
                  child: Container(color: Colors.black.withOpacity(0.3)),
                ),
              ),
            ),

            // The Panel — blur + tint + border + content as ONE unit, sliding
            // in from behind the right edge. Nothing stays behind while
            // something else moves → no smear, no lingering haze. (#I)
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: drawerWidth,
              child: RepaintBoundary(
                child: SlideTransition(
                  position: _slide,
                  child: SlideTransition(
                  position: _recedeSlide,
                  child: ClipRect(
                    key: _panelKey,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                      child: Container(
                        decoration: BoxDecoration(
                          color: AppTheme.surface.withOpacity(0.4),
                          border: Border(
                            left: BorderSide(
                              color: Colors.white.withOpacity(0.1),
                              width: 0.5,
                            ),
                          ),
                        ),
                        child: FadeTransition(
                          opacity: _contentFade,
                          child: Column(
                            children: [
                              _buildHeader(),
                              _buildInputField(),
                              Container(
                                height: 0.5,
                                margin:
                                    const EdgeInsets.symmetric(horizontal: 20),
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.white.withOpacity(0.0),
                                      Colors.white.withOpacity(0.06),
                                      Colors.white.withOpacity(0.06),
                                      Colors.white.withOpacity(0.0),
                                    ],
                                    stops: const [0.0, 0.2, 0.8, 1.0],
                                  ),
                                ),
                              ),
                              Expanded(
                                // Fix 3: O(1) field reference — no .where() inside build()
                                child: _cachedInboxItems.isEmpty
                                    ? _buildEmptyState()
                                    : _buildItemList(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  ),
                ),
              ),
            ),
          ],
          ),
        );
      },
    );
  }

  // ── HEADER ─────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 16, 12),
      child: Row(
        children: [
          Text(
            'Inbox',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
              color: Colors.white.withOpacity(0.85),
            ),
          ),
          // No count badge: "Inbox 26" is a pile of guilt, not information —
          // the list itself says everything (quiet-progress rule).
          const Spacer(),
          _CloseButton(onTap: widget.onClose),
        ],
      ),
    );
  }

  // ── INPUT FIELD ────────────────────────────────────────────────────
  Widget _buildInputField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: Colors.white.withOpacity(0.04),
          border: Border.all(color: Colors.white.withOpacity(0.08), width: 0.5),
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Icon(
                Icons.add_rounded,
                size: 16,
                color: Colors.white.withOpacity(0.25),
              ),
            ),
            Expanded(
              child: TextField(
                controller: _inputController,
                focusNode: _inputFocusNode,
                style: const TextStyle(
                  fontFamily: 'Inter',
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: Colors.white,
                  letterSpacing: 0.1,
                ),
                decoration: InputDecoration(
                  hintText: 'Add thought...',
                  hintStyle: TextStyle(
                    fontFamily: 'Inter',
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: Colors.white.withOpacity(0.2),
                    letterSpacing: 0.1,
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 12,
                  ),
                  border: InputBorder.none,
                ),
                onSubmitted: _addItem,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── EMPTY STATE ────────────────────────────────────────────────────
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.lightbulb_outline_rounded,
            size: 32,
            color: Colors.white.withOpacity(0.08),
          ),
          const SizedBox(height: 12),
          Text(
            'Your inbox is empty',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: Colors.white.withOpacity(0.15),
              letterSpacing: 0.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Capture thoughts, ideas, and plans',
            style: TextStyle(
              fontFamily: 'Inter',
              fontSize: 11,
              fontWeight: FontWeight.w400,
              color: Colors.white.withOpacity(0.08),
              letterSpacing: 0.1,
            ),
          ),
        ],
      ),
    );
  }

  // ── ITEM LIST ──────────────────────────────────────────────────────
  Widget _buildItemList() {
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      // Fix 3: cached list — O(1)
      itemCount: _cachedInboxItems.length,
      itemBuilder: (context, index) {
        final task = _cachedInboxItems[index];
        return DragSource(
          key: ValueKey(task.id),
          task: task,
          kind: DragSourceKind.inboxCard,
          sourceInsets: const EdgeInsets.only(bottom: 4),
          child: _InboxItemCard(
            task: task,
            onDelete: () => _deleteItem(task),
            onEdit: (val) => _updateItem(task, val),
          ),
        );
      },
    );
  }
}

/// Opaque shield over the drawer panel: wins every zone hit-test beneath it
/// (priority 100), shows no hover, and turns drops into spring-backs. Goes
/// passive the moment the panel recedes or is dismissed.
class _DrawerBlockerZone extends DropZone {
  final _InboxDrawerState state;
  _DrawerBlockerZone(this.state);

  @override
  String get id => 'inbox-drawer';

  @override
  int get priority => 100;

  @override
  Rect? globalRect() {
    if (!state.mounted) return null;
    if (state.widget.animationController.isDismissed) return null;
    if (state._recedeCtrl.value > 0.02) return null;
    final box =
        state._panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  DropHover? hoverAt(Offset globalPos, DragPayload p) => null;

  @override
  DropResult? onDrop(Offset globalPos, DragPayload p) => null;
}

// ─────────────────────────────────────────────────────────────────────────────
// INBOX ITEM CARD — hover-reveal edit/delete, premium micro-interactions
// Now driven by RustTask instead of ephemeral InboxItem
// ─────────────────────────────────────────────────────────────────────────────
class _InboxItemCard extends StatefulWidget {
  final RustTask task;
  final VoidCallback onDelete;
  final ValueChanged<String> onEdit;

  const _InboxItemCard({
    required this.task,
    required this.onDelete,
    required this.onEdit,
  });

  @override
  State<_InboxItemCard> createState() => _InboxItemCardState();
}

class _InboxItemCardState extends State<_InboxItemCard>
    with SingleTickerProviderStateMixin {
  bool _hovered = false;
  bool _editing = false;
  late TextEditingController _editController;
  late FocusNode _editFocus;
  late AnimationController _deleteCtrl;

  @override
  void initState() {
    super.initState();
    _editController = TextEditingController(text: widget.task.title);
    _editFocus = FocusNode();
    _editFocus.addListener(() {
      if (!_editFocus.hasFocus && _editing) {
        setState(() {
          _editing = false;
          _editController.text = widget.task.title;
        });
      }
    });
    _deleteCtrl = AnimationController(
      duration: const Duration(milliseconds: 280),
      vsync: this,
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(_InboxItemCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Sync edit field if title changed externally (e.g. from sync)
    if (!_editing && oldWidget.task.title != widget.task.title) {
      _editController.text = widget.task.title;
    }
  }

  @override
  void dispose() {
    _editController.dispose();
    _editFocus.dispose();
    _deleteCtrl.dispose();
    super.dispose();
  }

  void _triggerDelete() async {
    await _deleteCtrl.reverse();
    if (mounted) widget.onDelete();
  }

  Color _priorityColor(int p) {
    if (p == 2) return AppTheme.priorityCritical;
    if (p == 1) return AppTheme.priorityHigh;
    return Colors.white.withOpacity(0.2);
  }

  @override
  Widget build(BuildContext context) {
    final priority = widget.task.priority;
    final prioColor = _priorityColor(priority);
    return SizeTransition(
      sizeFactor: CurvedAnimation(
        parent: _deleteCtrl,
        curve: Curves.easeOutQuart,
      ),
      child: FadeTransition(
        opacity: _deleteCtrl,
        child: MouseRegion(
          cursor: SystemMouseCursors.basic,
          onEnter: (_) {
            if (DragSession.hoverSuppressed) return;
            setState(() => _hovered = true);
          },
          onExit: (_) => setState(() => _hovered = false),
          child: AnimatedContainer(
            // Phase 2: easeOutQuart on hover — feels weighted, not nervous
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutQuart,
            margin: const EdgeInsets.only(bottom: 4),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: _hovered
                  ? Colors.white.withOpacity(0.04)
                  : Colors.white.withOpacity(0.015),
              border: Border.all(
                color: _hovered
                    ? Colors.white.withOpacity(0.10)
                    : Colors.white.withOpacity(0.04),
                width: 0.5,
              ),
              boxShadow: _hovered
                  ? [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.3),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ]
                  : [],
            ),
            child: Row(
              children: [
                // Priority pip — colour == importance (critical/high/normal)
                Container(
                  width: priority >= 1 ? 6 : 5,
                  height: priority >= 1 ? 6 : 5,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: prioColor,
                    boxShadow: priority == 2
                        ? [BoxShadow(color: prioColor.withOpacity(0.4), blurRadius: 5)]
                        : null,
                  ),
                ),
                // Text or edit field
                Expanded(
                  child: _editing
                      ? TextField(
                          controller: _editController,
                          focusNode: _editFocus,
                          style: const TextStyle(
                            fontFamily: 'Inter',
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            color: Colors.white,
                            height: 1.4,
                          ),
                          decoration: const InputDecoration(
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                            border: InputBorder.none,
                          ),
                          onSubmitted: (val) {
                            setState(() => _editing = false);
                            if (val.trim().isNotEmpty) {
                              widget.onEdit(val);
                            } else {
                              _editController.text = widget.task.title;
                            }
                          },
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.task.title,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                color: Colors.white.withOpacity(0.75),
                                height: 1.4,
                                letterSpacing: 0.05,
                              ),
                            ),
                            // Age label removed: "2d" reads as "ignored for
                            // two days" — guilt, not help. Sort order already
                            // keeps the freshest thought on top.
                            if (widget.task.tags.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Wrap(
                              spacing: 5,
                              runSpacing: 4,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                for (final tg in widget.task.tags)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 6, vertical: 1.5),
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
                                      style: TextStyle(
                                        fontFamily: 'Inter',
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
                ),

                // Action icons — hover only
                AnimatedOpacity(
                  duration: const Duration(milliseconds: 140),
                  opacity: _hovered ? 0.5 : 0.0,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 140),
                    curve: Curves.easeOutQuart,
                    offset: Offset(_hovered ? 0 : 0.3, 0),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _actionIcon(
                          Icons.edit_outlined,
                          onTap: () {
                            setState(() => _editing = true);
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              _editFocus.requestFocus();
                            });
                          },
                        ),
                        const SizedBox(width: 2),
                        _actionIcon(
                          Icons.delete_outline_rounded,
                          onTap: _triggerDelete,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionIcon(IconData icon, {VoidCallback? onTap}) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 13, color: Colors.grey[400]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CLOSE BUTTON — subtle × with hover glow
// ─────────────────────────────────────────────────────────────────────────────
class _CloseButton extends StatefulWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});
  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _hovered
                ? Colors.white.withOpacity(0.08)
                : Colors.white.withOpacity(0.03),
            border: Border.all(
              color: Colors.white.withOpacity(_hovered ? 0.14 : 0.06),
              width: 0.5,
            ),
          ),
          child: Icon(
            Icons.close_rounded,
            size: 14,
            color: Colors.white.withOpacity(_hovered ? 0.6 : 0.3),
          ),
        ),
      ),
    );
  }
}

