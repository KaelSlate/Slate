import 'package:flutter/material.dart';

import '../../core/state/task_state.dart';
import '../../core/theme/app_theme.dart';
import '../widgets/paper_grain.dart';

/// The honest face of a vault that didn't open. Replaces the old silent
/// «Sample task 1..5» fallback, which read as data loss and let new input
/// write into the void. Calm, specific, and it blocks nothing it shouldn't:
/// captures made while this is up are spilled and file themselves later.
class VaultGate extends StatefulWidget {
  final EngineFailure failure;
  final VoidCallback onRetry;
  final VoidCallback onStartFresh;

  const VaultGate({
    super.key,
    required this.failure,
    required this.onRetry,
    required this.onStartFresh,
  });

  @override
  State<VaultGate> createState() => _VaultGateState();
}

class _VaultGateState extends State<VaultGate> {
  /// «Start fresh» arms on the first tap and fires on the second — a quiet
  /// two-step instead of a modal dialog.
  bool _freshArmed = false;

  String get _causeLine => switch (widget.failure.kind) {
        EngineFailKind.key =>
          'The vault is encrypted with a key this Windows profile no longer holds.',
        EngineFailKind.io =>
          "The vault file didn't open — another program may be holding it.",
        EngineFailKind.other =>
          "The vault file didn't read back the way it was written.",
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.background.withValues(alpha: 0.985),
      child: PaperGrain(
        child: TweenAnimationBuilder<double>(
          tween: Tween(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 380),
          curve: Curves.easeOutCubic,
          builder: (context, t, child) => Opacity(
            opacity: t,
            child: Transform.translate(
              offset: Offset(0, 10 * (1 - t)),
              child: child,
            ),
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text("Slate can't open your tasks.",
                      textAlign: TextAlign.center,
                      style: AppTheme.welcomeSerif),
                  const SizedBox(height: 14),
                  Text(_causeLine,
                      textAlign: TextAlign.center,
                      style: AppTheme.bodyLarge.copyWith(
                        color: AppTheme.textSecondary,
                        fontSize: 14,
                        height: 1.5,
                      )),
                  const SizedBox(height: 10),
                  Text(widget.failure.dbPath,
                      textAlign: TextAlign.center,
                      style: AppFonts.robotoMono(
                        fontSize: 11,
                        color: Colors.white.withValues(alpha: 0.28),
                      )),
                  const SizedBox(height: 26),
                  Text(
                    'The file itself is untouched. Anything you capture right '
                    'now is kept safe and will file itself once the vault opens.',
                    textAlign: TextAlign.center,
                    style: AppFonts.inter(
                      fontSize: 12.5,
                      color: Colors.white.withValues(alpha: 0.42),
                      height: 1.55,
                    ),
                  ),
                  const SizedBox(height: 34),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 10,
                    children: [
                      _GateButton(
                        label: 'Try again',
                        emphasized: true,
                        onTap: widget.onRetry,
                      ),
                      _GateButton(
                        label: _freshArmed
                            ? "Click again if you're sure"
                            : 'Start fresh — the old file is kept',
                        emphasized: false,
                        onTap: () {
                          if (!_freshArmed) {
                            setState(() => _freshArmed = true);
                            return;
                          }
                          widget.onStartFresh();
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GateButton extends StatefulWidget {
  final String label;
  final bool emphasized;
  final VoidCallback onTap;
  const _GateButton(
      {required this.label, required this.emphasized, required this.onTap});

  @override
  State<_GateButton> createState() => _GateButtonState();
}

class _GateButtonState extends State<_GateButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final base = widget.emphasized ? 0.14 : 0.05;
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: Colors.white.withValues(alpha: base + (_hovered ? 0.04 : 0)),
            border: Border.all(
              color: Colors.white.withValues(
                  alpha: widget.emphasized ? 0.22 : 0.12),
              width: 0.5,
            ),
          ),
          child: Text(
            widget.label,
            style: AppFonts.inter(
              fontSize: 13,
              fontWeight:
                  widget.emphasized ? FontWeight.w600 : FontWeight.w500,
              color: Colors.white
                  .withValues(alpha: widget.emphasized ? 0.88 : 0.62),
            ),
          ),
        ),
      ),
    );
  }
}
