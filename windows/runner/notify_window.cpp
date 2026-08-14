#include "notify_window.h"

#include <dwmapi.h>
#include <flutter/method_result_functions.h>
#include <flutter_acrylic/flutter_acrylic_plugin.h>
#include <shellapi.h>
#include <uxtheme.h>

#include "sfx_player.h"

#include <optional>

#ifndef DWMWA_CLOAK
#define DWMWA_CLOAK 13
#endif
#ifndef DWMWA_SYSTEMBACKDROP_TYPE
#define DWMWA_SYSTEMBACKDROP_TYPE 38
#endif
#ifndef DWMSBT_TRANSIENTWINDOW
#define DWMSBT_TRANSIENTWINDOW 3
#endif

namespace {

constexpr UINT_PTR kHealTimerId = 1;
constexpr UINT kHealStepMs = 50;

constexpr UINT_PTR kUncloakTimerId = 2;

// The safety net for a Dart side that never answers `reveal`, NOT a schedule.
// Every healthy show uncloaks on the reply, which is a RASTERISED frame.
//
// It was 150 ms, and that lost a race it should never have been in: the first
// card of a session pays runtime SkSL compilation for three MaskFilter.blur
// passes, two gradients and an ImageFilter, which overruns 150 ms on a cold
// GPU cache. The timer then uncloaked a window that had painted NOTHING.
//
// The timer is no longer what stands between that and the screen — BlankRegion
// is, and it holds whether or not this fires. What the length buys now is that
// a merely slow engine is not punished with a card that appears a beat late.
// Revealing early is no longer possible; revealing late still costs something.
constexpr UINT kUncloakFallbackMs = 700;

// The startup shader warm-up, and its own net. Generous because nothing is
// waiting on it — no card is due, nobody is looking — and short enough that a
// window can never sit shown-but-cloaked for a noticeable stretch.
constexpr UINT_PTR kWarmTimerId = 3;
constexpr UINT kWarmFallbackMs = 3000;

}  // namespace

NotifyWindow::NotifyWindow(const flutter::DartProject& project)
    : project_(project) {}

NotifyWindow::~NotifyWindow() {}

bool NotifyWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  // ONLY flutter_acrylic — same rule as the pill. RegisterPlugins here would
  // give the process a second tray_manager that fights the first one for the
  // icon's messages, and the tray stops responding to clicks.
  FlutterAcrylicPluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "FlutterAcrylicPlugin"));
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "slate/notify",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const std::string& method = call.method_name();
        if (method == "ready") {
          // Dart's handler is installed and the tree is up. This is the only
          // moment at which asking it to warm up can actually reach it.
          result->Success();
          WarmUpOnce();
        } else if (method == "action") {
          if (action_sink_ && call.arguments()) {
            action_sink_(*call.arguments());
          }
          result->Success();
        } else if (method == "region") {
          // The card grew a row, lost one, or is being carried off screen.
          // Without this the window keeps the shape it was revealed with: rows
          // below the first stop taking clicks, and a flicked card is sheared
          // along a hard vertical line with its shadow cut in half.
          ApplyHitRegion(call.arguments());
          result->Success();
        } else if (method == "closed") {
          HideNow();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  EnableAcrylicBackdrop();
  flutter_controller_->ForceRedraw();
  SetCloak(true);
  // NOT WarmUpOnce() here. This runs inside window creation, long before the
  // Dart entrypoint has executed `setMethodCallHandler`, so the `warmup` call
  // would be sent to a channel nobody is listening on and quietly dropped —
  // which is exactly what it did: measured, the first card of a session was
  // 266 ms slower than the ones after it, the whole shader bill still unpaid.
  // Dart says `ready` when it really is; see the channel handler above.
  return true;
}

