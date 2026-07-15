import 'dart:async';
import 'dart:ffi' hide Size;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';
import '../state/crash_log.dart';
import '../theme/app_theme.dart';
import 'spatial_zoom_engine.dart';

// user32 probe: hotkey_manager's RegisterHotKey never reports failure, so we
// test each chord ourselves before handing it to the plugin.
final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final int Function(int, int, int, int) _winRegisterHotKey = _user32
    .lookupFunction<Int32 Function(IntPtr, Int32, Uint32, Uint32),
        int Function(int, int, int, int)>('RegisterHotKey');
final int Function(int, int) _winUnregisterHotKey =
    _user32.lookupFunction<Int32 Function(IntPtr, Int32), int Function(int, int)>(
        'UnregisterHotKey');

// Direct Win32 for the pieces window_manager gets wrong on Windows:
// show(inactive:) still calls SetForegroundWindow, and nothing exposes
// Z-order or DWM attributes. See summon()/finishAndRestore().
final int Function(Pointer<Utf16>, Pointer<Utf16>) _winFindWindow =
    _user32.lookupFunction<IntPtr Function(Pointer<Utf16>, Pointer<Utf16>),
        int Function(Pointer<Utf16>, Pointer<Utf16>)>('FindWindowW');
final int Function(int) _winIsWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindow');
final int Function() _winGetForegroundWindow = _user32
    .lookupFunction<IntPtr Function(), int Function()>('GetForegroundWindow');
final int Function(int) _winSetForegroundWindow = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'SetForegroundWindow');
final int Function(int, int, int, int, int, int, int) _winSetWindowPos =
    _user32.lookupFunction<
        Int32 Function(IntPtr, IntPtr, Int32, Int32, Int32, Int32, Uint32),
        int Function(int, int, int, int, int, int, int)>('SetWindowPos');
final int Function(int, int) _winShowWindow = _user32.lookupFunction<
    Int32 Function(IntPtr, Int32), int Function(int, int)>('ShowWindow');
final int Function(int, int) _winGetWindowLongPtr = _user32.lookupFunction<
    IntPtr Function(IntPtr, Int32), int Function(int, int)>('GetWindowLongPtrW');
final int Function(int) _winIsIconic = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsIconic');
final int Function(int) _winIsZoomed = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsZoomed');
final int Function(int) _winIsWindowVisible = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>('IsWindowVisible');

final DynamicLibrary _dwmapi = DynamicLibrary.open('dwmapi.dll');
final int Function(int, int, Pointer<Int32>, int) _dwmSetWindowAttribute =
    _dwmapi.lookupFunction<
        Int32 Function(IntPtr, Uint32, Pointer<Int32>, Uint32),
        int Function(int, int, Pointer<Int32>, int)>('DwmSetWindowAttribute');

final int Function(Pointer<_WinPoint>) _winGetCursorPos = _user32
    .lookupFunction<Int32 Function(Pointer<_WinPoint>),
        int Function(Pointer<_WinPoint>)>('GetCursorPos');
final int Function(Pointer<_WinRect>, int) _winMonitorFromRect =
    _user32.lookupFunction<IntPtr Function(Pointer<_WinRect>, Uint32),
        int Function(Pointer<_WinRect>, int)>('MonitorFromRect');
final int Function(int, Pointer<_WinMonitorInfo>) _winGetMonitorInfo =
    _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_WinMonitorInfo>),
        int Function(int, Pointer<_WinMonitorInfo>)>('GetMonitorInfoW');
final int Function(int, Pointer<_WinRect>) _winGetWindowRect =
    _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_WinRect>),
        int Function(int, Pointer<_WinRect>)>('GetWindowRect');

final class _WinPoint extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class _WinRect extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

final class _WinMonitorInfo extends Struct {
  @Uint32()
  external int cbSize;
  external _WinRect rcMonitor;
  external _WinRect rcWork;
  @Uint32()
  external int dwFlags;
}

final class _WinWindowPlacement extends Struct {
  @Uint32()
  external int length;
  @Uint32()
  external int flags;
  @Uint32()
  external int showCmd;
  external _WinPoint ptMinPosition;
  external _WinPoint ptMaxPosition;
  external _WinRect rcNormalPosition;
}

final int Function(int, Pointer<_WinWindowPlacement>) _winGetWindowPlacement =
    _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_WinWindowPlacement>),
        int Function(int, Pointer<_WinWindowPlacement>)>('GetWindowPlacement');
final int Function(int, Pointer<_WinWindowPlacement>) _winSetWindowPlacement =
    _user32.lookupFunction<Int32 Function(IntPtr, Pointer<_WinWindowPlacement>),
        int Function(int, Pointer<_WinWindowPlacement>)>('SetWindowPlacement');

