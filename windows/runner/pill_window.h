#ifndef RUNNER_PILL_WINDOW_H_
#define RUNNER_PILL_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>

#include <memory>

#include "win32_window.h"

// The SEPARATE global-capture pill window. It hosts its OWN Flutter engine,
// launched with the `--pill` entrypoint arg (see pill_window.dart), and is a
// borderless, topmost tool window. Because it is a distinct OS window, the main
// app window is never resized/hidden/re-maximized to become the pill — which is
// what the rounds 1-8 morph did, and every one of those bugs (cold swapchain,
// jerk, maximize desync, taskbar flash) lived there. Created hidden; the main
// app shows/positions it on the capture hotkey.
class PillWindow : public Win32Window {
 public:
  explicit PillWindow(const flutter::DartProject& project);
  virtual ~PillWindow();

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
};

#endif  // RUNNER_PILL_WINDOW_H_
