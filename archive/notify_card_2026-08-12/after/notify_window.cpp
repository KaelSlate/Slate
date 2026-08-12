#include "notify_window.h"

#include <dwmapi.h>
#include <flutter/method_result_functions.h>
#include <flutter_acrylic/flutter_acrylic_plugin.h>
#include <shellapi.h>
#include <uxtheme.h>

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
constexpr UINT kUncloakFallbackMs = 150;

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
        if (method == "action") {
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
  return true;
}

// REAL glass, not a dark rectangle pretending.
//
// Flutter cannot blur what is behind this window — BackdropFilter only ever
// sees Flutter's own tree, so over a browser or a bright wallpaper a
// "glassmorphic" card is just flat plastic. Windows itself can do it: the same
// acrylic the shell uses for its own toasts. DWMSBT_TRANSIENTWINDOW is
// documented for exactly this — "transient, light-dismiss surfaces".
//
// The frame has to be extended over the whole client area first, otherwise the
// backdrop has nowhere to show through. Where Dart paints a translucent colour,
// the desktop behind is blurred by the compositor at zero cost to us.
//
// Windows 11 22H2 (build 22621) and up. Older builds simply refuse the
// attribute and keep the solid body — degraded, never broken.
void NotifyWindow::EnableAcrylicBackdrop() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  MARGINS m = {-1, -1, -1, -1};
  ::DwmExtendFrameIntoClientArea(hwnd, &m);
  int backdrop = DWMSBT_TRANSIENTWINDOW;
  acrylic_ = SUCCEEDED(::DwmSetWindowAttribute(
      hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, sizeof(backdrop)));
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

void NotifyWindow::Uncloak() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  ::KillTimer(hwnd, kUncloakTimerId);
  if (::IsWindowVisible(hwnd)) SetCloak(false);
}

// Everything outside the card stops being part of this window: DWM will not
// composite it and, crucially, the hit test will not see it — so a click there
// reaches whatever app is underneath, in whatever process. Dart sends the rect
// already padded for its own shadow, in physical pixels, plus the corner radius
// so the soft shadow is not sliced by a hard rectangle.
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
  // A stale region from the previous show would clip the entrance of this one.
  ::SetWindowRgn(hwnd, nullptr, FALSE);
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