const int _kSwShowNoActivate = 8; // SW_SHOWNA
const int _kSwShowNormalNoActivate = 4; // SW_SHOWNOACTIVATE (placement)
const int _kSwShowMinNoActive = 7; // SW_SHOWMINNOACTIVE (placement)
const int _kSwShowMaximized = 3; // SW_SHOWMAXIMIZED (placement)
const int _kWpfRestoreToMaximized = 2;
const int _kSwpNoSizeNoMoveNoActivate = 0x0001 | 0x0002 | 0x0010;
const int _kSwpNoZOrderNoActivate = 0x0004 | 0x0010;
const int _kSwpNoActivate = 0x0010;
const int _kHwndTopmost = -1;
const int _kHwndNoTopmost = -2;
const int _kWsExTopmost = 0x8;
const int _kGwlExStyle = -20;
const int _kDwmTransitionsForceDisabled = 3;
const int _kDwmCloak = 13;

class _Chord {
  final int mods; // MOD_* bitmask for the probe
  final int vk;
  final PhysicalKeyboardKey key;
  final List<HotKeyModifier> modifiers;
  final String label;
  const _Chord(this.mods, this.vk, this.key, this.modifiers, this.label);
}

/// Global quick capture — the Raycast move, one window edition.
///
/// Hotkey from anywhere in the OS:
/// - Slate focused → an in-app capture scene over the current view. The
///   window is NOT touched (no hide/reshow dance).
/// - Slate in background/minimized/tray → the single main window morphs into
///   a Spotlight-style overlay on the cursor's monitor, then restores its
///   exact prior state. A VISIBLE window morphs atomically (dirty tree +
///   one SetWindowPos = the new root presents inside the resize, nothing
///   blinks); hidden/minimized transitions run at alpha 1/255 until fresh
///   frames present at the new size. Never alpha 0 and never DWM cloak
///   while RESIZING: under both (pixel-verified) the embedder's synchronous
///   resize never presents a frame at the new size and the screen keeps a
///   stale-size frame forever — the "pill shrunk into the bottom-right
///   corner" bug. Alpha 1/255 is invisible to the eye but the window stays
///   presentable. A bare (uncovered) show instead composites a resized
///   swapchain before its first paint as a bright flash ("white blink").
class QuickCaptureController with WindowListener {
  QuickCaptureController._();
  static final QuickCaptureController instance = QuickCaptureController._();

  /// MainScreen rides this key between the app root and the overlay's window
  /// ghost — GlobalKey reparenting moves the LIVE element in one frame (state,
  /// scroll positions and all) instead of a full remount, so the morph has no
  /// heavy rebuild frame to blink through.
  static final GlobalKey mainScreenHostKey = GlobalKey();

  /// true → the app root shows the capture overlay instead of MainScreen.
  final ValueNotifier<bool> overlayMode = ValueNotifier(false);

  /// true → capture scene stacked over MainScreen (window untouched).
  final ValueNotifier<bool> inAppCapture = ValueNotifier(false);

  /// Bumped when the capture scene must play its exit (blur, repeat hotkey).
  final ValueNotifier<int> dismissTick = ValueNotifier(0);

  /// Human-readable registered chord — tray menu/tooltip show it.
  String hotkeyLabel = 'Alt+Space';

  /// All geometry below is PHYSICAL pixels straight from Win32. The plugin's
  /// setBounds/getBounds funnel every rect through devicePixelRatio AND the
  /// 900x600 logical minimum that DefWindowProc enforces on ANY SetWindowPos
  /// of a WS_THICKFRAME window — on scaled/small displays the overlay came
  /// out the wrong size (the "pill glued to the window / mangled in the
  /// corner" family). Native units, no conversions, no clamps.
  Rect? _priorRect;
  bool _priorMinimized = false;
  bool _priorVisible = true;
  bool _priorFocused = false;

  /// The window carried WS_MAXIMIZE into the morph (a hidden or background
  /// window KEEPS the zoomed style). SetWindowPos is swallowed by a zoomed
  /// window — the overlay came up "stretched in the corner" at the maximized
  /// rect — so zoomed entries/exits go through SetWindowPlacement instead.
  bool _priorZoomed = false;

  /// The window was minimized FROM a maximized state — un-minimizing must
  /// give the maximized window back, so the flag is re-planted on restore.
  bool _priorRestoreToMax = false;
  bool _busy = false;

  /// Hotkey pressed while a morph/restore was in flight — replay it once the
  /// machinery is free instead of eating the press.
  bool _pendingSummon = false;

  /// The morph swallowed a FOCUSED windowed Slate: the overlay paints a live
  /// MainScreen "ghost" at the window's old spot so the app never visibly
  /// disappears. Physical px; null = no ghost.
  Rect? ghostRect;

  /// Overlay window rect (physical px) — the ghost maps itself with it.
  Rect? overlayRect;

