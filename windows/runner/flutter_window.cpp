#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windowsx.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Frameless-but-resizable, the Windows Terminal way: the window keeps
// WS_THICKFRAME (native resize, Aero Snap, Win+arrows) while WM_NCCALCSIZE
// (handled by window_manager's frameless mode) extends the client area over
// the whole frame. The Flutter view child covers every client pixel, so it
// must yield an edge band back to the parent via HTTRANSPARENT — only then
// does the parent's WM_NCHITTEST run and return the HT* resize codes.

constexpr int kResizeBandDip = 8;

int ResizeBandFor(HWND top_level) {
  return ::MulDiv(kResizeBandDip, ::GetDpiForWindow(top_level), 96);
}

// True while the window is acting as the quick-capture overlay (topmost) or
// is maximized — no resize edges in either state.
bool ResizeEdgesDisabled(HWND top_level) {
  if (::IsZoomed(top_level)) return true;
  return (::GetWindowLongPtr(top_level, GWL_EXSTYLE) & WS_EX_TOPMOST) != 0;
}

WNDPROC g_flutter_view_proc = nullptr;

LRESULT CALLBACK FlutterViewSubclassProc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam) {
  if (message == WM_NCHITTEST) {
    HWND top_level = ::GetAncestor(hwnd, GA_ROOT);
    if (top_level && !ResizeEdgesDisabled(top_level)) {
      RECT rect;
      ::GetWindowRect(top_level, &rect);
      const int band = ResizeBandFor(top_level);
      const int x = GET_X_LPARAM(lparam);
      const int y = GET_Y_LPARAM(lparam);
      if (x < rect.left + band || x >= rect.right - band ||
          y < rect.top + band || y >= rect.bottom - band) {
        return HTTRANSPARENT;  // fall through to the top-level hit test
      }
    }
  }
  return ::CallWindowProc(g_flutter_view_proc, hwnd, message, wparam, lparam);
}

// Maximized frameless client = the monitor work area (strips the invisible
// frame overhang), minus 2px on any edge that hosts an AUTO-HIDE taskbar —
// cover that last strip and hovering the screen edge can never summon the
// bar back (the Chromium recipe).
bool HandleMaximizedNCCalcSize(HWND hwnd, NCCALCSIZE_PARAMS* sz) {
  HMONITOR monitor = ::MonitorFromRect(&sz->rgrc[0], MONITOR_DEFAULTTONEAREST);
  MONITORINFO mi{};
  mi.cbSize = sizeof(MONITORINFO);
  if (!monitor || !::GetMonitorInfo(monitor, &mi)) {
    return false;
  }
  sz->rgrc[0] = mi.rcWork;

  APPBARDATA state{};
  state.cbSize = sizeof(APPBARDATA);
  if (::SHAppBarMessage(ABM_GETSTATE, &state) & ABS_AUTOHIDE) {
    auto has_bar = [&](UINT edge) {
      APPBARDATA query{};
      query.cbSize = sizeof(APPBARDATA);
      query.uEdge = edge;
      query.rc = mi.rcMonitor;
      return ::SHAppBarMessage(ABM_GETAUTOHIDEBAREX, &query) != 0;
    };
    if (has_bar(ABE_BOTTOM)) sz->rgrc[0].bottom -= 2;
    if (has_bar(ABE_TOP)) sz->rgrc[0].top += 2;
    if (has_bar(ABE_LEFT)) sz->rgrc[0].left += 2;
    if (has_bar(ABE_RIGHT)) sz->rgrc[0].right -= 2;
  }
  return true;
}

