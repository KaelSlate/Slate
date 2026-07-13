import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/state/toast_bus.dart';
import '../../core/theme/app_theme.dart';

/// Slate toast — one calm line, bottom center, self-dismissing. No Material
/// SnackBar: this is a flat warm surface in the app's own voice. Tapping the
/// toast runs its optional action (e.g. "Deleted · Ctrl+Z to undo" → undo).
/// Mounted once in PulseLayer's stack. Fade+rise in, quiet fade out.
class SlateToastLayer extends StatefulWidget {
  const SlateToastLayer({super.key});

  @override
  State<SlateToastLayer> createState() => _SlateToastLayerState();
}

class _SlateToastLayerState extends State<SlateToastLayer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  Timer? _hideTimer;
  ToastMessage? _msg;

  static const _lifetime = Duration(milliseconds: 2600);

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      duration: const Duration(milliseconds: 190),
      reverseDuration: const Duration(milliseconds: 260),
      vsync: this,
    );
    SlateToasts.instance.current.addListener(_onToast);
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    SlateToasts.instance.current.removeListener(_onToast);
    _ctrl.dispose();
    super.dispose();
  }

  void _onToast() {
    final msg = SlateToasts.instance.current.value;
    if (msg == null) return;
    setState(() => _msg = msg);
    _ctrl.forward(from: _ctrl.value * 0.6); // re-show keeps a soft pulse
    _hideTimer?.cancel();
    _hideTimer = Timer(_lifetime, _hide);
  }

  void _hide() {
    _hideTimer?.cancel();
    _ctrl.reverse().whenComplete(() {
      if (mounted && _ctrl.isDismissed) setState(() => _msg = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final msg = _msg;
    if (msg == null) return const SizedBox.shrink();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 44,
      child: IgnorePointer(
        ignoring: msg.onTap == null,
        child: Center(
          child: FadeTransition(
            opacity: CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
            child: AnimatedBuilder(
              animation: _ctrl,
              builder: (context, child) => Transform.translate(
                offset: Offset(0, (1 - _ctrl.value) * 8),
                child: child,
              ),
              child: MouseRegion(
                cursor: SystemMouseCursors.basic,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: msg.onTap == null
                      ? null
                      : () {
                          msg.onTap!();
                          _hide();
                        },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceLight.withValues(alpha: 0.97),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.10),
                          width: 0.5),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.40),
                          blurRadius: 18,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (msg.icon != null) ...[
                          Icon(msg.icon,
                              size: 13,
                              color: Colors.white.withValues(alpha: 0.5)),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          msg.text,
                          style: AppFonts.inter(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w500,
                            color: Colors.white.withValues(alpha: 0.80),
                            letterSpacing: 0.1,
                          ),
                        ),
                        if (msg.detail != null) ...[
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Text('·',
                                style: AppFonts.inter(
                                  fontSize: 12.5,
                                  color:
                                      Colors.white.withValues(alpha: 0.25),
                                )),
                          ),
                          Text(
                            msg.detail!,
                            style: AppFonts.inter(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.38),
                              letterSpacing: 0.1,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