  int _hwnd = 0;

  /// Foreground window at summon — the app the user was in. THE anchor:
  /// focus goes back to it on dismiss, and Slate re-enters Z directly under
  /// it. (A raw GW_HWNDPREV neighbor is a trap: owned/IME helper windows
  /// cluster ABOVE an app's main window, so anchoring to one landed Slate
  /// on top of the very editor the user was reading.)
  int _priorForeground = 0;

  int get _windowHandle {
    if (_hwnd == 0 || _winIsWindow(_hwnd) == 0) {
      final cls = 'FLUTTER_RUNNER_WIN32_WINDOW'.toNativeUtf16();
      final title = 'Slate'.toNativeUtf16();
      _hwnd = _winFindWindow(cls, title);
      calloc.free(cls);
      calloc.free(title);
    }
    return _hwnd;
  }

  void _dwmFlag(int attribute, bool on) {
    final h = _windowHandle;
    if (h == 0) return;
    final v = calloc<Int32>()..value = on ? 1 : 0;
    _dwmSetWindowAttribute(h, attribute, v, 4);
    calloc.free(v);
  }

  /// DWM minimize/restore animations play on the WINDOW — which during a
  /// morph is the pill. Forced off for the whole dance, back on after.
  void _transitionsDisabled(bool disabled) =>
      _dwmFlag(_kDwmTransitionsForceDisabled, disabled);

  /// Cloak = invisible on screen but still rendered/composited by DWM —
  /// unlike opacity 0 (layered alpha), frames reach the Alt+Tab thumbnail.
  void _cloaked(bool cloaked) => _dwmFlag(_kDwmCloak, cloaked);

  void _showNoActivate() {
    final h = _windowHandle;
    if (h != 0) _winShowWindow(h, _kSwShowNoActivate);
  }

  void _captureZOrder() {
    _priorForeground = _winGetForegroundWindow();
  }

  int _zAnchor() {
    final h = _windowHandle;
    var after = _priorForeground; // the app the user was working in
    if (after == 0 || after == h || _winIsWindow(after) == 0) {
      final fg = _winGetForegroundWindow();
      after = fg == h ? 0 : fg;
    }
    return after == h ? 0 : after;
  }

  /// Hiding the foreground pill does NOT reliably reassign the foreground —
  /// the hidden window can stay "active" (shown later = surfaces focused on
  /// top of the user's editor; minimized = ghost focus). Hand it back to the
  /// app the pill was summoned over, the Spotlight contract.
  void _yieldForeground() {
    final h = _windowHandle;
    if (h == 0 || _winGetForegroundWindow() != h) return;
    final anchor = _zAnchor();
    if (anchor != 0) _winSetForegroundWindow(anchor);
  }

  void _restoreZOrder() {
    final h = _windowHandle;
    if (h == 0) return;
    final after = _zAnchor();
    if (after == 0) return;
    _winSetWindowPos(h, after, 0, 0, 0, 0, _kSwpNoSizeNoMoveNoActivate);
  }

  /// THE atomic morph: Z-order + position + size in ONE SetWindowPos, no
  /// activation. The widget tree is dirtied with the destination root right
  /// before this call, so the embedder's synchronous resize builds and
  /// presents that exact tree at the new size INSIDE the call — the screen
  /// jumps from "old root at old rect" to "new root at new rect" with no
  /// intermediate frame. No hide, no opacity dip, nothing to blink.
  void _morphWindow(Rect r, {required int insertAfter}) {
    final h = _windowHandle;
    if (h == 0) return;
    _winSetWindowPos(h, insertAfter, r.left.round(), r.top.round(),
        r.width.round(), r.height.round(), _kSwpNoActivate);
  }

  /// Bring a COLD window up as the pill: behind another app, minimized, or
  /// hidden to tray — anything that is NOT the actively-rendering foreground.
  /// Pixel-proven root of the stretched-pill saga: such a window's embedder
  /// swapchain is stale-sized, so showing + sizing it in one breath leaves
  /// DWM stretching a stale frame (the pill shrunk into the bottom-right
  /// corner). ANY resize performed while the window is already visible
  /// rebuilds the swapchain (typing or a manual drag healed it live). So show
  /// it OFF-SCREEN, resize-nudge it there to rebuild the surface out of sight,
  /// then slide the corrected surface on-screen with a PURE move (no resize
  /// left to flash). One SetWindowPlacement also un-hides / un-minimizes /
  /// un-maximizes it.
  Future<void> _coldMorph(Rect target) async {
    final park = Rect.fromLTWH(target.left - target.width - 320, target.top,
        target.width, target.height);
    final parkNudge =
        Rect.fromLTWH(park.left, park.top, park.width - 2, park.height - 2);
    overlayMode.value = true;
    _placementSet(park, showCmd: _kSwShowNormalNoActivate, restoreToMax: false);
    await _assertRect(park); // forced off-screen even if placement clamps
    await _pumpFrames(2);
    _morphWindow(parkNudge, insertAfter: _kHwndTopmost); // heal nudge, off-screen
    await _pumpFrames(2);
    _morphWindow(park, insertAfter: _kHwndTopmost); // back to full size, off-screen
    await _pumpFrames(2); // corrected surface presented out of sight
    _morphWindow(target, insertAfter: _kHwndTopmost); // pure move on-screen
    await _assertRect(target);
    await _pumpFrames(1);
    await windowManager.focus();
  }

