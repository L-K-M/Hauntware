#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Match the runtime WindowOptions in desktop_window.dart so a window that
  // becomes visible before Dart resizes it already has the final geometry:
  // 1080x760 centered on the work area instead of 1280x720 at (10, 10).
  Win32Window::Size size(1080, 760);
  RECT work_area{};
  if (!::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0) ||
      work_area.right <= work_area.left || work_area.bottom <= work_area.top) {
    // Center on the primary screen instead: an empty rectangle, failed or
    // reported, would park the window in the top-left corner.
    work_area = {0, 0, ::GetSystemMetrics(SM_CXSCREEN),
                 ::GetSystemMetrics(SM_CYSCREEN)};
  }
  const double scale_factor =
      FlutterDesktopGetDpiForMonitor(
          ::MonitorFromRect(&work_area, MONITOR_DEFAULTTONEAREST)) /
      96.0;
  const int scaled_width = static_cast<int>(size.width * scale_factor);
  const int scaled_height = static_cast<int>(size.height * scale_factor);
  const int window_x = static_cast<int>(
      (work_area.left +
       (work_area.right - work_area.left - scaled_width) / 2) /
      scale_factor);
  const int window_y = static_cast<int>(
      (work_area.top +
       (work_area.bottom - work_area.top - scaled_height) / 2) /
      scale_factor);
  // Point is unsigned: when the window is larger than the work area
  // (125%+ DPI, small panels) the centered offset goes negative and would
  // wrap — clamp to the work area edge instead of spawning off-screen.
  const int edge_x = static_cast<int>(work_area.left / scale_factor);
  const int edge_y = static_cast<int>(work_area.top / scale_factor);
  Win32Window::Point origin(window_x > edge_x ? window_x : edge_x,
                            window_y > edge_y ? window_y : edge_y);
  if (!window.Create(L"Planchette", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
