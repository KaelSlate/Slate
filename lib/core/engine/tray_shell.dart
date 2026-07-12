import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../state/local_prefs.dart';
import 'quick_capture_controller.dart';
import 'slate_core_bridge.dart';

/// Tray residency + launch-at-login. The capture hotkey is the product's
/// core promise, so Slate lives in the tray: closing the window (X) hides it,
/// the engine and hotkey stay alive; quitting is an explicit tray action.
/// Autostart runs the exe with --hidden — at login only the tray icon and the
/// hotkey exist until the first summon.
class TrayShell with TrayListener {
  TrayShell._();
  static final TrayShell instance = TrayShell._();

  /// Runner-to-Dart requests. "quitRequested" = a newer instance is taking
  /// over (single-instance handover in main.cpp) — flush and die quietly.
  static const _shell = MethodChannel('slate/shell');

  Future<void> init() async {
    _shell.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'quitRequested':
          await quit();
        case 'showRequested':
          await openApp();
      }
      return null;
    });
    launchAtStartup.setup(
      appName: 'Slate',
      appPath: Platform.resolvedExecutable,
      args: ['--hidden'],
    );
    // Release builds own the registry path (fresh across releases + honors
    // the tray toggle). Dev/profile runs must NOT hijack autostart onto a
    // build\ exe that dies at the next flutter clean.
    if (kReleaseMode) {
      try {
        if (LocalPrefs.instance.autostart) {
          await launchAtStartup.enable();
        } else {
          await launchAtStartup.disable();
        }
      } catch (e) {
        debugPrint('tray: autostart setup failed: $e');
      }
    }

    trayManager.addListener(this);
    await trayManager.setIcon('assets/icons/tray_icon.ico');
    await trayManager.setToolTip(
        'Slate — ${QuickCaptureController.instance.hotkeyLabel} to capture');
    await _rebuildMenu();
  }

  Future<void> _rebuildMenu() async {
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'Open Slate'),
      MenuItem(
          key: 'capture',
          label:
              'Quick Capture (${QuickCaptureController.instance.hotkeyLabel})'),
      MenuItem.separator(),
      MenuItem.checkbox(
        key: 'autostart',
        label: 'Launch at startup',
        checked: LocalPrefs.instance.autostart,
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit Slate'),
    ]));
  }

  Future<void> openApp() async {
    final capture = QuickCaptureController.instance;
    if (capture.overlayMode.value || capture.inAppCapture.value) {
      capture.dismissTick.value++;
      return;
    }
    // Self-heal: whatever a crashed/raced morph left behind (cloak, alpha 0,
    // DWM transitions off), opening the app must always produce a REAL
    // window. All idempotent no-ops on a healthy window.
    await capture.healWindowState();
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    try {
      SlateCore().shutdownEngine(); // drain writes + WAL checkpoint
    } finally {
      await trayManager.destroy();
      await windowManager.hide();
      exit(0);
    }
  }

  @override
  void onTrayIconMouseDown() => openApp();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'open':
        await openApp();
      case 'capture':
        await QuickCaptureController.instance.summon();
      case 'autostart':
        final next = !LocalPrefs.instance.autostart;
        LocalPrefs.instance.autostart = next;
        if (kReleaseMode) {
          try {
            next
                ? await launchAtStartup.enable()
                : await launchAtStartup.disable();
          } catch (e) {
            debugPrint('tray: autostart toggle failed: $e');
          }
        }
        await _rebuildMenu();
      case 'quit':
        await quit();
    }
  }
}