  bool _isTopmost() {
    final h = _windowHandle;
    if (h == 0) return false;
    return (_winGetWindowLongPtr(h, _kGwlExStyle) & _kWsExTopmost) != 0;
  }

  /// Reassert [target] until it sticks (checks first — a no-op when the
  /// atomic morph already landed the exact rect).
  Future<void> _assertRect(Rect target) async {
    for (var i = 0; i < 3; i++) {
      final now = _windowRect();
      if (now != null &&
          (now.left - target.left).abs() < 2 &&
          (now.width - target.width).abs() < 2 &&
          (now.height - target.height).abs() < 2) {
        if (i > 0) CrashLog.trace('assertRect: landed after $i reassert(s)');
        return;
      }
      _setWindowRect(target);
      await _pumpFrames(1);
    }
    CrashLog.trace('assertRect: FAILED $target now=${_windowRect()}');
  }

  /// Plugin setAlwaysOnTop omits SWP_NOACTIVATE, which ACTIVATES the (hidden)
  /// window per SetWindowPos rules — the restored Slate then surfaced
  /// focused over the user's editor. Native, with NOACTIVATE.
  void _setTopmost(bool on) {
    final h = _windowHandle;
    if (h == 0) return;
    _winSetWindowPos(h, on ? _kHwndTopmost : _kHwndNoTopmost, 0, 0, 0, 0,
        _kSwpNoSizeNoMoveNoActivate);
  }

  /// Atomic placement write: geometry + minimized/normal state + the
  /// restore-to-maximized flag in one SYNCHRONOUS call. The old path posted
  /// SC_RESTORE and raced it: the message could land after the overlay was
  /// already revealed, re-maximizing the window under the pill.
  void _placementSet(Rect normal,
      {required int showCmd, required bool restoreToMax}) {
    final h = _windowHandle;
    if (h == 0) return;
    final p = calloc<_WinWindowPlacement>();
    try {
      p.ref.length = sizeOf<_WinWindowPlacement>();
      if (_winGetWindowPlacement(h, p) == 0) return;
      p.ref
        ..flags = restoreToMax ? _kWpfRestoreToMaximized : 0
        ..showCmd = showCmd;
      p.ref.rcNormalPosition
        ..left = normal.left.round()
        ..top = normal.top.round()
        ..right = normal.right.round()
        ..bottom = normal.bottom.round();
      _winSetWindowPlacement(h, p);
    } finally {
      calloc.free(p);
    }
  }

  /// (restoreToMax, normal rect) of the current placement.
  (bool, Rect?) _placementRead() {
    final h = _windowHandle;
    if (h == 0) return (false, null);
    final p = calloc<_WinWindowPlacement>();
    try {
      p.ref.length = sizeOf<_WinWindowPlacement>();
      if (_winGetWindowPlacement(h, p) == 0) return (false, null);
      final r = p.ref.rcNormalPosition;
      return (
        p.ref.flags & _kWpfRestoreToMaximized != 0,
        Rect.fromLTRB(r.left + 0.0, r.top + 0.0, r.right + 0.0, r.bottom + 0.0)
      );
    } finally {
      calloc.free(p);
    }
  }

  /// GetWindowRect, physical px.
  Rect? _windowRect() {
    final h = _windowHandle;
    if (h == 0) return null;
    final rc = calloc<_WinRect>();
    try {
      if (_winGetWindowRect(h, rc) == 0) return null;
      final r = rc.ref;
      return Rect.fromLTRB(
          r.left + 0.0, r.top + 0.0, r.right + 0.0, r.bottom + 0.0);
    } finally {
      calloc.free(rc);
    }
  }

  void _setWindowRect(Rect r) {
    final h = _windowHandle;
    if (h == 0) return;
    _winSetWindowPos(h, 0, r.left.round(), r.top.round(), r.width.round(),
        r.height.round(), _kSwpNoZOrderNoActivate);
  }

