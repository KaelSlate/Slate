import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'spatial_zoom_engine.dart';

// user32 probe: hotkey_manager's RegisterHotKey never reports failure, so we
// test each chord ourselves before handing it to the plugin.
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final int Function(int, int, int, int) _winRegisterHotKey = _user32
    .lookupFunction<Int32 Function(IntPtr, Int32, Uint32, Uint32),
        int Function(int, int, int, int)>('RegisterHotKey');
final int Function(int, int) _winUnregisterHotKey = _user32.lookupFunction<
    Int32 Function(IntPtr, Int32), int Function(int, int)>('UnregisterHotKey');

class _Chord {
  final int mods; // MOD_* bitmask for the probe
  final int vk;
  final PhysicalKeyboardKey key;
  final List<HotKeyModifier> modifiers;
  final String label;
  const _Chord(this.mods, this.vk, this.key, this.modifiers, this.label);
}

/// Global quick capture — the Raycast move, done right: the hotkey raises a
/// SEPARATE always-on-top pill window (its own Flutter engine, see
/// pill_window.dart + windows/runner/pill_window.cpp). The main app window is
/// never touched — no morph, so none of the rounds 1-8 fragility (cold
/// swapchain, jerk, maximize desync, taskbar flash) can occur.
///
/// This controller now does exactly one thing: find a free system chord and
/// point it at the runner's `showPill`. Everything else — the window morph, the
/// ghost, the in-window overlay — is gone.
class QuickCaptureController {
  QuickCaptureController._();
  static final QuickCaptureController instance = QuickCaptureController._();

  /// Runner channel — the capture hotkey raises the separate pill window.
  static const _shellChannel = MethodChannel('slate/shell');

  /// Human-readable registered chord — tray menu/tooltip/hints show it.
  String hotkeyLabel = 'Alt+Space';

  /// Set by the shell (pulse_layer) while the main screen is mounted. Called
  /// when the chord fires and Slate is ALREADY in front: there the pill can be
  /// an in-canvas real lens instead of the separate window's opaque body.
  /// Returns true if it handled the summon; false → fall back to the window
  /// (welcome/warmup up, not mounted, …) so the chord is never dead.
  bool Function()? onInAppSummon;

  static const _chords = [
    // Alt+Space: THE two-key summon chord (Spotlight/Raycast/PowerToys Run).
    // Probed first — PowerToys Run may own it, then we fall down the chain.
    _Chord(0x1, 0x20, PhysicalKeyboardKey.space, [HotKeyModifier.alt],
        'Alt+Space'),
    _Chord(0x3, 0x20, PhysicalKeyboardKey.space,
        [HotKeyModifier.control, HotKeyModifier.alt], 'Ctrl+Alt+Space'),
    _Chord(0x3, 0x53, PhysicalKeyboardKey.keyS,
        [HotKeyModifier.control, HotKeyModifier.alt], 'Ctrl+Alt+S'),
  ];

  Future<void> init() async {
    await hotKeyManager.unregisterAll();
    for (final c in _chords) {
      if (!_chordFree(c.mods, c.vk)) {
        debugPrint('quick capture: ${c.label} is taken, trying next');
        continue;
      }
      await hotKeyManager.register(
        HotKey(key: c.key, modifiers: c.modifiers, scope: HotKeyScope.system),
        // Separate pill window: the runner raises it instantly.
        keyDownHandler: (_) => _summon(),
      );
      hotkeyLabel = c.label;
      debugPrint('quick capture: registered ${c.label}');
      return;
    }
    debugPrint('quick capture: no free chord — hotkey disabled');
  }

  /// The chord. ONE capture object, summoned into the host that can render it
  /// honestly WITHOUT ever tying the pill to the window's position:
  ///
  ///   Slate FILLS the screen (maximized/fullscreen)
  ///                   → the IN-CANVAS pill. Flutter can sample its own scene,
  ///                     so the glass is a REAL lens — the same material as the
  ///                     day pill. Safe here precisely because the window's
  ///                     bottom IS the screen's bottom: the pill lands exactly
  ///                     where it always does. No window is touched.
  ///   anything else   → the separate always-on-top pill window.
  ///
  /// Windowed is NOT in-canvas on purpose: an in-canvas pill rides the window,
  /// so dragging the window part-way off-screen would drag the pill off with it.
  /// The global pill must be independent of the window — it belongs to the
  /// screen. (Over foreign windows there is also nothing Flutter can blur, so
  /// there the lens honestly becomes a body — a platform limit.)
  ///
  /// The chord TOGGLES the one capture (the pill window already toggles itself
  /// — PillWindow::ShowPill hides when visible, Raycast-style — so the in-canvas
  /// host must behave the same or the same chord would mean two things). It
  /// never stacks a second input on top of an open one.
  ///
  /// The reverse direction needs no guard — while the pill window is foreground
  /// the main window receives no key events at all, so `C` cannot fire.
  Future<void> _summon() async {
    // Queried, not cached: a stale focus flag would make the chord silently
    // dead from another app, and window_manager's focus events are known to
    // miss transitions (see the maximize resync note in pulse_layer).
    final overSlate = await windowManager.isFocused();
    if (overSlate) {
      // Only when the window fills the screen does the in-canvas pill land in
      // the same place the global one would — otherwise it would be glued to a
      // window the user can drag anywhere (or off-screen).
      final fillsScreen = (await windowManager.isMaximized()) ||
          (await windowManager.isFullScreen());
      if (fillsScreen && (onInAppSummon?.call() ?? false)) return;
      // A pill is already open somewhere — never stack a second one on it.
      if (StaircaseState.isComposingTask) return;
    }
    await _shellChannel.invokeMethod('showPill');
  }

  bool _chordFree(int mods, int vk) {
    const probeId = 0x5157; // 'QW'
    if (_winRegisterHotKey(0, probeId, mods, vk) == 0) return false;
    _winUnregisterHotKey(0, probeId);
    return true;
  }
}
