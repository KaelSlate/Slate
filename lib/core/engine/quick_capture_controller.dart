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
        keyDownHandler: (_) => _shellChannel.invokeMethod('showPill'),
      );
      hotkeyLabel = c.label;
      debugPrint('quick capture: registered ${c.label}');
      return;
    }
    debugPrint('quick capture: no free chord — hotkey disabled');
  }

  bool _chordFree(int mods, int vk) {
    const probeId = 0x5157; // 'QW'
    if (_winRegisterHotKey(0, probeId, mods, vk) == 0) return false;
    _winUnregisterHotKey(0, probeId);
    return true;
  }
}
