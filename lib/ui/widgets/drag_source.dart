import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/engine/slate_core_bridge.dart';
import '../../core/interaction/drag_session.dart';

/// Lift-on-drag wrapper: LMB + ~5px of travel → DragSession.begin.
/// Plain clicks pass through untouched (mouse tap slop is 1px, so the child's
/// tap recognizer has already rejected by the time we lift — no double-fire).
/// Also dims/hides its child while that task is mid-drag or settling.
class DragSource extends StatefulWidget {
  final RustTask task;
  final DragSourceKind kind;
  final DateTime? sourceDay;
  /// Deflates the lifted-card rect (e.g. the card's own bottom margin).
  final EdgeInsets sourceInsets;
  final bool enabled;
  final Widget child;

  const DragSource({
    super.key,
    required this.task,
    required this.kind,
    this.sourceDay,
    this.sourceInsets = EdgeInsets.zero,
    this.enabled = true,
    required this.child,
  });

  @override
  State<DragSource> createState() => _DragSourceState();
}

class _DragSourceState extends State<DragSource> {
  static const double _threshold = 5.0;

  Offset? _downGlobal;
  int _pointer = -1;

  @override
  void initState() {
    super.initState();
    DragCardRegistry.register(widget.task.id, _liveRect);
  }

  @override
  void didUpdateWidget(DragSource old) {
    super.didUpdateWidget(old);
    if (old.task.id != widget.task.id) {
      DragCardRegistry.unregister(old.task.id, _liveRect);
      DragCardRegistry.register(widget.task.id, _liveRect);
    }
  }

  @override
  void dispose() {
    DragCardRegistry.unregister(widget.task.id, _liveRect);
    super.dispose();
  }

  /// Live rect provider — lets a settling drag preview land on this exact card.
  Rect? _liveRect() {
    if (!mounted) return null;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return widget.sourceInsets
        .deflateRect(box.localToGlobal(Offset.zero) & box.size);
  }

  bool _textInputActive() {
    final ctx = FocusManager.instance.primaryFocus?.context;
    return ctx?.findAncestorStateOfType<EditableTextState>() != null;
  }

  void _onPointerDown(PointerDownEvent e) {
    if (!widget.enabled) return;
    if (e.buttons != kPrimaryButton) return;
    if (_textInputActive()) return;
    _pointer = e.pointer;
    _downGlobal = e.position;
  }

  void _onPointerMove(PointerMoveEvent e) {
    final down = _downGlobal;
    if (down == null || e.pointer != _pointer) return;
    if (DragSession.instance.phase != DragPhase.idle) return;
    if ((e.position - down).distance < _threshold) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    _downGlobal = null;
    final rect = widget.sourceInsets
        .deflateRect(box.localToGlobal(Offset.zero) & box.size);
    DragSession.instance.begin(
      DragPayload(
        task: widget.task,
        kind: widget.kind,
        sourceGlobalRect: rect,
        grabOffset: down - rect.topLeft,
        sourceDay: widget.sourceDay,
      ),
      e.position,
    );
  }

  void _reset(PointerEvent _) {
    _downGlobal = null;
    _pointer = -1;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _reset,
      onPointerCancel: _reset,
      child: ValueListenableBuilder<String?>(
        valueListenable: DragSession.instance.hiddenTaskId,
        builder: (_, hidden, child) {
          final isHidden = hidden == widget.task.id;
          final settling =
              DragSession.instance.phase == DragPhase.settling;
          return AnimatedOpacity(
            duration: const Duration(milliseconds: 120),
            opacity: !isHidden ? 1.0 : (settling ? 0.0 : 0.35),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}
