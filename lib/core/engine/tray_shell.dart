import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../state/crash_log.dart';
import '../state/export_service.dart';
import '../state/local_prefs.dart';
import '../state/task_state.dart';
import 'capture_destination.dart';
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

  /// Injected from main() so tray actions can mutate + notify the live UI.
  TaskState? taskState;

  Future<void> init() async {
    _shell.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'quitRequested':
          await quit();
        case 'showRequested':
          await openApp();
        case 'pillCapture':
          _handlePillCapture(call.arguments);
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
    // First-run sample tasks still around → offer a one-click sweep.
    final demoIds = LocalPrefs.instance.demoIds.toSet();
    final hasDemo = demoIds.isNotEmpty &&
        (taskState?.tasks.any((t) => demoIds.contains(t.id)) ?? false);
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'open', label: 'Open Slate'),
      MenuItem(
          key: 'capture',
          label:
              'Quick Capture (${QuickCaptureController.instance.hotkeyLabel})'),
      MenuItem.separator(),
      MenuItem(key: 'export', label: 'Export data…'),
      MenuItem(key: 'report', label: 'Report a problem'),
      MenuItem.separator(),
      if (hasDemo) MenuItem(key: 'clear_demo', label: 'Clear sample tasks'),
      MenuItem.checkbox(
        key: 'autostart',
        label: 'Launch at startup',
        checked: LocalPrefs.instance.autostart,
      ),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: 'Quit Slate'),
    ]));
  }

  /// A capture submitted in the SEPARATE pill window (its own isolate) arrives
  /// here as the serialized ParseResult. The DB write lives in THIS isolate —
  /// one engine, one DB — and creating through taskState refreshes the live UI.
  void _handlePillCapture(dynamic args) {
    if (args is! Map) return;
    final m = args.cast<dynamic, dynamic>();
    final result = ParseResult(
      cleanTitle: (m['cleanTitle'] as String?) ?? '',
      startTime: m['startTime'] as int?,
      endTime: m['endTime'] as int?,
      priority: (m['priority'] as int?) ?? 0,
      tags: (m['tags'] as List?)?.cast<String>() ?? const [],
      dateKind: (m['dateKind'] as int?) ?? 0,
      dateA: (m['dateA'] as int?) ?? -1,
      dateB: (m['dateB'] as int?) ?? -1,
      dateC: (m['dateC'] as int?) ?? -1,
    );
    final dest = resolveCapture(result, DateTime.now());
    taskState?.createCaptured(result.cleanTitle, result, dest);
  }

  Future<void> openApp() async {
    // The main window is a plain app window now — the capture pill is a
    // separate window, so there is no morph to wait out or heal.
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
  void onTrayIconRightMouseDown() async {
    await _rebuildMenu(); // live items (sample sweep) reflect current state
    await trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'open':
        await openApp();
      case 'capture':
        await _shell.invokeMethod('showPill'); // separate pill window, no morph
      case 'export':
        try {
          final file = await exportAllTasks(SlateCore());
          // Explorer with the fresh export selected — the feedback IS the file.
          await Process.start('explorer.exe', ['/select,${file.path}']);
        } catch (e) {
          debugPrint('tray: export failed: $e');
        }
      case 'report':
        try {
          // Testers can't be asked to hunt for files — open the log folder.
          final path = CrashLog.folderPath ??
              '${(await getApplicationDocumentsDirectory()).path}'
                  '\\slate_data\\logs';
          Directory(path).createSync(recursive: true);
          CrashLog.dumpTrace(); // fresh slate_trace.txt lands in that folder
          await Process.start('explorer.exe', [path]);
        } catch (e) {
          debugPrint('tray: report open failed: $e');
        }
      case 'clear_demo':
        taskState?.clearDemoTasks();
        await _rebuildMenu();
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