// Pay for shader compilation NOW, on a window nobody is looking at, instead of
// in front of the first reminder someone ever gets.
//
// We are on Skia (FLUTTER_IMPELLER in this runner's CMake is read by nobody),
// so every pipeline the card needs is compiled from SkSL the first time it is
// drawn. That bill used to land on the first card of a session — the single
// moment in this whole feature that cannot be rehearsed — and it showed as a
// card that simply cut into existence with no entrance at all.
//
// Showing the window to do it is safe because it is invisible twice over: DWM
// has it cloaked, and BlankRegion has shaped it down to one pixel. SW_SHOWNA
// keeps it off the foreground; HWND_BOTTOM keeps it out of everyone's way.
void NotifyWindow::WarmUpOnce() {
  HWND hwnd = GetHandle();
  if (!hwnd || !channel_ || warming_) return;
  warming_ = true;

  // A REHEARSAL, not just a paint. Shader compilation was only part of the
  // first card's bill; the rest is every code path in ShowCards that has never
  // run before — the first COM call into the shell, the first positioning
  // SetWindowPos on this window, the first time DWM is asked to put it topmost
  // and to build a composition surface for it. Doing all of it here, minutes
  // early and one pixel wide, is the only way the first card can cost what the
  // tenth costs.
  WindowsAcceptsNotifications();

  SetCloak(true);
  BlankRegion();

  RECT work = {0, 0, 1366, 768};
  POINT pt{};
  ::GetCursorPos(&pt);
  HMONITOR mon = ::MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (mon && ::GetMonitorInfo(mon, &mi)) work = mi.rcWork;
  // The SAME call the real show makes, so that one is not the first of its kind.
  ::SetWindowPos(hwnd, HWND_TOPMOST, work.left, work.top,
                 work.right - work.left, work.bottom - work.top,
                 SWP_NOACTIVATE);
  ::ShowWindow(hwnd, SW_SHOWNA);
  // Belt: a Dart side that never answers must not leave this window shown.
  ::SetTimer(hwnd, kWarmTimerId, kWarmFallbackMs, nullptr);
  auto finish = [this](const flutter::EncodableValue*) { FinishWarmUp(); };
  channel_->InvokeMethod(
      "warmup", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          finish,
          [finish](const std::string&, const std::string&,
                   const flutter::EncodableValue*) { finish(nullptr); },
          [finish]() { finish(nullptr); }));
}

void NotifyWindow::FinishWarmUp() {
  HWND hwnd = GetHandle();
  if (!hwnd || !warming_) return;
  warming_ = false;
  ::KillTimer(hwnd, kWarmTimerId);

  // Rehearse the UNCLOAK too, which is the last first-time-only step on the
  // path. DWM builds its composition state for a window the first time it is
  // actually asked to composite one, and on the first card that work landed
  // between "the card is ready" and "the card is on screen" — the only stretch
  // where it is visible as lateness.
  //
  // Safe to do for real: the region is one pixel at the work area's top-left
  // corner, and Dart paints nothing there — the card lives at bottom centre.
  // There is no frame in which anything can be seen.
  SetCloak(false);
  SetCloak(true);

  ::ShowWindow(hwnd, SW_HIDE);
}

// REAL glass, not a dark rectangle pretending.
//
// Flutter cannot blur what is behind this window — BackdropFilter only ever
// sees Flutter's own tree, so over a browser or a bright wallpaper a
// "glassmorphic" card is just flat plastic. Windows itself can do it: the same
// acrylic the shell uses for its own toasts. DWMSBT_TRANSIENTWINDOW is
// documented for exactly this — "transient, light-dismiss surfaces".
//
// The frame has to be extended over the whole client area, otherwise the
// backdrop has nowhere to show through. Where Dart paints a translucent colour,
// the desktop behind is blurred by the compositor at zero cost to us.
//
// Windows 11 22H2 (build 22621) and up. Older builds simply refuse the
// attribute and keep the solid body — degraded, never broken.
//
// ORDER MATTERS, and it did not use to. The frame was extended first and
// unconditionally, so on Windows 10 — where the attribute does not exist and
// the call fails — the window was left with its frame stretched over the whole
// client area and NO backdrop to justify it. DWM fills that extension with its
// own frame material, which is what the region then exposed everywhere the
// card's shadow had faded out: the grey the eye reads as a slab on first show
// and as flickering brackets during a drag.
//
// Safe to make conditional: transparency on Windows 10 comes from
// flutter_acrylic's `Window.setEffect(transparent)`, which goes through
// SetWindowCompositionAttribute(ACCENT_ENABLE_TRANSPARENTGRADIENT) and never
// touches DwmExtendFrameIntoClientArea at all (checked against the plugin
// source, 1.1.4). Nothing here was holding the transparency up.
void NotifyWindow::EnableAcrylicBackdrop() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  int backdrop = DWMSBT_TRANSIENTWINDOW;
  acrylic_ = SUCCEEDED(::DwmSetWindowAttribute(
      hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, sizeof(backdrop)));
  if (acrylic_) {
    MARGINS m = {-1, -1, -1, -1};
    ::DwmExtendFrameIntoClientArea(hwnd, &m);
  }
}

