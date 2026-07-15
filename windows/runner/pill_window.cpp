#include "pill_window.h"

#include <optional>

#include "flutter/generated_plugin_registrant.h"

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
  RegisterPlugins(flutter_controller_->engine());
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

  ::SetWindowPos(hwnd, HWND_TOPMOST, work.left, work.top, work.right - work.left,
                 work.bottom - work.top, SWP_NOACTIVATE);
  ::ShowWindow(hwnd, SW_SHOWNA);
  ::SetForegroundWindow(hwnd);
  ::SetFocus(hwnd);

  if (channel_) channel_->InvokeMethod("reveal", nullptr);
}

void PillWindow::HidePill() {
  HWND hwnd = GetHandle();
  if (!hwnd) return;
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
