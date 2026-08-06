import 'dart:async';
import 'dart:io' show Directory;
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle, FontLoader;
import 'package:flutter_acrylic/flutter_acrylic.dart' show Window;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';
import 'core/engine/quick_capture_controller.dart';
import 'core/engine/spatial_zoom_engine.dart';
import 'core/engine/tray_shell.dart';
import 'core/sfx/sfx.dart';
import 'core/state/app_dirs.dart';
import 'core/state/crash_log.dart';
import 'core/state/first_run.dart';
import 'core/state/lesson_state.dart';
import 'core/state/local_prefs.dart';
import 'core/state/task_state.dart';
import 'core/theme/app_theme.dart';
import 'pill_window.dart';
import 'ui/screens/main_screen.dart';

/// Slate — Genesis Initialization
/// Desktop-first scroll behavior. UI loads immediately.

/// Eagerly activate the bundled variable fonts BEFORE the first frame. Pubspec
/// `fonts:` register asynchronously during binding init, so without this the
/// first painted view can use fallback metrics and then reflow ("task text
/// settles down a frame after the screen appears") when the real font activates.
/// FontLoader-loading them (awaited) makes the metrics correct from frame one.
/// Non-fatal: any failure just falls back to the old lazy behaviour.
Future<void> _warmFonts() async {
  // Warm all three in parallel — they were loaded one-await-at-a-time before,
  // serializing three rootBundle reads on the critical pre-first-frame path.
  await Future.wait(const ['Inter', 'InterTight', 'RobotoMono'].map((family) async {
    try {
      final loader = FontLoader(family)
        ..addFont(rootBundle.load('assets/fonts/$family.ttf'));
      await loader.load();
    } catch (e) {
      if (kDebugMode) print('font warm failed for $family: $e');
    }
  }));
}

void main(List<String> args) {
  // The runner launches a SECOND Flutter engine with `--pill` for the separate
  // capture-pill window. It boots a minimal pill app and shares none of the main
  // app's window/tray/hotkey machinery. See pill_window.dart.
  if (args.contains('--pill')) {
    runPillWindow();
    return;
  }
  // Crash observability for testers: every uncaught error (zone + framework)
  // lands in Documents/slate_data/logs with the app version. runApp must live
  // in the SAME zone as ensureInitialized, hence the wrap of the whole body.
  runZonedGuarded<void>(() async {
    await _boot(args);
  }, (error, stack) {
    CrashLog.record(error, stack, source: 'zone');
  });
}

