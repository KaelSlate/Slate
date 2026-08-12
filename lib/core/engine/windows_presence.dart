import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

/// Is anyone there, and would interrupting them be rude?
///
/// Windows answers both questions through ONE call, `SHQueryUserNotificationState`,
/// which is also the contract Microsoft sets for apps that draw their own
/// notification UI: ask before every show, and only speak on
/// `acceptsNotifications`. It already folds in the locked screen, the screen
/// saver, a full-screen game, presentation mode and Focus Assist — which is why
/// this feature needs no power-broadcast or session plumbing on the C++ side.
///
/// There is no event for any of it (the OS explicitly does not notify when a
/// full-screen app starts), so it is polled at the moment of the decision and
/// never cached.
///
/// Same `dart:ffi` shape the capture chord already uses on user32
/// (quick_capture_controller.dart) — no plugin, no channel, no second engine.
enum UserNotificationState {
  /// Locked, screen saver, or the session is not the active one.
  notPresent(1),

  /// A full-screen app is up (not exclusive D3D).
  busy(2),

  /// A full-screen exclusive D3D app — a game.
  runningD3dFullScreen(3),

  presentationMode(4),

  /// The only state in which we are allowed to appear.
  acceptsNotifications(5),

  /// Focus Assist / Quiet Hours. Critical only, and a task is never critical.
  quietTime(6),

  /// Full-screen Store app.
  app(7);

  const UserNotificationState(this.code);
  final int code;

  static UserNotificationState fromCode(int code) {
    for (final s in UserNotificationState.values) {
      if (s.code == code) return s;
    }
    // Unknown future state: treat as "go ahead" rather than muting the feature
    // on a Windows build we have never seen.
    return UserNotificationState.acceptsNotifications;
  }
}

typedef _ShQueryStateNative = Int32 Function(Pointer<Int32>);
typedef _ShQueryStateDart = int Function(Pointer<Int32>);

typedef _GetLastInputInfoNative = Int32 Function(Pointer<Uint32>);
typedef _GetLastInputInfoDart = int Function(Pointer<Uint32>);

typedef _GetTickCount64Native = Uint64 Function();
typedef _GetTickCount64Dart = int Function();

class WindowsPresence {
  WindowsPresence._();
  static final WindowsPresence instance = WindowsPresence._();

  _ShQueryStateDart? _queryState;
  _GetLastInputInfoDart? _lastInput;
  _GetTickCount64Dart? _tickCount;
  bool _bound = false;

  /// Binding failure is never fatal and never silences reminders: a machine
  /// where the probe cannot load simply gets the permissive answer. Losing a
  /// reminder is worse than showing one at an imperfect moment.
  void _bind() {
    if (_bound) return;
    _bound = true;
    try {
      final shell32 = DynamicLibrary.open('shell32.dll');
      _queryState = shell32
          .lookupFunction<_ShQueryStateNative, _ShQueryStateDart>(
              'SHQueryUserNotificationState');
      final user32 = DynamicLibrary.open('user32.dll');
      _lastInput = user32
          .lookupFunction<_GetLastInputInfoNative, _GetLastInputInfoDart>(
              'GetLastInputInfo');
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      _tickCount = kernel32
          .lookupFunction<_GetTickCount64Native, _GetTickCount64Dart>(
              'GetTickCount64');
    } catch (e) {
      debugPrint('presence: probe unavailable, staying permissive ($e)');
    }
  }

  /// What Windows thinks of interrupting right now.
  UserNotificationState state() {
    _bind();
    final fn = _queryState;
    if (fn == null) return UserNotificationState.acceptsNotifications;
    return using((arena) {
      final out = arena<Int32>();
      final hr = fn(out);
      if (hr != 0) return UserNotificationState.acceptsNotifications;
      return UserNotificationState.fromCode(out.value);
    });
  }

  /// True only when Windows would deliver its own notification.
  bool get acceptsNotifications =>
      state() == UserNotificationState.acceptsNotifications;

  /// Milliseconds since the last keyboard or mouse input in THIS session.
  ///
  /// Deliberately coarse: a locked screen, a sleeping laptop and a person who
  /// walked away all read as a long idle, which is exactly the granularity the
  /// day glance needs. Returns null when the probe is unavailable.
  int? idleMs() {
    _bind();
    final info = _lastInput;
    final ticks = _tickCount;
    if (info == null || ticks == null) return null;
    return using((arena) {
      // LASTINPUTINFO { UINT cbSize; DWORD dwTime; } — two 32-bit fields.
      final buf = arena<Uint32>(2);
      buf[0] = 8;
      if (info(buf) == 0) return null;
      final idle = ticks() - buf[1];
      // GetTickCount64 outruns the 32-bit dwTime after ~49 days of uptime;
      // a negative or absurd result means the wrap, not a real idle.
      return (idle < 0 || idle > 0xFFFFFFFF) ? null : idle;
    });
  }
}
