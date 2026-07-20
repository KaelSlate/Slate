#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <functional>
#include <memory>

#include "flutter_window.h"
#include "pill_window.h"
#include "utils.h"

namespace {

// Single instance, newest-wins: a second launch asks the running Slate to
// quit cleanly (Rust flush + tray icon removal happen on the Dart side),
// waits for it to die, then becomes the instance. This is what keeps one
// tray icon / one hotkey owner across autostart + manual launches + dev runs.
void TakeOverSingleInstance() {
  ::CreateMutexW(nullptr, TRUE, L"Local\\Slate.SingleInstance");
  if (::GetLastError() != ERROR_ALREADY_EXISTS) {
    return;
  }
  HWND prev = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Slate");
  if (prev) {
    ::PostMessageW(prev, ::RegisterWindowMessageW(L"Slate.QuitForHandover"),
                   0, 0);
    for (int i = 0; i < 100 && ::IsWindow(prev); ++i) {
      ::Sleep(50);  // <=5s for the old engine to drain writes and exit
    }
  }
  // Old instance gone or hung — either way, proceed. A hung twin is a bug,
  // but a refused launch would look worse.
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  TakeOverSingleInstance();

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // Autostart runs "slate.exe --hidden": tray + hotkey only. The window must
  // stay unshown from the very first native frame — Dart decides visibility.
  const bool start_hidden =
      command_line && ::wcsstr(command_line, L"--hidden") != nullptr;

  FlutterWindow window(project, start_hidden);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Slate", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Separate capture-pill window: its own Flutter engine (`--pill` entrypoint),
  // borderless + topmost + no taskbar/alt-tab entry. Created at the primary
  // work-area size so showing it never RESIZES (a resize on a just-shown window
  // is the cold-swapchain trap) — ShowPill only repositions. Lives for the whole
  // process, shown on the hotkey.
  //
  // Built AFTER the main window's first frame, not alongside it: booting a
  // SECOND Flutter engine here was competing with the first engine for CPU and
  // GPU during the exact stretch the user is staring at an empty window. The
  // hotkey can't fire before the app is drawn anyway.
  std::unique_ptr<PillWindow> pill_window;
  flutter::DartProject pill_project(L"data");
  pill_project.set_dart_entrypoint_arguments({"--pill"});

  auto build_pill = [&]() {
    if (pill_window) return;
    RECT wa = {0, 0, 1366, 768};
    ::SystemParametersInfo(SPI_GETWORKAREA, 0, &wa, 0);
    pill_window = std::make_unique<PillWindow>(pill_project);
    Win32Window::Point pill_origin(wa.left, wa.top);
    Win32Window::Size pill_size(wa.right - wa.left, wa.bottom - wa.top);
    pill_window->Create(L"SlatePill", pill_origin, pill_size, WS_POPUP,
                        WS_EX_TOPMOST | WS_EX_TOOLWINDOW);
    // Pill submit -> main isolate creates the task (one engine, one DB).
    pill_window->SetCaptureSink(
        [&window](const flutter::EncodableValue& v) { window.SendCapture(v); });
  };

  if (start_hidden) {
    // Autostart: no window is ever shown, so there is no first frame to stay
    // out of the way of — and the hotkey is the ONLY reason this process
    // exists. Build the pill now; deferring it here would risk never building
    // it at all.
    build_pill();
  } else {
    window.SetFirstFrameCallback(build_pill);
  }

  // Wired up front: a hotkey that somehow beats the first frame is a no-op
  // rather than a crash.
  window.SetShowPillCallback([&pill_window]() {
    if (pill_window) pill_window->ShowPill();
  });

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
