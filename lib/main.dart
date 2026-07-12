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
import 'core/state/local_prefs.dart';
import 'core/state/task_state.dart';
import 'core/theme/app_theme.dart';
import 'ui/overlays/quick_capture_overlay.dart';
import 'ui/screens/main_screen.dart';
import 'ui/screens/preview_first_run.dart';

/// Slate — Genesis Initialization
/// Desktop-first scroll behavior. UI loads immediately.

/// TEMPORARY — when true, boots the Warm Foundation preview instead of the app.
/// Flip to false (and delete preview_first_run.dart) when done reviewing.
const bool kPreviewMode = false;

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

void main(List<String> args) async {
  if (kDebugMode) print('main() started');
  // Autostart launches with --hidden: tray icon + hotkey only, no window.
  final startHidden = args.contains('--hidden');
  WidgetsFlutterBinding.ensureInitialized();

  // Kick off everything independent AT ONCE instead of serializing await-by-await:
  // font warm, the prefs file, and window init all overlap. Fonts are still
  // awaited before runApp() so glyph metrics are correct on the first frame.
  // Prefs live in a plain JSON file now (see LocalPrefs) — DPAPI is reserved
  // for the actual secret (the SQLCipher DB key).
  final fontsWarm = _warmFonts();
  final prefsLoad = LocalPrefs.load();

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

  // First-run onboarding flags (greeting removed — these only gate other niceties).
  StaircaseState.isFirstRun = !prefs.onboarded;
  StaircaseState.showWelcome = !prefs.welcomed;

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
      // Root swap: the same window is either the app or the capture pill.
      // When Slate itself is focused, capture stacks OVER the app instead —
      // no window morph, MainScreen keeps its state.
      home: ValueListenableBuilder<bool>(
        valueListenable: QuickCaptureController.instance.overlayMode,
        builder: (context, overlay, _) {
          if (overlay) return const QuickCaptureOverlay();
          // mainScreenHostKey: the same live MainScreen element reparents into
          // the overlay's window ghost and back — one-frame move, state kept.
          final main = kPreviewMode
              ? const PreviewFirstRun() as Widget
              : KeyedSubtree(
                  key: QuickCaptureController.mainScreenHostKey,
                  child: const MainScreen(),
                );
          return ValueListenableBuilder<bool>(
            valueListenable: QuickCaptureController.instance.inAppCapture,
            builder: (context, inApp, __) => Stack(children: [
              main,
              if (inApp) const QuickCaptureOverlay(inApp: true),
            ]),
          );
        },
      ),
    );
  }
}
