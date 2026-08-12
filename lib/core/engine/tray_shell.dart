import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../state/app_dirs.dart';
import '../state/crash_log.dart';
import '../state/export_service.dart';
import '../sfx/sfx.dart';
import '../state/local_prefs.dart';
import '../state/task_state.dart';
import 'capture_destination.dart';
import 'quick_capture_controller.dart';
import 'reminder_scheduler.dart';
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
        case 'notifyAction':
          _handleNotifyAction(call.arguments);
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
    // Honest chord only: if none registered, don't advertise a dead one.
    await trayManager.setToolTip(QuickCaptureController.instance.hotkeyActive
        ? 'Slate — ${QuickCaptureController.instance.hotkeyLabel} to capture'
        : 'Slate');
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
          label: QuickCaptureController.instance.hotkeyActive
              ? 'Quick Capture (${QuickCaptureController.instance.hotkeyLabel})'
              : 'Quick Capture'),
      MenuItem.separator(),
      MenuItem(key: 'export', label: 'Export data…'),
      MenuItem(key: 'report', label: 'Report a problem'),
      MenuItem.separator(),
      if (hasDemo) MenuItem(key: 'clear_demo', label: 'Clear sample tasks'),
      MenuItem.checkbox(
        key: 'reminders',
        label: 'Reminders',
        checked: LocalPrefs.instance.reminders,
      ),
      MenuItem.checkbox(
        key: 'reminder_sound',
        label: 'Reminder sound',
        checked: LocalPrefs.instance.reminderSound,
      ),
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

  // ── Reminders ─────────────────────────────────────────────────────────────

  ReminderScheduler? _reminders;

  /// Is Slate's own window up and focused? Fed by the window listener in
  /// main(). When it is, a reminder card would be telling the person something
  /// already on the screen in front of them.
  bool windowFocused = false;

  /// Starts the loop that decides when Slate speaks. Called once from _boot,
  /// after the tray exists — the process is already resident, so this is the
  /// only thing the feature needs to stay alive all day.
  void startReminders() {
    if (_reminders != null) return;
    _reminders = ReminderScheduler.live(
      core: SlateCore(),
      present: _presentCards,
      chime: (priority) {
        // Two switches, not one: someone on a call wants silence, not the whole
        // feature gone.
        if (LocalPrefs.instance.reminderSound) {
          Sfx.reminderDue(priority: priority);
        }
      },
      enabled: () => LocalPrefs.instance.reminders,
      // Kept in sync by the window listener rather than asked on every tick:
      // window_manager's isFocused() is async, and a scheduler decision cannot
      // wait on a round trip.
      appInFocus: () => windowFocused,
    );
    _reminders!.start();
  }

  /// A capture or an edit may have moved the next moment closer than the sleep
  /// the scheduler is currently sitting on.
  void remindersChanged() => _reminders?.reschedule();

  /// Hands the cards to the runner, which owns the notify window. The BOOL that
  /// comes back is load-bearing: false means Windows refused the moment (Focus
  /// Assist, a game, a locked screen) and the reminder must stay unspoken.
  Future<bool> _presentCards(
      List<ReminderCard> cards, bool merging, int lifeMs) async {
    try {
      final ok = await _shell.invokeMethod<bool>('notify', <String, dynamic>{
        'cards': cards.map((c) => c.toMap()).toList(),
        'lifeMs': lifeMs,
      });
      return ok ?? false;
    } catch (e) {
      debugPrint('reminders: present failed: $e');
      return false;
    }
  }

  /// A tap on the card, or the card leaving. The window is a renderer — every
  /// consequence happens here, in the isolate that owns the DB and the undo.
  void _handleNotifyAction(dynamic args) {
    if (args is! Map) return;
    final action = args['action'] as String?;
    if (action == 'closed') {
      _reminders?.cardClosed();
      return;
    }
    if (action == 'done') {
      final id = args['id'] as String?;
      final state = taskState;
      if (id == null || state == null) return;
      for (final t in state.tasks) {
        if (t.id == id) {
          // The same funnel as every checkbox in the app: same chime, same undo.
          if (!t.isCompleted) state.toggleTask(t);
          break;
        }
      }
      return;
    }
    if (action == 'open') {
      openApp();
    }
  }

  Future<void> openApp() async {
    // The main window is a plain app window now — the capture pill is a
    // separate window, so there is no morph to wait out or heal.
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    try {
      // Today's backup leaves with the freshest state (tiny JSON, ~ms).
      await taskState?.writeSafetyBackup(refresh: true);
    } catch (_) {/* quitting must never hang on the safety net */}
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
              '${(await AppDirs.dataDir()).path}\\logs';
          Directory(path).createSync(recursive: true);
          CrashLog.dumpTrace(); // fresh slate_trace.txt lands in that folder
          await Process.start('explorer.exe', [path]);
        } catch (e) {
          debugPrint('tray: report open failed: $e');
        }
      case 'clear_demo':
        taskState?.clearDemoTasks();
        await _rebuildMenu();
      case 'reminders':
        LocalPrefs.instance.reminders = !LocalPrefs.instance.reminders;
        // Off means off NOW, not after the current card times out.
        if (!LocalPrefs.instance.reminders) {
          await _shell.invokeMethod('notifyHide');
        }
        await _rebuildMenu();
      case 'reminder_sound':
        LocalPrefs.instance.reminderSound = !LocalPrefs.instance.reminderSound;
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
