#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

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
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