// Inherited wholesale from the pill: a per-pixel transparent window whose
// client area DefWindowProc erases with the class brush gets that graphite
// ADDED to the desktop by DWM. Cloaked, the window renders but is not
// composited, so nothing pre-Flutter can ever reach the screen.
void NotifyWindow::SetCloak(bool on) {
  HWND hwnd = GetHandle();
  if (!hwnd || cloaked_ == on) return;
  BOOL value = on ? TRUE : FALSE;
  ::DwmSetWindowAttribute(hwnd, DWMWA_CLOAK, &value, sizeof(value));
  cloaked_ = on;
}

// Uncloak, then TELL DART. The second half is not bookkeeping — it is the only
// moment at which an entrance may begin.
//
// Everything before this point happens on a window the compositor is not
// showing: the card is built, laid out, painted and rasterised entirely out of
// sight. Dart therefore holds the card still, at seed, and waits for this call
// to start its spring. Without it the animation ran against the clock while
// cloaked and what appeared on screen was whatever was left of it — the whole
// entrance on the first card of a session, where shader compilation shares the
// same wait.
void NotifyWindow::Uncloak() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ::KillTimer(hwnd, kUncloakTimerId);
  if (!::IsWindowVisible(hwnd)) return;
  const bool was_cloaked = cloaked_;
  SetCloak(false);
  // Only on the transition. Uncloak() is reachable twice — the fallback timer
  // and then the real reply — and a second `revealed` after the entrance has
  // begun would be a spring restarting mid-flight.
  if (!was_cloaked) return;
  // THE CHIME, on the frame the card becomes visible rather than on the call
  // that asked for it. Dart arms it (Sfx.reminderDue -> onReveal) the instant
  // ShowCards returns; without this it played roughly 110 ms ahead of its own
  // picture and read as two unrelated events.
  SfxPlayer::Instance().FireDeferred();
  if (channel_) channel_->InvokeMethod("revealed", nullptr);
}

// Everything outside the card stops being part of this window: DWM will not
// composite it and, crucially, the hit test will not see it — so a click there
// reaches whatever app is underneath, in whatever process. Dart sends the rect
// already padded for its own shadow, in physical pixels, plus the corner radius
// so the soft shadow is not sliced by a hard rectangle.
// Shape the window down to a single pixel. Held from the moment it is shown
// until Dart answers `reveal` with a real rect.
//
// This used to be `SetWindowRgn(nullptr)` — "clear the stale region so it
// cannot clip the entrance" — which cleared it to the WHOLE WORK AREA. Between
// ShowWindow and the reply, anything that painted in that window painted at
// full screen size, and the uncloak fallback was one timer away from showing
// it. A grey slab exactly the size of the desktop is the same bug as a grey
// slab the size of a card; it was only ever the cloak holding it back.
//
// A blank region is a second, independent belt: it does not care whether the
// engine has painted, whether the swapchain has presented, or whether the
// fallback timer beat all of it. There is nothing to composite.
void NotifyWindow::BlankRegion() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  // 1x1 rather than genuinely empty: an empty region is a legal way to ask the
  // compositor to stop dealing with a window entirely, and this one still has
  // to keep presenting frames so that the very thing we are waiting for — a
  // rasterised frame — can happen.
  ::SetWindowRgn(hwnd, ::CreateRectRgn(0, 0, 1, 1), FALSE);
}

