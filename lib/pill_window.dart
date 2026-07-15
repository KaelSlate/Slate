import 'package:flutter/material.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'core/theme/app_theme.dart';

/// Entry for the SEPARATE pill window (runner launches a second Flutter engine
/// with the `--pill` entrypoint arg). This window is the global capture pill and
/// NOTHING else — the main app window is never touched, so none of the round 1-8
/// morph fragility (cold swapchain, jerk, maximize desync, taskbar flash) can
/// happen. Phase 1 = prove a borderless topmost window + blur render on Windows;
/// live parsing + capture + main-window refresh land in later phases.
Future<void> runPillWindow() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Window.initialize();
  runApp(const _PillApp());
}

class _PillApp extends StatelessWidget {
  const _PillApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: SizedBox(
            width: 600,
            height: 57,
            child: _PillShell(),
          ),
        ),
      ),
    );
  }
}

/// Placeholder body — the real SmartDayInput moves in once the window plumbing
/// (Phase 2/3) is proven. Kept visually close so the spike shows the true look.
class _PillShell extends StatelessWidget {
  const _PillShell();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppTheme.glassOpaqueBody,
        borderRadius: BorderRadius.circular(28),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 40, spreadRadius: 4),
        ],
      ),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 28),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text('Type a task…',
              style: TextStyle(color: Colors.white54, fontSize: 17)),
        ),
      ),
    );
  }
}