  /// Work area of the monitor the cursor is on (Raycast rule), physical px.
  /// Falls back to the primary monitor if the cursor can't be read.
  Rect _overlayRect() {
    final pt = calloc<_WinPoint>();
    final rc = calloc<_WinRect>();
    final mi = calloc<_WinMonitorInfo>();
    try {
      var x = 0, y = 0;
      if (_winGetCursorPos(pt) != 0) {
        x = pt.ref.x;
        y = pt.ref.y;
      }
      rc.ref
        ..left = x
        ..top = y
        ..right = x + 1
        ..bottom = y + 1;
      // 2 = MONITOR_DEFAULTTONEAREST, degrades to primary via the zero rect.
      final mon = _winMonitorFromRect(rc, 2);
      mi.ref.cbSize = sizeOf<_WinMonitorInfo>();
      if (mon != 0 && _winGetMonitorInfo(mon, mi) != 0) {
        final w = mi.ref.rcWork;
        return Rect.fromLTRB(
            w.left + 0.0, w.top + 0.0, w.right + 0.0, w.bottom + 0.0);
      }
      return const Rect.fromLTWH(0, 0, 1920, 1080);
    } finally {
      calloc.free(pt);
      calloc.free(rc);
      calloc.free(mi);
    }
  }

  /// Escape chords, borrowed from Windows while a capture scene is up. See
  /// [_claimDismissKeys].
  HotKey? _escChord;
  HotKey? _escPlain;