void NotifyWindow::ApplyHitRegion(const flutter::EncodableValue* hit) {
  HWND hwnd = GetHandle();
  if (!hwnd) return;

  const auto* list = std::get_if<flutter::EncodableList>(hit);
  if (!list || list->size() < 4) {
    // No usable rect: fall back to a full-window region. A card that eats
    // clicks is bad; a card that never appears is worse.
    ::SetWindowRgn(hwnd, nullptr, TRUE);
    return;
  }

  int v[5] = {0, 0, 0, 0, 0};
  for (size_t i = 0; i < 5 && i < list->size(); ++i) {
    if (const auto* n = std::get_if<int32_t>(&(*list)[i])) v[i] = *n;
  }
  if (v[2] <= v[0] || v[3] <= v[1]) {
    ::SetWindowRgn(hwnd, nullptr, TRUE);
    return;
  }

  const int radius = v[4] > 0 ? v[4] : 0;
  HRGN rgn = radius > 0
                 ? ::CreateRoundRectRgn(v[0], v[1], v[2] + 1, v[3] + 1,
                                        radius * 2, radius * 2)
                 : ::CreateRectRgn(v[0], v[1], v[2] + 1, v[3] + 1);
  if (!rgn) return;
  // The window owns the region after this call — do not delete it.
  ::SetWindowRgn(hwnd, rgn, FALSE);
}

void NotifyWindow::RevealWhenPainted() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  if (!channel_) {
    SetCloak(false);
    return;
  }
  ::SetTimer(hwnd, kUncloakTimerId, kUncloakFallbackMs, nullptr);
  auto done = [this](const flutter::EncodableValue* hit) {
    ApplyHitRegion(hit);
    Uncloak();
  };
  channel_->InvokeMethod(
      "reveal", nullptr,
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          done,
          [done](const std::string&, const std::string&,
                 const flutter::EncodableValue*) { done(nullptr); },
          [done]() { done(nullptr); }));
}

// Microsoft's own contract for apps that draw their own notification UI: ask
// before every show, and only speak on QUNS_ACCEPTS_NOTIFICATIONS. Windows
// sends no event when a game goes full screen, so this is asked every time and
// never cached. Dart asks too; this is the last line, because the state can
// change between the decision and the show.
bool NotifyWindow::WindowsAcceptsNotifications() {
  QUERY_USER_NOTIFICATION_STATE state{};
  if (FAILED(::SHQueryUserNotificationState(&state))) {
    return true;  // unknown -> permissive; losing a reminder is worse
  }
  return state == QUNS_ACCEPTS_NOTIFICATIONS;
}

bool NotifyWindow::ShowCards(const flutter::EncodableValue& cards) {
  HWND hwnd = GetHandle();
  if (!hwnd || !channel_) return false;
  if (!WindowsAcceptsNotifications()) return false;

  // A card arriving while the startup warm-up still has the window shown would
  // be read below as "already visible" and handed over as a payload for a card
  // that is not on screen: no entrance, no region handshake, nothing. Close the
  // warm-up first — it has served its purpose the moment a real card exists.
  if (warming_) FinishWarmUp();

  // Tell Dart whether the compositor is blurring behind us, so it paints a
  // translucent body over real glass instead of an opaque one over nothing.
  flutter::EncodableValue payload = cards;
  if (auto* map = std::get_if<flutter::EncodableMap>(&payload)) {
    (*map)[flutter::EncodableValue("acrylic")] =
        flutter::EncodableValue(acrylic_);
  }

  // Card already up: hand the new payload over and let Dart grow it. No
  // re-show, no second entrance, no second region handshake.
  if (::IsWindowVisible(hwnd)) {
    channel_->InvokeMethod(
        "show", std::make_unique<flutter::EncodableValue>(payload));
    // There is no uncloak on this path — the card is already up — so anything
    // waiting for one would wait for the NEXT card. "On reveal" means "now"
    // when the thing is already revealed.
    SfxPlayer::Instance().FireDeferred();
    return true;
  }

  POINT pt{};
  ::GetCursorPos(&pt);
  HMONITOR mon = ::MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  RECT work = {0, 0, 1366, 768};
  if (mon && ::GetMonitorInfo(mon, &mi)) work = mi.rcWork;

  const int width = work.right - work.left;
  const int height = work.bottom - work.top;

  SetCloak(true);
  BlankRegion();
  channel_->InvokeMethod("show",
                         std::make_unique<flutter::EncodableValue>(payload));

  RECT current{};
  ::GetWindowRect(hwnd, &current);
  const bool size_changed = (current.right - current.left) != width ||
                            (current.bottom - current.top) != height;

  if (size_changed) {
    ShowAtHealedSize(work, width, height);
    return true;
  }

  ::SetWindowPos(hwnd, HWND_TOPMOST, work.left, work.top, width, height,
                 SWP_NOACTIVATE);
  // SW_SHOWNA, never SetForegroundWindow: a reminder that steals the caret
  // mid-sentence is worse than no reminder at all.
  ::ShowWindow(hwnd, SW_SHOWNA);
  RevealWhenPainted();
  return true;
}

