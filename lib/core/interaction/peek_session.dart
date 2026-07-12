import 'dart:async';
import 'package:flutter/widgets.dart';

/// Slate — global hover-peek session.
/// One floating popover at a time, rendered by [TaskPeekLayer] in PulseLayer's
/// ROOT Stack. The popover is INTERACTIVE (checkbox/edit), so a "cursor bridge"
/// keeps it alive while the pointer travels source → popover: sources call
/// [scheduleClose] on exit and [keepAlive] on re-enter; the popover does the same.

enum PeekKind { cardTitle, monthDay }

@immutable
class PeekRequest {
  /// Identity of the source (dedup + targeted hide) — a State or GlobalKey.
  final Object owner;
  /// Global rect of the source widget the popover anchors to.
  final Rect anchorRect;
  final PeekKind kind;
  final WidgetBuilder builder;
  final double maxWidth;

  const PeekRequest({
    required this.owner,
    required this.anchorRect,
    required this.kind,
    required this.builder,
    this.maxWidth = 260,
  });
}

class PeekSession extends ChangeNotifier {
  PeekSession._();
  static final PeekSession instance = PeekSession._();

  PeekRequest? _current;
  PeekRequest? get current => _current;
  Timer? _closeTimer;

  void show(PeekRequest req) {
    _closeTimer?.cancel();
    _closeTimer = null;
    _current = req;
    notifyListeners();
  }

  /// Pointer left the source/popover — close after a short grace so it can
  /// bridge into the interactive popover without it vanishing.
  void scheduleClose({Duration delay = const Duration(milliseconds: 90)}) {
    if (_current == null) return;
    _closeTimer?.cancel();
    _closeTimer = Timer(delay, () {
      _closeTimer = null;
      if (_current != null) {
        _current = null;
        notifyListeners();
      }
    });
  }

  /// Pointer re-entered the source or the popover — cancel a pending close.
  void keepAlive() {
    _closeTimer?.cancel();
    _closeTimer = null;
  }

  /// Hide only if [owner] still owns the popover.
  void hide(Object owner) {
    if (_current?.owner != owner) return;
    _closeTimer?.cancel();
    _closeTimer = null;
    _current = null;
    notifyListeners();
  }

  void hideAll() {
    _closeTimer?.cancel();
    _closeTimer = null;
    if (_current == null) return;
    _current = null;
    notifyListeners();
  }
}
