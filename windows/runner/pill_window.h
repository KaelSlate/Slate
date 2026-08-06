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
  // Show the window when its size no longer matches the screen it is about to
  // appear on (a resolution switch, a monitor hotplug). The engine only adopts
  // a resize while it is presenting, so this wakes it first.
  void ShowAtHealedSize(const RECT& work, int width, int height);
  // Timer-driven tail of that heal: nudge the size, then play the entrance.
  void StepHeal();

  // Ask Dart to play the entrance and uncloak only once it answers — i.e. once
  // a frame of its own has actually reached the compositor.
  void RevealWhenPainted();
  void Uncloak();
  // DWM cloak: the window keeps rendering, it just isn't composited onto the
  // desktop. This is what keeps every pre-Flutter pixel off the screen.
  void SetCloak(bool on);

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::function<void(const flutter::EncodableValue&)> capture_sink_;
  HWND prior_foreground_ = nullptr;  // app to restore focus to on dismiss
  int heal_phase_ = 0;               // 0 idle, 1 nudge due, 2 entrance due
  bool cloaked_ = false;
};

#endif  // RUNNER_PILL_WINDOW_H_