LRESULT HitTestResizeEdges(HWND hwnd, LPARAM lparam) {
  RECT rect;
  ::GetWindowRect(hwnd, &rect);
  const int band = ResizeBandFor(hwnd);
  const int x = GET_X_LPARAM(lparam);
  const int y = GET_Y_LPARAM(lparam);
  const bool left = x < rect.left + band;
  const bool right = x >= rect.right - band;
  const bool top = y < rect.top + band;
  const bool bottom = y >= rect.bottom - band;
  if (top && left) return HTTOPLEFT;
  if (top && right) return HTTOPRIGHT;
  if (bottom && left) return HTBOTTOMLEFT;
  if (bottom && right) return HTBOTTOMRIGHT;
  if (top) return HTTOP;
  if (bottom) return HTBOTTOM;
  if (left) return HTLEFT;
  if (right) return HTRIGHT;
  return HTCLIENT;
}

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project,
                             bool start_hidden)
    : project_(project), start_hidden_(start_hidden) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Yield the frameless resize band back to the parent (see namespace above).
  HWND view = flutter_controller_->view()->GetNativeWindow();
  g_flutter_view_proc = reinterpret_cast<WNDPROC>(::SetWindowLongPtr(
      view, GWLP_WNDPROC,
      reinterpret_cast<LONG_PTR>(FlutterViewSubclassProc)));

  quit_handover_msg_ = ::RegisterWindowMessageW(L"Slate.QuitForHandover");
  show_request_msg_ = ::RegisterWindowMessageW(L"Slate.ShowRequested");
  shell_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "slate/shell",
          &flutter::StandardMethodCodec::GetInstance());
  // The main isolate's capture hotkey raises the separate pill window through
  // here (no more morphing this window).
  shell_channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        if (call.method_name() == "showPill") {
          if (show_pill_cb_) show_pill_cb_();
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  // Shown IMMEDIATELY, not on the first frame: the window class now carries the
  // app's own warm-graphite brush (win32_window.cpp), so what appears instantly
  // is Slate's background rather than a white unpainted surface. Waiting for the
  // first frame instead would trade a flash for a second of nothing at all.
  // --hidden (autostart) shows nothing: tray + hotkey only.
  if (!start_hidden_) {
    this->Show();
  }

  // Anything that isn't needed to DRAW the first frame is deferred past it —
  // it was all competing with that frame for the CPU. Raster thread → post,
  // never run work here (see SetFirstFrameCallback).
  first_frame_msg_ = ::RegisterWindowMessageW(L"Slate.FirstFrame");
  HWND self = GetHandle();
  UINT msg = first_frame_msg_;
  flutter_controller_->engine()->SetNextFrameCallback([self, msg]() {
    ::PostMessageW(self, msg, 0, 0);
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SendCapture(const flutter::EncodableValue& value) {
  if (shell_channel_) {
    shell_channel_->InvokeMethod(
        "pillCapture",
        std::make_unique<flutter::EncodableValue>(value));
  }
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Maximized WM_NCCALCSIZE is ours BEFORE the plugins: window_manager's
  // frameless handler would consume it without the auto-hide taskbar inset.
  if (message == WM_NCCALCSIZE && wparam && ::IsZoomed(hwnd)) {
    auto* sz = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
    if (HandleMaximizedNCCalcSize(hwnd, sz)) {
      return 0;
    }
  }

  // Logoff/shutdown: Windows kills the process right after WM_ENDSESSION
  // returns — Dart's quit path never runs. Flush the Rust vault directly
  // (drain write queue + WAL checkpoint); ffi_shutdown_engine is idempotent.
  if (message == WM_ENDSESSION && wparam) {
    if (HMODULE core = ::GetModuleHandleW(L"slate_core.dll")) {
      if (auto shutdown = reinterpret_cast<int (*)()>(
              ::GetProcAddress(core, "ffi_shutdown_engine"))) {
        shutdown();
      }
    }
    return 0;
  }

  // First frame is up — run the work we held back, once, on this thread.
  if (message == first_frame_msg_ && first_frame_msg_ != 0 &&
      !first_frame_done_) {
    first_frame_done_ = true;
    if (first_frame_cb_) first_frame_cb_();
    return 0;
  }

  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  if (message == quit_handover_msg_ && quit_handover_msg_ != 0) {
    // A newer instance is taking over — quit through Dart (Rust flush,
    // tray icon removal), never TerminateProcess.
    if (shell_channel_) {
      shell_channel_->InvokeMethod("quitRequested", nullptr);
    }
    return 0;
  }

  if (message == show_request_msg_ && show_request_msg_ != 0) {
    if (shell_channel_) {
      shell_channel_->InvokeMethod("showRequested", nullptr);
    }
    return 0;
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_NCHITTEST:
      if (!ResizeEdgesDisabled(hwnd)) {
        LRESULT hit = HitTestResizeEdges(hwnd, lparam);
        if (hit != HTCLIENT) {
          return hit;
        }
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
