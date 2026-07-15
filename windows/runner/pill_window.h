#ifndef RUNNER_PILL_WINDOW_H_
#define RUNNER_PILL_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <functional>
#include <memory>

#include "win32_window.h"

// The SEPARATE global-capture pill window. It hosts its OWN Flutter engine,
// launched with the `--pill` entrypoint arg (see pill_window.dart), and is a
// borderless, topmost tool window. Because it is a distinct OS window, the main
// app window is never resized/hidden/re-maximized to become the pill — which is
// what the rounds 1-8 morph did, and every one of those bugs (cold swapchain,
// jerk, maximize desync, taskbar flash) lived there. Created hidden; the main
// app shows/positions it on the capture hotkey via ShowPill().
class PillWindow : public Win32Window {
 public:
  explicit PillWindow(const flutter::DartProject& project);
  virtual ~PillWindow();

  // Show the pill centered on the cursor's monitor work area, focused, and tell
  // the pill isolate to play its entrance. Instant — no morph, no resize dance.
  void ShowPill();
  // Hide the pill and hand the foreground back to the app the user was in.
  void HidePill();

  // Set by main() so a submitted capture can reach the MAIN isolate (one engine,
  // one DB). Receives the serialized ParseResult map from the pill.
  void SetCaptureSink(
      std::function<void(const flutter::EncodableValue&)> sink) {
    capture_sink_ = std::move(sink);
  }

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::function<void(const flutter::EncodableValue&)> capture_sink_;
  HWND prior_foreground_ = nullptr;  // app to restore focus to on dismiss
};

#endif  // RUNNER_PILL_WINDOW_H_