Future<void> _boot(List<String> args) async {
  if (kDebugMode) print('main() started');
  // Autostart launches with --hidden: tray icon + hotkey only, no window.
  final startHidden = args.contains('--hidden');
  WidgetsFlutterBinding.ensureInitialized();

  FlutterError.onError = (details) {
    CrashLog.record(details.exception, details.stack, source: 'flutter');
    FlutterError.presentError(details);
  };
  // Resolve the log dir concurrently; earlier records are buffered.
  // AppDirs also runs the one-time move out of Documents/OneDrive here,
  // before anything opens the DB.
  unawaited(AppDirs.dataDir().then(
    (d) => CrashLog.init(Directory('${d.path}\\logs')),
  ));

  // Kick off everything independent AT ONCE instead of serializing await-by-await:
  // font warm, the prefs file, and window init all overlap. Fonts are still
  // awaited before runApp() so glyph metrics are correct on the first frame.
  // Prefs live in a plain JSON file now (see LocalPrefs) — DPAPI is reserved
  // for the actual secret (the SQLCipher DB key).
  final fontsWarm = _warmFonts();
  final prefsLoad = LocalPrefs.load();

  // Sound layer: opens the XAudio2 device and reads the saved mix. No-op in a
  // normal Slate build. Not awaited — nothing on the first-frame path needs it,
  // and Sfx stays silent until PulseLayer arms it after the warmup pass anyway.
  unawaited(Sfx.init());

  // Start the Rust engine NOW (DLL load → SQLCipher open → task hydration),
  // concurrent with fonts/prefs/window init instead of after the first frame.
  // The same container is handed to runApp, so the app sees this instance.
  final container = ProviderContainer();
  container.read(taskStateProvider);

  // Phase 5: Remove native OS title bar — custom header renders in-app.
  // setAsFrameless() zeroes WM_NCCALCSIZE → client area covers the whole
  // window, zero border strips. Edge RESIZE comes from the runner
  // (flutter_window.cpp): the Flutter view yields an 8px band via
  // HTTRANSPARENT and the top-level window answers HTLEFT/HTTOP/… natively.
  await windowManager.ensureInitialized();
  // Acrylic channel for the quick-capture overlay's transparent window mode.
  await Window.initialize();
  const windowOptions = WindowOptions(
    size: Size(1280, 720),
    minimumSize: Size(900, 600),
    center: true,
    backgroundColor: Color(0xFF15110D), // AppTheme.background (warm graphite)
    skipTaskbar: false,
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setAsFrameless();
    if (!startHidden) {
      await windowManager.show();
      await windowManager.focus();
    }
  });

  // Close (X / Alt+F4) hides to tray — the engine and the capture hotkey
  // stay alive. Real quit (with Rust flush) lives in the tray menu.
  await windowManager.setPreventClose(true);
  windowManager.addListener(_WindowCloseHandler());

  // Global quick capture hotkey + tray residency + launch-at-login.
  await QuickCaptureController.instance.init();
  TrayShell.instance.taskState = container.read(taskStateProvider);
  await TrayShell.instance.init();

  // Launch view (#1): default to WEEK, but reopen in MONTH if that's the view you
  // last worked in — the 'V' toggle persists view_pref. We no longer force the
  // Day view on first launch.
  final prefs = await prefsLoad;
  if (prefs.viewPref == 'month') {
    StaircaseState.isWeekPreference = false;
    StaircaseState.currentLevel = StaircaseLevel.monthGrid;
  } else {
    StaircaseState.isWeekPreference = true;
    StaircaseState.currentLevel = StaircaseLevel.weekTactics;
  }

  // First-run: welcome overlay + the empty-state ghost silhouettes, both live
  // until the first capture completes the arc (see FirstRunController).
  StaircaseState.isFirstRun = !prefs.onboarded;
  StaircaseState.showWelcome = !prefs.welcomed;
  FirstRunController.instance.syncFromPrefs();
  // The teaching ladder outlives that moment: each mechanic retires on its own
  // mastery, so one capture can no longer switch off everything unlearned.
  LessonState.instance.syncFromPrefs();

  await fontsWarm; // ensure glyph metrics are ready before the first frame
  runApp(UncontrolledProviderScope(container: container, child: const SlateApp()));
}

/// Window-close interceptor: X hides to tray. The process must survive so
/// the capture hotkey keeps working — that's the whole point of the tray.
/// The real exit path (Rust flush + exit(0), never windowManager.destroy():
/// destroy() races WM_CLOSE inside flutter_windows.dll → AV) is
/// TrayShell.quit().
class _WindowCloseHandler with WindowListener {
  @override
  void onWindowClose() async {
    await windowManager.hide();
  }
}

/// Custom scroll behavior for desktop.
/// NO mouse in dragDevices: on desktop a mouse must NOT click-drag to scroll —
/// that let you grab a task row and yank the whole list around (bouncy
/// overscroll), which reads as cheap/unfinished. Mouse = wheel-scroll only (the
/// native norm: Linear, Notion, Things). Touch/trackpad/stylus keep drag-to-scroll.
/// The hour timeline still pans because DesktopScrollWrapper maps the wheel to
/// horizontal scroll.
class SlateDesktopScrollBehavior extends MaterialScrollBehavior {
  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.stylus,
    PointerDeviceKind.trackpad,
  };

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) {
    return const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());
  }
}

class SlateApp extends StatelessWidget {
  const SlateApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Slate',
      theme: AppTheme.darkTheme,
      debugShowCheckedModeBanner: false,
      scrollBehavior: SlateDesktopScrollBehavior(),
      // The capture pill is a SEPARATE window now (its own engine) — this
      // window is only ever the app. No morph, no root swap.
      home: const MainScreen(),
    );
  }
}