void NotifyWindow::ShowAtHealedSize(const RECT& work, int width, int height) {
  HWND hwnd = GetHandle();
  ::SetWindowPos(hwnd, HWND_TOPMOST, work.left, work.top, width, height,
                 SWP_NOACTIVATE);
  ::ShowWindow(hwnd, SW_SHOWNA);

  if (channel_) channel_->InvokeMethod("warmup", nullptr);

  heal_phase_ = 1;
  ::SetTimer(hwnd, kHealTimerId, kHealStepMs, nullptr);
}

void NotifyWindow::StepHeal() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;

  if (heal_phase_ == 1) {
    RECT r{};
    ::GetWindowRect(hwnd, &r);
    const int w = r.right - r.left;
    const int h = r.bottom - r.top;
    ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, w - 1, h,
                   SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOZORDER);
    ::SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, w, h,
                   SWP_NOACTIVATE | SWP_NOMOVE | SWP_NOZORDER);
    heal_phase_ = 2;
    ::SetTimer(hwnd, kHealTimerId, kHealStepMs, nullptr);
    return;
  }

  ::KillTimer(hwnd, kHealTimerId);
  heal_phase_ = 0;
  if (::IsWindowVisible(hwnd)) RevealWhenPainted();
}

void NotifyWindow::HideNow() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  if (heal_phase_) {
    ::KillTimer(hwnd, kHealTimerId);
    heal_phase_ = 0;
  }
  ::KillTimer(hwnd, kUncloakTimerId);
  const bool was_visible = ::IsWindowVisible(hwnd) != 0;
  SetCloak(true);
  ::ShowWindow(hwnd, SW_HIDE);
  // No foreground restore: this window never took it in the first place.
  if (was_visible && closed_sink_) closed_sink_();
}

void NotifyWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

LRESULT NotifyWindow::MessageHandler(HWND hwnd, UINT const message,
                                     WPARAM const wparam,
                                     LPARAM const lparam) noexcept {
  // Ahead of the engine, exactly like the pill's heal timers.
  if (message == WM_TIMER && wparam == kHealTimerId) {
    StepHeal();
    return 0;
  }
  if (message == WM_TIMER && wparam == kUncloakTimerId) {
    Uncloak();
    return 0;
  }
  if (message == WM_TIMER && wparam == kWarmTimerId) {
    FinishWarmUp();
    return 0;
  }
  // NOTHING ERASES THIS WINDOW. The class brush is RGB(0x15,0x11,0x0D) —
  // deliberately, so the MAIN window is born dark instead of flashing white
  // (win32_window.cpp) — but on a per-pixel-alpha window DWM composites that
  // graphite ADDITIVELY over the desktop. It is the same defect that made the
  // screen visibly lift when the capture pill was summoned, and here it is what
  // painted the grey rectangle where the card was about to be.
  //
  // Returning 1 claims the erase as handled and draws nothing. Flutter's child
  // view covers the whole client area and owns every pixel that should exist.
  if (message == WM_ERASEBKGND) {
    return 1;
  }
  // Clicking the card must not pull the keyboard away from whatever the person
  // is typing in. MA_NOACTIVATE (not ...ANDEAT) so the click still lands.
  if (message == WM_MOUSEACTIVATE) {
    return MA_NOACTIVATE;
  }

  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
    if (message == WM_FONTCHANGE) {
      flutter_controller_->engine()->ReloadSystemFonts();
    }
  }
  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
