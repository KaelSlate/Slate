#ifndef RUNNER_NOTIFY_WINDOW_H_
#define RUNNER_NOTIFY_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <functional>
#include <memory>

#include "win32_window.h"

// The reminder window. Its own Flutter engine (`--notify` entrypoint, see
// notify_window.dart), sized to the work area exactly like the pill so that
// showing it never RESIZES — a resize on a just-shown window is the cold
// swapchain trap that cost rounds 1-8.
//
// Two things separate it from the pill, and both are the whole point:
//   * it NEVER takes focus (WS_EX_NOACTIVATE) — the person keeps typing;
//   * everything outside the card is not part of the window at all
//     (SetWindowRgn), so a click there lands in whatever app is underneath.
//
// SetWindowRgn rather than WM_NCHITTEST/HTTRANSPARENT: HTTRANSPARENT only
// forwards the hit test to other windows OF THE SAME THREAD, so it could never
// pass a click to another process — the click would simply die here. A region
// is the window's real shape as far as DWM and the hit test are concerned, and
// it does not touch the engine's viewport, so it costs nothing to reshape.
class NotifyWindow : public Win32Window {
 public:
  explicit NotifyWindow(const flutter::DartProject& project);
  virtual ~NotifyWindow();

  // Show the card(s). |cards| is the payload built by the main isolate.
  // Returns false when Windows says now is a bad moment (Focus Assist, a
  // full-screen game, a locked screen) — the caller must NOT mark the reminder
  // as spoken in that case, or it is lost forever.
  bool ShowCards(const flutter::EncodableValue& cards);

  // Hide immediately: the card timed out, was acted on, or the capture hotkey
  // was pressed (the person always wins over the machine).
  void HideNow();

  // Set by main() so a tap on the card reaches the MAIN isolate, which owns the
  // DB and the undo stack.
  void SetActionSink(std::function<void(const flutter::EncodableValue&)> sink) {
    action_sink_ = std::move(sink);
  }

  // Told to the scheduler when the card leaves on its own.
  void SetClosedSink(std::function<void()> sink) {
    closed_sink_ = std::move(sink);
  }

 protected:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // Same two lessons the pill carries: an engine only adopts a resize while it
  // is presenting, and nothing may reach the screen before Dart has painted.
  void ShowAtHealedSize(const RECT& work, int width, int height);
  void StepHeal();
  void RevealWhenPainted();
  void Uncloak();
  void SetCloak(bool on);

  // Carve the window down to the card. |hit| is [l, t, r, b] in PHYSICAL
  // pixels, sent by Dart with its reveal answer — Dart already knows its own
  // devicePixelRatio, so no DPI arithmetic happens on this side.
  void ApplyHitRegion(const flutter::EncodableValue* hit);

  // Would Windows deliver a notification of its own right now?
  static bool WindowsAcceptsNotifications();

  // Ask the compositor for the same acrylic the shell gives its own toasts.
  // Flutter cannot blur foreign windows; DWM can. Win11 22H2+, silently
  // declined on older builds.
  void EnableAcrylicBackdrop();

  flutter::DartProject project_;
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::function<void(const flutter::EncodableValue&)> action_sink_;
  std::function<void()> closed_sink_;
  int heal_phase_ = 0;
  bool cloaked_ = false;
  // True when the compositor accepted the acrylic backdrop. Dart asks, so it
  // can paint a translucent body over real blur instead of a solid one.
  bool acrylic_ = false;
};

#endif  // RUNNER_NOTIFY_WINDOW_H_
