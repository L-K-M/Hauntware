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
  ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work_area, 0);
  const double scale_factor =
      FlutterDesktopGetDpiForMonitor(
          ::MonitorFromRect(&work_area, MONITOR_DEFAULTTONEAREST)) /
      96.0;
  Win32Window::Point origin(
      static_cast<int>(
          (work_area.left +
           (work_area.right - work_area.left -
            static_cast<LONG>(size.width * scale_factor)) /
               2) /
          scale_factor),
      static_cast<int>(
          (work_area.top +
           (work_area.bottom - work_area.top -
            static_cast<LONG>(size.height * scale_factor)) /
               2) /
          scale_factor));
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
