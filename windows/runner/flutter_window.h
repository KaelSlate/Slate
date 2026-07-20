#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <functional>
#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  // |start_hidden| keeps the native window unshown (autostart --hidden);
  // the Dart side owns visibility from then on.
  explicit FlutterWindow(const flutter::DartProject& project,
                         bool start_hidden = false);
  virtual ~FlutterWindow();

  // The main isolate's hotkey asks (over slate/shell) to raise the separate
  // pill window; main() wires this to PillWindow::ShowPill.
  void SetShowPillCallback(std::function<void()> cb) {
    show_pill_cb_ = std::move(cb);
  }
  // A submitted capture from the pill window is delivered to the MAIN isolate
  // (one engine, one DB) as `pillCapture` on slate/shell.
  void SendCapture(const flutter::EncodableValue& value);

  // Runs ONCE on the UI thread after this window has presented its first frame.
  // Anything heavy that isn't needed to draw that frame belongs here — see
  // main(), which defers booting the pill's second Flutter engine onto it.
  void SetFirstFrameCallback(std::function<void()> cb) {
    first_frame_cb_ = std::move(cb);
  }

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  bool start_hidden_ = false;

  // slate/shell — runner-to-Dart requests (single-instance handover).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      shell_channel_;

  // "Quit, a newer instance is taking over" (see main.cpp).
  UINT quit_handover_msg_ = 0;

  // External "open the app" request — drives the same Dart path as a tray
  // click (openApp). Used by the e2e harness; tray clicks aren't scriptable.
  UINT show_request_msg_ = 0;

  // Raises the separate pill window (wired to PillWindow::ShowPill in main()).
  std::function<void()> show_pill_cb_;

  // Deferred-until-first-frame work. The engine's frame callback arrives on the
  // RASTER thread, so it only posts |first_frame_msg_|; the callback itself runs
  // from MessageHandler, i.e. on the UI thread, exactly once.
  std::function<void()> first_frame_cb_;
  UINT first_frame_msg_ = 0;
  bool first_frame_done_ = false;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
