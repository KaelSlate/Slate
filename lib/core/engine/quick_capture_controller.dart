import 'dart:ffi';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

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

  /// False when every chord in the chain was taken: the welcome overlay and
  /// the tray then stop advertising a chord that does nothing — the one lie
  /// this label used to tell.
  bool hotkeyActive = true;

  /// Hosts of an IN-APP capture input (the shell's overview pill, the day
  /// view's own) register a closer here. The chord shuts them all before it
  /// raises the window pill — one capture instance at a time, always.
  /// Each closer must be a safe no-op when its input isn't open.
  final List<VoidCallback> _inAppClosers = [];

  void addInAppCloser(VoidCallback close) => _inAppClosers.add(close);
  void removeInAppCloser(VoidCallback close) => _inAppClosers.remove(close);

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
      hotkeyActive = true;
      debugPrint('quick capture: registered ${c.label}');
      return;
    }
    hotkeyActive = false;
    debugPrint('quick capture: no free chord — hotkey disabled');
  }

  /// The chord. ONE host, always: the separate always-on-top pill window.
  ///
  /// The pill belongs to the SCREEN, not to the window — the lesson the whole
  /// morph saga (rounds 1-8) was resolved by. An in-canvas pill rides the main
  /// window, so it lands somewhere different depending on where that window
  /// happens to be, and dragging the window part-way off-screen drags the pill
  /// off with it. Gating in-canvas on maximized/fullscreen only narrowed that
  /// bug; it also forked the chord's behaviour in two — Enter dismissed in one
  /// host and never in the other, Shift+Enter worked in one and was dead in the
  /// other. One host is the only way those can't drift apart again.
  ///
  /// (Over a foreign window there is nothing Flutter could blur anyway, so the
  /// lens honestly becomes a body — a platform limit, not a choice.)
  ///
  /// `C` and the day-cell «+» keep the in-canvas pill: those are a different
  /// gesture — local, aimed at the day you're looking at, and they belong to
  /// the window by definition.
  ///
  /// No focus/state query first: it made the chord async for nothing, and a
  /// stale answer would make it silently dead. The chord ALWAYS gives a pill.
  /// PillWindow::ShowPill toggles itself (hides when visible, Raycast-style).
  ///
  /// The reverse direction needs no guard — while the pill window is foreground
  /// the main window receives no key events at all, so `C` cannot fire.
  Future<void> _summon() async {
    // Copied: a closer may unregister mid-iteration (a view disposing).
    for (final close in List<VoidCallback>.of(_inAppClosers)) {
      close();
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