  /// Last real placement (physical px). GetWindowRect on a minimized window
  /// reports the off-screen -32000 rect — restoring that would strand the
  /// window.
  Rect? _lastNormalRect;

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
    windowManager.addListener(this);
    _lastNormalRect = _windowRect();
    await hotKeyManager.unregisterAll();
    for (final c in _chords) {
      if (!_chordFree(c.mods, c.vk)) {
        debugPrint('quick capture: ${c.label} is taken, trying next');
        continue;
      }
      await hotKeyManager.register(
        HotKey(key: c.key, modifiers: c.modifiers, scope: HotKeyScope.system),
        keyDownHandler: (_) => summon(),
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

  /// Escape is claimed GLOBALLY (RegisterHotKey) for exactly as long as a
  /// capture scene is up, in two flavors:
  /// - Alt+Esc: Windows' own window-cycle chord — the shell swallows it before
  ///   the engine sees a key event, so Escape-while-Alt-held never arrived.
  /// - Bare Esc: SetForegroundWindow after a morph can lose the focus race
  ///   for a few ms; a fast first Escape then went to the PREVIOUS app
  ///   ("closes only on the second press"). The hotkey route doesn't care
  ///   who has keyboard focus.
  /// RegisterHotKey outranks both the shell and the focused app.
  Future<void> _claimDismissKeys() async {
    if (_escChord == null && _chordFree(0x1, 0x1B)) {
      final chord = HotKey(
        key: PhysicalKeyboardKey.escape,
        modifiers: [HotKeyModifier.alt],
        scope: HotKeyScope.system,
      );
      await hotKeyManager.register(chord,
          keyDownHandler: (_) => dismissTick.value++);
      _escChord = chord;
    }
    if (_escPlain == null && _chordFree(0, 0x1B)) {
      final chord = HotKey(
        key: PhysicalKeyboardKey.escape,
        modifiers: [],
        scope: HotKeyScope.system,
      );
      await hotKeyManager.register(chord,
          keyDownHandler: (_) => dismissTick.value++);
      _escPlain = chord;
    }
  }

  Future<void> _releaseDismissKeys() async {
    final chord = _escChord;
    final plain = _escPlain;
    _escChord = null;
    _escPlain = null;
    if (chord != null) await hotKeyManager.unregister(chord);
    if (plain != null) await hotKeyManager.unregister(plain);
  }

  /// Hotkey entry point. Toggles: open when closed, dismiss when open.
  Future<void> summon() async {
    if (_busy) {
      // Mid-restore hotkey = "open it again": run after the restore lands
      // instead of silently dropping the press.
      _pendingSummon = true;
      return;
    }
    if (overlayMode.value || inAppCapture.value) {
      dismissTick.value++;
      return;
    }

    // In-app capture ONLY when Slate is really in front of the user AND its
    // bottom edge is the screen's bottom edge (maximized/fullscreen) — the
    // pill must live at the BOTTOM OF THE SCREEN, always the same spot. A
    // windowed Slate would anchor it to the window instead, so that case
    // morphs like any other app. The visible+!minimized part matters too: a
    // hidden window can still be GetForegroundWindow, and the old
    // focused-only check opened the capture scene INSIDE the invisible
    // window — hotkey "dead" until a desktop click blurred it.
    if (await windowManager.isFocused() &&
        await windowManager.isVisible() &&
        !await windowManager.isMinimized() &&
        (await windowManager.isMaximized() ||
            await windowManager.isFullScreen())) {
      // Already in Slate: capture in place, never hide the user's own window.
      // Day pill open = already capturing → the chord is a no-op.
      if (StaircaseState.isComposingTask) return;
      inAppCapture.value = true;
      await _claimDismissKeys();
      return;
    }

    _busy = true;
    try {
      await _claimDismissKeys();
      // The window IS the pill during the morph — DWM minimize/restore
      // animations would play on the pill itself (the "mangled pill flying
      // out of the taskbar corner"). Off for the whole dance.
      _transitionsDisabled(true);
      _captureZOrder();

      // Invisible prep FIRST, valid for every branch: a visible window
      // paints MainScreen over every pixel (opaque), a hidden/minimized one
      // has no pixels at all. Alpha 1, not 0: Windows 10 renders a zero-alpha
      // accent gradient as solid black instead of letting the desktop show
      // through. The 900x600 minimum is lifted because DefWindowProc clamps
      // EVERY SetWindowPos to it, and a scaled/small work area may be smaller.
      await Window.setEffect(
          effect: WindowEffect.transparent, color: const Color(0x01000000));
      await windowManager.setBackgroundColor(Colors.transparent);
      await windowManager.setMinimumSize(Size.zero);
      final target = _overlayRect();
      overlayRect = target;

      // State reads LAST — native and await-free, so nothing can change
      // between here and the morph. (The header's minimize button posts an
      // async SC_MINIMIZE; with the old plugin-await reads it could land
      // mid-summon and invalidate every "prior" we captured.)
      final h = _windowHandle;
      _priorMinimized = _winIsIconic(h) != 0;
      _priorVisible = _winIsWindowVisible(h) != 0;
      _priorZoomed = !_priorMinimized && _winIsZoomed(h) != 0;
      _priorFocused =
          _priorVisible && !_priorMinimized && _priorForeground == h;
      if (_priorMinimized || _priorZoomed) {
        // Windows itself remembers the true normal placement — truer than
        // any rect we cached (GetWindowRect on a zoomed window reports the
        // monitor-sized rect, on a minimized one the -32000 icon rect).
        final (toMax, normal) = _placementRead();
        _priorRestoreToMax = _priorMinimized && toMax;
        _priorRect = normal ?? _lastNormalRect;
      } else {
        _priorRestoreToMax = false;
        _priorRect = _lastNormalRect = _windowRect() ?? _lastNormalRect;
      }

      // Focused windowed Slate: the overlay will paint a live MainScreen
      // ghost at the window's old spot — visually the app stays put while
      // the real window becomes the pill. The ghost keeps MainScreen's
      // shortcut surface alive, so mute it exactly like in-app capture does.
      CrashLog.trace('summon: vis=$_priorVisible min=$_priorMinimized '
          'zoom=$_priorZoomed focus=$_priorFocused '
          'prior=$_priorRect target=$target');

      final showGhost = _priorFocused && !_priorMinimized && !_priorZoomed;
      ghostRect = showGhost ? _priorRect : null;
      // Otherwise: MainScreen unmounts during the morph; a stale modal flag
      // from an open day pill would mute every shortcut after restore.
      StaircaseState.isComposingTask = showGhost;

      if (showGhost) {
        // Focused windowed Slate: ATOMIC morph. The window is the actively
        // rendering foreground, so a single SetWindowPos presents the dirty
        // overlay tree at the new rect inside the call — no hide, no opacity
        // dip. The live MainScreen ghost keeps the app visually pinned.
        final sw = Stopwatch()..start();
        var frameUs = -1;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => frameUs = sw.elapsedMicroseconds);
        overlayMode.value = true; // NO await between this and the morph
        _morphWindow(target, insertAfter: _kHwndTopmost);
        final swpUs = sw.elapsedMicroseconds;
        await _pumpFrames(1);
        final inMsg = 'morph[in]: swp=${swpUs}us frame=${frameUs}us '
            'atomic=${frameUs >= 0 && frameUs <= swpUs}';
        debugPrint(inMsg);
        CrashLog.trace(inMsg);
        await _assertRect(target);
        await windowManager.focus();
        return;
      }

      // Every OTHER prior — behind another app (windowed OR maximized),
      // minimized, or hidden to tray — is NOT the actively-rendering
      // foreground, so its embedder swapchain is COLD and the cold-morph
      // path warms it off-screen before revealing. See _coldMorph.
      await _coldMorph(target);
    } catch (e) {
      CrashLog.trace('summon failed: $e');
      _cloaked(false);
      // Scene never came up → the window is back to normal use; a lifted
      // minimum must not outlive the morph.
      if (!overlayMode.value) {
        unawaited(windowManager.setMinimumSize(const Size(900, 600)));
      }
      rethrow;
    } finally {
      _busy = false;
    }
  }

  /// Called by the capture scene after its exit animation. Never call
  /// directly — bump [dismissTick] so the exit always animates.
  Future<void> finishAndRestore() async {
    if (inAppCapture.value) {
      inAppCapture.value = false;
      await _releaseDismissKeys();
      return;
    }
    if (!overlayMode.value) return;
    // A fast Escape can land while summon() is still flying. Dropping the
    // dismiss here left a zombie scene (frozen pill, "second Escape") —
    // wait the summon out instead.
    for (var i = 0; i < 40 && _busy; i++) {
      await Future.delayed(const Duration(milliseconds: 25));
    }
    if (_busy || !overlayMode.value) return;
    _busy = true;
    try {
      await _releaseDismissKeys();
      final prior = _priorRect;
      CrashLog.trace('restore: vis=$_priorVisible min=$_priorMinimized '
          'zoom=$_priorZoomed focus=$_priorFocused prior=$prior');

      if (_priorVisible && !_priorMinimized && prior != null) {
        // Visible window: ATOMIC reverse morph — the same single-SetWindowPos
        // trick as summon, in reverse. The window never hides, never drops
        // opacity, and the live MainScreen reparents back in that same frame.
        if (_winIsIconic(_windowHandle) != 0) {
          // A taskbar-button click minimized the overlay mid-scene —
          // un-minimize invisibly before doing geometry.
          _placementSet(prior,
              showCmd: _kSwShowNormalNoActivate, restoreToMax: false);
        }
        if (_priorZoomed) {
          // Re-maximize + rcNormal in ONE SetWindowPlacement (SetWindowPos
          // is swallowed by zoomed windows). SW_SHOWMAXIMIZED activates —
          // a no-op right now: the pill IS the foreground. But it also
          // RAISES: for a behind-prior that is a full-screen Slate frame
          // above the user's app (the S4 flash) — so the behind case runs
          // the whole dance at alpha 1/255 (invisible, yet still presented
          // — alpha 0 wedges the resize handshake) and reveals below the
          // anchor.
          final behind = !_priorFocused;
          if (behind) await windowManager.setOpacity(1 / 255);
          overlayMode.value = false; // dirty; placement's resize presents it
          _placementSet(prior,
              showCmd: _kSwShowMaximized, restoreToMax: false);
          await _pumpFrames(1);
          _restoreZOrder();
          if (_isTopmost()) {
            _setTopmost(false);
            _restoreZOrder();
          }
          _yieldForeground();
          await Window.setEffect(
              effect: WindowEffect.disabled, color: AppTheme.background);
          await windowManager.setBackgroundColor(AppTheme.background);
          if (behind) await windowManager.setOpacity(1.0);
          await windowManager.setMinimumSize(const Size(900, 600));
          return;
        }

        // Anchor: back UNDER the app the pill was summoned over (Spotlight
        // contract). For a focused prior there is no anchor — it stays the
        // top non-topmost window.
        final anchor = _priorFocused ? 0 : _zAnchor();
        final sw = Stopwatch()..start();
        var frameUs = -1;
        WidgetsBinding.instance
            .addPostFrameCallback((_) => frameUs = sw.elapsedMicroseconds);
        overlayMode.value = false; // NO await between this and the morph
        _morphWindow(prior,
            insertAfter: anchor != 0 ? anchor : _kHwndNoTopmost);
        final swpUs = sw.elapsedMicroseconds;
        await _pumpFrames(1);
        final outMsg = 'morph[out]: swp=${swpUs}us frame=${frameUs}us '
            'atomic=${frameUs >= 0 && frameUs <= swpUs}';
        debugPrint(outMsg);
        CrashLog.trace(outMsg);
        // Inserting after a plain window clears TOPMOST per SetWindowPos
        // rules — belt in case the OS kept it.
        if (_isTopmost()) {
          _setTopmost(false);
          if (anchor != 0) _restoreZOrder();
        }
        await _assertRect(prior);
        if (_priorFocused) {
          await windowManager.focus(); // keyboard back to MainScreen
        } else {
          // The morph kept our (soon wrong) foreground — hand it to the app
          // the user was actually in. Exactly ONE focus transition: nothing
          // below touches activation.
          _yieldForeground();
        }
        // Invisible under MainScreen's opaque paint — safe after the swap.
        await Window.setEffect(
            effect: WindowEffect.disabled, color: AppTheme.background);
        await windowManager.setBackgroundColor(AppTheme.background);
        await windowManager.setMinimumSize(const Size(900, 600));
        return;
      }

      // Hidden or minimized prior: the pill vanishes (alpha 1/255 —
      // invisible but still presentable, so the zoomed re-plant below can
      // deliver frames; alpha 0 wedges the resize handshake), focus is
      // yielded FIRST — hiding a window that is no longer foreground
      // causes zero activation churn (the old order let Windows reassign
      // focus mid-chain: the user's caret blinked on-off-on).
      await windowManager.setOpacity(1 / 255);
      if (!_priorMinimized && _priorZoomed && prior != null) {
        // The window was hidden-while-maximized. Re-plant WS_MAXIMIZE now,
        // while the invisible (alpha-0) pill is still the foreground —
        // SW_SHOWMAXIMIZED activates, which is a no-op at this instant.
        // hide() below keeps the zoomed style, so the next tray open comes
        // back maximized with the true rcNormal remembered.
        _placementSet(prior, showCmd: _kSwShowMaximized, restoreToMax: false);
      }
      _yieldForeground();
      await windowManager.hide();
      overlayMode.value = false;
      await Window.setEffect(
          effect: WindowEffect.disabled, color: AppTheme.background);
      await windowManager.setBackgroundColor(AppTheme.background);
      _setTopmost(false);
      if (_priorMinimized) {
        // Cloaked render pass: DWM keeps compositing a cloaked window, so
        // the Alt+Tab thumbnail becomes a real MainScreen frame instead of
        // the white "Slate + default icon" fallback of a never-shown window.
        _cloaked(true);
        if (prior != null) {
          _placementSet(prior,
              showCmd: _kSwShowNormalNoActivate, restoreToMax: false);
        } else {
          _showNoActivate();
        }
        await windowManager.setOpacity(1.0);
        await _pumpFrames(3);
        // Back to minimized in one synchronous call, restore-to-maximized
        // preserved — un-minimizing later gives the maximized window back.
        if (prior != null) {
          _placementSet(prior,
              showCmd: _kSwShowMinNoActive, restoreToMax: _priorRestoreToMax);
        } else {
          await windowManager.minimize();
        }
        _cloaked(false);
      } else {
        // Tray-hidden: park the geometry for the next open, reset opacity
        // while hidden. No taskbar work — a hidden window has no tab, and
        // the old DeleteTab/AddTab churn is gone (AddTab on a hidden window
        // fabricated a phantom taskbar button with no Alt+Tab entry).
        // Zoomed prior: geometry already re-planted by the placement above.
        if (!_priorZoomed && prior != null) _setWindowRect(prior);
        await windowManager.setOpacity(1.0);
      }
      // Geometry is settled — re-arm the normal-use minimum.
      await windowManager.setMinimumSize(const Size(900, 600));
    } catch (e) {
      debugPrint('quick capture: restore failed: $e');
    } finally {
      // Safety net — a mid-flight failure must NEVER leave the window
      // cloaked (present in the taskbar but INVISIBLE in Alt+Tab),
      // animation-less, or with the 900x600 minimum lifted. All idempotent.
      _cloaked(false);
      _transitionsDisabled(false);
      unawaited(windowManager.setMinimumSize(const Size(900, 600)));
      ghostRect = null;
      StaircaseState.isComposingTask = false;
      _busy = false;
      if (_pendingSummon) {
        _pendingSummon = false;
        unawaited(summon()); // hotkey arrived mid-restore: reopen now
      }
    }
  }

  /// Assert the "healthy visible window" invariants: uncloaked, animated,
  /// fully opaque. Idempotent — tray/openApp calls it as a belt so no raced
  /// or crashed morph can ever leave Slate a taskbar-button-without-a-window.
  Future<void> healWindowState() async {
    if (_busy || overlayMode.value) return;
    _cloaked(false);
    _transitionsDisabled(false);
    await windowManager.setOpacity(1.0);
  }

  bool get windowIsForeground => _winGetForegroundWindow() == _windowHandle;

  /// A morph (summon or restore) is mid-flight. openApp waits this out —
  /// interleaving its show/focus with the restore tail races window state.
  bool get busy => _busy;

  /// Present [n] frames; time-boxed so a stalled pump can never wedge the
  /// window machinery.
  Future<void> _pumpFrames(int n) async {
    final binding = WidgetsBinding.instance;
    for (var i = 0; i < n; i++) {
      binding.scheduleFrame();
      await binding.endOfFrame.timeout(
        const Duration(milliseconds: 60),
        onTimeout: () {},
      );
    }
  }

  Future<void> _cacheNormalBounds() async {
    if (overlayMode.value || _busy) return;
    final h = _windowHandle;
    // A minimized rect is the -32000 icon slot, a maximized one is the
    // monitor — neither is a "normal" rect worth remembering.
    if (h == 0 || _winIsIconic(h) != 0 || _winIsZoomed(h) != 0) return;
    _lastNormalRect = _windowRect() ?? _lastNormalRect;
  }

  @override
  void onWindowMoved() => _cacheNormalBounds();

  @override
  void onWindowResized() => _cacheNormalBounds();

  @override
  void onWindowBlur() {
    // Clicking another app while capturing = calm dismiss, nothing created.
    if ((overlayMode.value || inAppCapture.value) && !_busy) {
      dismissTick.value++;
    }
  }
}
