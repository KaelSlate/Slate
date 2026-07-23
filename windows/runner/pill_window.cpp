#include "pill_window.h"

#include <flutter_acrylic/flutter_acrylic_plugin.h>

#include <optional>

namespace {

// Drives the two-step heal below. Each step is ~3 frames at 60 Hz: enough for
// the engine to actually present, which is the whole point of the exercise.
constexpr UINT_PTR kHealTimerId = 1;
constexpr UINT kHealStepMs = 50;

}  // namespace

PillWindow::PillWindow(const flutter::DartProject& project)
    : project_(project) {}

PillWindow::~PillWindow() {}

bool PillWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  // ONLY flutter_acrylic (the transparent window effect). Registering the
  // main-owned plugins here too — tray_manager especially — gave the process a
  // second tray_manager that fought the main one for the icon's messages, so
  // the tray icon stopped responding to clicks. The pill needs none of them.
  FlutterAcrylicPluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin(
          "FlutterAcrylicPlugin"));
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "slate/pill",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        const std::string& method = call.method_name();
        if (method == "dismiss") {
          HidePill();
          result->Success();
        } else if (method == "capture") {
          if (capture_sink_ && call.arguments()) {
            capture_sink_(*call.arguments());
          }
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  flutter_controller_->ForceRedraw();
  return true;
}

void PillWindow::ShowPill() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;

  // Toggle: the hotkey pressed while the pill is up dismisses it (Raycast).
  if (::IsWindowVisible(hwnd)) {
    HidePill();
    return;
  }

  // Remember who to hand focus back to (unless that is us / the main window).
  HWND fg = ::GetForegroundWindow();
  if (fg && fg != hwnd) prior_foreground_ = fg;

  // Full work area of the monitor the cursor is on — same rule as before, but
  // it is THIS window that moves; the main window is never touched.
  POINT pt{};
  ::GetCursorPos(&pt);
  HMONITOR mon = ::MonitorFromPoint(pt, MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  RECT work = {0, 0, 1366, 768};
  if (mon && ::GetMonitorInfo(mon, &mi)) work = mi.rcWork;

  const int width = work.right - work.left;
  const int height = work.bottom - work.top;

  // Did the display geometry move under us while this window sat hidden?
  // Parsec/RDP switching the host resolution, a monitor hotplug, a DPI change —
  // all of them leave the pill sized for a screen that no longer exists.
  RECT current{};
  ::GetWindowRect(hwnd, &current);
  const bool size_changed = (current.right - current.left) != width ||
                            (current.bottom - current.top) != height;

  if (size_changed) {
    // The entrance is deferred to the heal timer — played now it would land in
    // the stale viewport, which is exactly the bug.
    ShowAtHealedSize(work, width, height);
    ::SetForegroundWindow(hwnd);
    ::SetFocus(hwnd);
    return;
  }

  ::SetWindowPos(hwnd, HWND_TOPMOST, work.left, work.top, width, height,
                 SWP_NOACTIVATE);
  ::ShowWindow(hwnd, SW_SHOWNA);
  ::SetForegroundWindow(hwnd);
  ::SetFocus(hwnd);

  if (channel_) channel_->InvokeMethod("reveal", nullptr);
}

// Resizing this window while it is HIDDEN does not reach the engine: it keeps
// rendering into a viewport of the old size, and that frame is what the
// compositor puts on screen — the pill spawns as a small, stretched slab in a
// corner. It never heals on its own either, because the next summon asks for
// the SAME size and no resize follows (which is why reopening the app from the
// tray this morning changed nothing).
//
// Measured on 2026-07-23, all against the real screen:
//   resize off-screen             -> ignored (nothing is presented out there)
//   resize behind alpha 0         -> ignored (a transparent window likewise)
//   resize while the engine idles -> ignored, viewport stays stale
//   resize while it is PRESENTING -> fixed instantly
// So a resize is only honoured by an engine that is actively drawing, and
// between summons this one draws nothing. `warmup` gets frames flowing while
// every pixel stays transparent; the nudge then lands, and the entrance is
// asked for last, so it plays in the geometry the window really has.
void PillWindow::ShowAtHealedSize(const RECT& work, int width, int height) {
  HWND hwnd = GetHandle();
  ::SetWindowPos(hwnd, HWND_TOPMOST, work.left, work.top, width, height,
                 SWP_NOACTIVATE);
  ::ShowWindow(hwnd, SW_SHOWNA);

  if (channel_) channel_->InvokeMethod("warmup", nullptr);

  heal_phase_ = 1;
  ::SetTimer(hwnd, kHealTimerId, kHealStepMs, nullptr);
}

// Step 1: nudge the size, so the engine adopts the viewport it is really given.
// Step 2: play the entrance, now that it lands in the right geometry.
void PillWindow::StepHeal() {
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
  if (::IsWindowVisible(hwnd) && channel_) {
    channel_->InvokeMethod("reveal", nullptr);
  }
}

void PillWindow::HidePill() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
  // Dismissed mid-heal (Esc landed inside those ~100 ms): drop the pending
  // steps, or a stray entrance would fire into a window that is already gone.
  if (heal_phase_) {
    ::KillTimer(hwnd, kHealTimerId);
    heal_phase_ = 0;
  }
  ::ShowWindow(hwnd, SW_HIDE);
  // Hand the keyboard back to the app the user summoned the pill over.
  if (prior_foreground_ && ::IsWindow(prior_foreground_)) {
    ::SetForegroundWindow(prior_foreground_);
  }
  prior_foreground_ = nullptr;
}

void PillWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }
  Win32Window::OnDestroy();
}

LRESULT PillWindow::MessageHandler(HWND hwnd, UINT const message,
                                   WPARAM const wparam,
                                   LPARAM const lparam) noexcept {
  // Ahead of the engine's handler: the heal must not depend on whether the
  // controller claims WM_TIMER.
  if (message == WM_TIMER && wparam == kHealTimerId) {
    StepHeal();
    return 0;
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
