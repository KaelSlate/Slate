import 'package:flutter/material.dart';

import '../../core/state/task_state.dart';
import '../../core/theme/app_theme.dart';
import '../overlays/inbox_drawer.dart';
import '../views/day_flow_view.dart';
import '../views/month_grid_view.dart';
import '../views/week_tactics_view.dart' show WeekTacticsView;
import '../widgets/smart_day_input.dart';

/// Slate — Startup Warmup
/// One-shot pre-render of every heavy surface, painted beneath the opaque
/// [WarmupVeil] for a few frames. Flutter does no occlusion culling, so the
/// covered surfaces still rasterize and Skia compiles all their shaders
/// (glass blur, gradients, text pipelines) before the user ever interacts.

class WarmupStage extends StatefulWidget {
  final TaskState taskState;
  const WarmupStage({super.key, required this.taskState});

  @override
  State<WarmupStage> createState() => _WarmupStageState();
}

class _WarmupStageState extends State<WarmupStage>
    with SingleTickerProviderStateMixin {
  // value: 1.0 — drawer held fully open so its sigma-16 blur compiles.
  late final AnimationController _drawerCtrl =
      AnimationController(vsync: this, value: 1.0);
  final FocusNode _pillFocus = FocusNode();
  final SmartInputNotifier _pillNotifier = SmartInputNotifier();
  final ValueNotifier<DateTime?> _jumpNotifier = ValueNotifier(null);
  final ValueNotifier<int> _monthDelta = ValueNotifier(0);

  @override
  void dispose() {
    _drawerCtrl.dispose();
    _pillFocus.dispose();
    _pillNotifier.dispose();
    _jumpNotifier.dispose();
    _monthDelta.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ts = widget.taskState;
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Stack(
          fit: StackFit.expand,
          children: [
            MonthGridView(
              core: ts.core,
              taskState: ts,
              focusDate: DateTime.now(),
              scrollDeltaNotifier: _monthDelta,
              onDayTap: (_) {},
              onDayHover: (_) {},
            ),
            WeekTacticsView(
              core: ts.core,
              taskState: ts,
              jumpToDateNotifier: _jumpNotifier,
              onDayTap: (_) {},
              onDayHover: (_) {},
              onToggleTask: (_) {},
            ),
            DayFlowView(
              selectedDate: DateTime.now(),
              core: ts.core,
              taskState: ts,
              onToggleTask: (_) {},
            ),
            // Timeline card recipe — guaranteed even on an empty install.
            const Center(child: TaskBlockWarmupSample()),
            // Glass command pill (BackdropFilter + specular gradients).
            Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 80),
                child: SmartDayInputWidget(
                  core: ts.core,
                  focusNode: _pillFocus,
                  notifier: _pillNotifier,
                  onSubmit: (_, r) {},
                  onDismiss: () {},
                ),
              ),
            ),
            InboxDrawer(
              animationController: _drawerCtrl,
              onClose: () {},
              taskState: ts,
            ),
          ],
        ),
      ),
    );
  }
}

/// Opaque branded veil — always a SIBLING above the warming surfaces, never an
/// Opacity ancestor of live glass (BackdropFilter under animating opacity
/// flickers). By reveal time the warmup children are already removed, so the
/// fade only ever crosses into the calm real view.
class WarmupVeil extends StatelessWidget {
  final bool revealing;
  final VoidCallback onRevealed;
  const WarmupVeil({
    super.key,
    required this.revealing,
    required this.onRevealed,
  });

  @override
  Widget build(BuildContext context) {
    return AbsorbPointer(
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
        opacity: revealing ? 0.0 : 1.0,
        onEnd: () {
          if (revealing) onRevealed();
        },
        child: Container(
          color: AppTheme.background,
          alignment: Alignment.center,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'SLATE',
                style: AppFonts.interTight(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 4.0,
                  color: AppTheme.graphiteInk.withOpacity(0.82),
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: 26,
                height: 2,
                decoration: BoxDecoration(
                  color: AppTheme.honey.withOpacity(0.85),
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
