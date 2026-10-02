#include "document_windows.h"

#include <flutter/standard_method_codec.h>
#include <shobjidl.h>

#include <functional>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "win32_window.h"

// Declared by the engine's flutter_windows_internal.h, which the Flutter
// artifacts do not ship; flutter_windows.dll exports both (FLUTTER_EXPORT),
// and Flutter's own experimental windowing API is built on them. The first
// adds a view to a running engine without handing the engine over, as the
// public FlutterDesktopViewControllerCreate does; the second finds the
// engine by the id Dart reads from PlatformDispatcher.engineId, since the
// C++ wrapper keeps the main window's engine handle to itself. Reassess on
// every Flutter upgrade.
extern "C" {
typedef struct {
  int width;
  int height;
} FlutterDesktopViewControllerProperties;

FLUTTER_EXPORT FlutterDesktopViewControllerRef
FlutterDesktopEngineCreateViewController(
    FlutterDesktopEngineRef engine,
    const FlutterDesktopViewControllerProperties* properties);

FLUTTER_EXPORT FlutterDesktopEngineRef
FlutterDesktopEngineForId(int64_t engine_id);
}

namespace {

constexpr char kChannel[] = "planchette/windows";

// WindowHostMethod, WindowHostEvent, and WindowHostKey in Dart.
constexpr char kIsAvailableMethod[] = "isAvailable";
constexpr char kCreateMethod[] = "create";
constexpr char kDestroyMethod[] = "destroy";
constexpr char kActivateMethod[] = "activate";
constexpr char kHideMethod[] = "hide";
constexpr char kIsFullScreenMethod[] = "isFullScreen";
constexpr char kSetFullScreenMethod[] = "setFullScreen";
constexpr char kSetTitleMethod[] = "setTitle";
constexpr char kPickOpenFilesMethod[] = "pickOpenFiles";
constexpr char kPickSavePathMethod[] = "pickSavePath";
constexpr char kActivatedEvent[] = "activated";
constexpr char kCloseRequestedEvent[] = "closeRequested";
constexpr char kViewIdKey[] = "viewId";
constexpr char kEngineIdKey[] = "engineId";
constexpr char kFullScreenKey[] = "fullScreen";
constexpr char kTitleKey[] = "title";
constexpr char kSuggestedNameKey[] = "suggestedName";
constexpr char kInitialDirectoryKey[] = "initialDirectory";

constexpr char kBadArgsError[] = "BAD_ARGS";
constexpr char kCreateFailedError[] = "CREATE_FAILED";
constexpr char kPickerFailedError[] = "PICKER_FAILED";

constexpr wchar_t kWindowTitle[] = L"Planchette";

// The workspace's minimum content size (WindowOptions in
// lib/services/desktop_window.dart), in logical pixels, which
// window_manager applies to the main window.
constexpr int kMinimumWidth = 640;
constexpr int kMinimumHeight = 400;

// How far a new window sits from the one it opens over, in logical pixels.
constexpr int kCascadeOffset = 24;

// The engine's implicit view: the main window.
constexpr int64_t kMainViewId = 0;

const flutter::EncodableValue* Argument(const flutter::EncodableMap* arguments,
                                        const char* key) {
  if (arguments == nullptr) {
    return nullptr;
  }
  const auto it = arguments->find(flutter::EncodableValue(key));
  return it == arguments->end() ? nullptr : &it->second;
}

// The standard codec sends a Dart int as 32 bits when it fits.
std::optional<int64_t> IntArgument(const flutter::EncodableMap* arguments,
                                   const char* key) {
  const flutter::EncodableValue* value = Argument(arguments, key);
  if (value == nullptr) {
    return std::nullopt;
  }
  if (const auto* narrow = std::get_if<int32_t>(value)) {
    return *narrow;
  }
  if (const auto* wide = std::get_if<int64_t>(value)) {
    return *wide;
  }
  return std::nullopt;
}

const std::string* StringArgument(const flutter::EncodableMap* arguments,
                                  const char* key) {
  const flutter::EncodableValue* value = Argument(arguments, key);
  return value == nullptr ? nullptr : std::get_if<std::string>(value);
}

// The channel arguments arrive as UTF-8 strings; the shell APIs want
// UTF-16.
std::wstring WideFromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                         utf8.data(),
                                         static_cast<int>(utf8.size()),
                                         nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring wide(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                        static_cast<int>(utf8.size()), wide.data(), length);
  return wide;
}

std::string Utf8FromWide(const std::wstring& wide) {
  if (wide.empty()) {
    return std::string();
  }
  const int length = ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                                           static_cast<int>(wide.size()),
                                           nullptr, 0, nullptr, nullptr);
  if (length <= 0) {
    return std::string();
  }
  std::string utf8(length, '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, wide.data(),
                        static_cast<int>(wide.size()), utf8.data(), length,
                        nullptr, nullptr);
  return utf8;
}

// The picked item's path, or none when the shell gives it in a form that
// is not a file path (SIGDN_FILESYSPATH fails on virtual items).
std::optional<std::string> ItemPath(IShellItem* item) {
  PWSTR raw = nullptr;
  if (FAILED(item->GetDisplayName(SIGDN_FILESYSPATH, &raw)) ||
      raw == nullptr) {
    // The contract says the out-parameter stays null on failure; a shell
    // that still wrote it must not leak it.
    if (raw != nullptr) {
      ::CoTaskMemFree(raw);
    }
    return std::nullopt;
  }
  std::wstring wide(raw);
  ::CoTaskMemFree(raw);
  return Utf8FromWide(wide);
}

}  // namespace

// One extra document window: a top-level window around a view of the app's
// engine.
class DocumentFlutterWindow : public Win32Window {
 public:
  DocumentFlutterWindow(
      FlutterDesktopEngineRef engine,
      std::function<void(int64_t)> on_activated,
      std::function<void(int64_t)> on_close_requested)
      : engine_(engine),
        on_activated_(std::move(on_activated)),
        on_close_requested_(std::move(on_close_requested)) {}

  // Destroyed through DestroyWindow so OnDestroy below still runs: from
  // Win32Window's destructor only the base class's would.
  ~DocumentFlutterWindow() override {
    if (GetHandle() != nullptr) {
      DestroyWindow(GetHandle());
    }
  }

  int64_t view_id() const { return view_id_; }

  // The Flutter view's HWND, a child of this window.
  HWND view() const { return view_; }

  bool IsFullScreen() const { return full_screen_; }

  // Full screen the way Win32 apps do it: the frame goes, and the window
  // covers its monitor; leaving puts the frame and placement back.
  void SetFullScreen(bool full_screen) {
    HWND hwnd = GetHandle();
    if (hwnd == nullptr || full_screen == full_screen_) {
      return;
    }
    if (full_screen) {
      windowed_style_ = GetWindowLong(hwnd, GWL_STYLE);
      windowed_placement_.length = sizeof(WINDOWPLACEMENT);
      GetWindowPlacement(hwnd, &windowed_placement_);
      MONITORINFO monitor = {sizeof(MONITORINFO)};
      GetMonitorInfo(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                     &monitor);
      SetWindowLong(hwnd, GWL_STYLE, windowed_style_ & ~WS_OVERLAPPEDWINDOW);
      SetWindowPos(hwnd, HWND_TOP, monitor.rcMonitor.left,
                   monitor.rcMonitor.top,
                   monitor.rcMonitor.right - monitor.rcMonitor.left,
                   monitor.rcMonitor.bottom - monitor.rcMonitor.top,
                   SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    } else {
      SetWindowLong(hwnd, GWL_STYLE, windowed_style_);
      SetWindowPlacement(hwnd, &windowed_placement_);
      SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                       SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
    }
    full_screen_ = full_screen;
  }

 protected:
  bool OnCreate() override {
    if (!Win32Window::OnCreate()) {
      return false;
    }
    RECT frame = GetClientArea();
    FlutterDesktopViewControllerProperties properties = {
        frame.right - frame.left, frame.bottom - frame.top};
    controller_ =
        FlutterDesktopEngineCreateViewController(engine_, &properties);
    if (controller_ == nullptr) {
      return false;
    }
    view_id_ =
        static_cast<int64_t>(FlutterDesktopViewControllerGetViewId(controller_));
    view_ = FlutterDesktopViewGetHWND(
        FlutterDesktopViewControllerGetView(controller_));
    SetChildContent(view_);
    FlutterDesktopViewControllerForceRedraw(controller_);
    return true;
  }

  void OnDestroy() override {
    if (controller_ != nullptr) {
      // Removes the view from the engine; the engine stays, the main
      // window's.
      FlutterDesktopViewControllerDestroy(controller_);
      controller_ = nullptr;
    }
    Win32Window::OnDestroy();
  }

  LRESULT MessageHandler(HWND hwnd, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override {
    switch (message) {
      case WM_CLOSE:
        // The close button, the window menu, Alt+F4: Dart decides, and
        // destroys the window once its widgets are gone (or quits, for the
        // last window). Not the engine's lifecycle either, which would
        // treat the last visible window's close as a quit request.
        on_close_requested_(view_id_);
        return 0;
      case WM_ACTIVATE:
        if (LOWORD(wparam) != WA_INACTIVE) {
          on_activated_(view_id_);
        }
        break;
      case WM_GETMINMAXINFO: {
        const double scale = FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
        RECT minimum = {0, 0, static_cast<LONG>(kMinimumWidth * scale),
                        static_cast<LONG>(kMinimumHeight * scale)};
        AdjustWindowRectEx(&minimum, GetWindowLong(hwnd, GWL_STYLE), FALSE,
                           GetWindowLong(hwnd, GWL_EXSTYLE));
        auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
        info->ptMinTrackSize.x = minimum.right - minimum.left;
        info->ptMinTrackSize.y = minimum.bottom - minimum.top;
        return 0;
      }
      case WM_FONTCHANGE:
        FlutterDesktopEngineReloadSystemFonts(engine_);
        break;
    }
    LRESULT result = 0;
    if (FlutterDesktopEngineProcessExternalWindowMessage(
            engine_, hwnd, message, wparam, lparam, &result)) {
      return result;
    }
    return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
  }

 private:
  FlutterDesktopEngineRef engine_;
  std::function<void(int64_t)> on_activated_;
  std::function<void(int64_t)> on_close_requested_;
  FlutterDesktopViewControllerRef controller_ = nullptr;
  HWND view_ = nullptr;
  int64_t view_id_ = -1;
  bool full_screen_ = false;
  LONG windowed_style_ = 0;
  WINDOWPLACEMENT windowed_placement_ = {sizeof(WINDOWPLACEMENT)};
};

DocumentWindowsHost::DocumentWindowsHost(HWND main_window,
                                         flutter::BinaryMessenger* messenger)
    : main_window_(main_window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, kChannel, &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) { HandleMethodCall(call, std::move(result)); });
}

DocumentWindowsHost::~DocumentWindowsHost() {
  channel_->SetMethodCallHandler(nullptr);
  // Each window removes its view from the engine as it goes, before the
  // engine does.
  windows_.clear();
}

void DocumentWindowsHost::HandleMainWindowMessage(UINT message,
                                                  WPARAM wparam) {
  if (message == WM_ACTIVATE && LOWORD(wparam) != WA_INACTIVE) {
    SendEvent(kActivatedEvent, kMainViewId);
  }
}

void DocumentWindowsHost::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();
  const auto* raw_arguments = call.arguments();
  const auto* arguments =
      raw_arguments == nullptr
          ? nullptr
          : std::get_if<flutter::EncodableMap>(raw_arguments);

  if (method == kIsAvailableMethod) {
    result->Success(flutter::EncodableValue(true));
    return;
  }
  if (method == kCreateMethod) {
    Create(arguments, std::move(result));
    return;
  }
  if (method != kDestroyMethod && method != kActivateMethod &&
      method != kHideMethod && method != kIsFullScreenMethod &&
      method != kSetFullScreenMethod && method != kSetTitleMethod &&
      method != kPickOpenFilesMethod && method != kPickSavePathMethod) {
    result->NotImplemented();
    return;
  }

  const std::optional<int64_t> view_id = IntArgument(arguments, kViewIdKey);
  HWND window = view_id ? WindowFor(*view_id) : nullptr;
  if (window == nullptr) {
    result->Error(kBadArgsError, "no window has that view id");
    return;
  }

  if (method == kDestroyMethod) {
    // The main window's view cannot leave the engine; window_manager
    // destroys that window, as the app quits.
    if (*view_id != kMainViewId) {
      pending_show_.erase(*view_id);
      windows_.erase(*view_id);
    }
  } else if (method == kActivateMethod) {
    // Shows it again if it was hidden, and brings it forward either way.
    pending_show_.erase(*view_id);
    ShowWindow(window, IsIconic(window) ? SW_RESTORE : SW_SHOW);
    SetForegroundWindow(window);
  } else if (method == kHideMethod) {
    // A pending first-frame show must not resurrect a window Dart just
    // hid.
    pending_show_.erase(*view_id);
    ShowWindow(window, SW_HIDE);
  } else if (method == kSetTitleMethod) {
    const std::string* title = StringArgument(arguments, kTitleKey);
    const std::wstring wide = title == nullptr ? L"" : WideFromUtf8(*title);
    if (title == nullptr || wide.empty()) {
      result->Error(kBadArgsError, "setTitle needs a title");
      return;
    }
    SetWindowTextW(window, wide.c_str());
  } else if (method == kPickOpenFilesMethod) {
    PickOpenFiles(window, std::move(result));
    return;
  } else if (method == kPickSavePathMethod) {
    PickSavePath(window, arguments, std::move(result));
    return;
  } else {
    // Full screen is the extra windows' only: window_manager owns the main
    // window's.
    DocumentFlutterWindow* extra = ExtraWindow(*view_id);
    if (extra == nullptr) {
      result->Error(kBadArgsError, "the main window's full screen is "
                                 "window_manager's");
      return;
    }
    if (method == kIsFullScreenMethod) {
      result->Success(flutter::EncodableValue(extra->IsFullScreen()));
      return;
    }
    const flutter::EncodableValue* full_screen =
        Argument(arguments, kFullScreenKey);
    const bool* value =
        full_screen == nullptr ? nullptr : std::get_if<bool>(full_screen);
    if (value == nullptr) {
      result->Error(kBadArgsError, "setFullScreen needs a fullScreen bool");
      return;
    }
    extra->SetFullScreen(*value);
  }
  result->Success();
}

void DocumentWindowsHost::Create(
    const flutter::EncodableMap* arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::optional<int64_t> engine_id =
      IntArgument(arguments, kEngineIdKey);
  if (!engine_id || *engine_id == 0) {
    result->Error(kBadArgsError, "create needs the engine id");
    return;
  }
  FlutterDesktopEngineRef engine = FlutterDesktopEngineForId(*engine_id);
  if (engine == nullptr) {
    result->Error(kCreateFailedError, "no engine has that id");
    return;
  }

  // The size of the window it opens over, and a step down and right of it.
  HWND reference = GetForegroundWindow();
  if (reference != main_window_) {
    bool ours = false;
    for (const auto& entry : windows_) {
      ours = ours || entry.second->GetHandle() == reference;
    }
    if (!ours) {
      reference = main_window_;
    }
  }
  RECT frame;
  GetWindowRect(reference, &frame);
  const double scale = FlutterDesktopGetDpiForHWND(reference) / 96.0;
  const LONG x = frame.left + static_cast<LONG>(kCascadeOffset * scale);
  const LONG y = frame.top + static_cast<LONG>(kCascadeOffset * scale);
  // Create takes the origin in logical pixels and picks the monitor from
  // it; the window is then placed in physical pixels, which the unsigned
  // logical origin cannot carry for a monitor left of or above the primary
  // one.
  Win32Window::Point origin(
      static_cast<unsigned int>((x > 0 ? x : 0) / scale),
      static_cast<unsigned int>((y > 0 ? y : 0) / scale));
  Win32Window::Size size(
      static_cast<unsigned int>((frame.right - frame.left) / scale),
      static_cast<unsigned int>((frame.bottom - frame.top) / scale));

  auto window = std::make_unique<DocumentFlutterWindow>(
      engine,
      [this](int64_t view_id) { SendEvent(kActivatedEvent, view_id); },
      [this](int64_t view_id) { SendEvent(kCloseRequestedEvent, view_id); });
  const std::string* given_title = StringArgument(arguments, kTitleKey);
  std::wstring title =
      given_title == nullptr ? kWindowTitle : WideFromUtf8(*given_title);
  if (title.empty()) {
    title = kWindowTitle;
  }
  if (!window->Create(title.c_str(), origin, size) || window->view_id() < 0) {
    result->Error(kCreateFailedError, "the window was not created");
    return;
  }
  SetWindowPos(window->GetHandle(), nullptr, x, y, 0, 0,
               SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);

  const int64_t view_id = window->view_id();
  windows_[view_id] = std::move(window);
  // Shown on its first frame, like the main window, so it never flashes an
  // empty frame before Flutter has drawn. The callback is the engine's one
  // next-frame slot, so it shows every window still waiting.
  pending_show_.insert(view_id);
  FlutterDesktopEngineSetNextFrameCallback(
      engine,
      [](void* host) { static_cast<DocumentWindowsHost*>(host)->ShowPending(); },
      this);
  result->Success(flutter::EncodableValue(view_id));
}

// file_selector's dialogs parent to the plugin registry's view — the main
// window — which may be hidden while other windows are open; these belong
// to the window that asked. Cancel is an empty list or a null, matching the
// Dart contract.
void DocumentWindowsHost::PickOpenFiles(
    HWND owner,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  IFileOpenDialog* dialog = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_ALL,
                                  IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || dialog == nullptr) {
    result->Error(kPickerFailedError, "the open dialog did not start");
    return;
  }
  FILEOPENDIALOGOPTIONS options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_ALLOWMULTISELECT);
  hr = dialog->Show(owner);
  flutter::EncodableList paths;
  if (SUCCEEDED(hr)) {
    IShellItemArray* items = nullptr;
    if (SUCCEEDED(dialog->GetResults(&items)) && items != nullptr) {
      DWORD count = 0;
      items->GetCount(&count);
      for (DWORD i = 0; i < count; ++i) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(items->GetItemAt(i, &item)) && item != nullptr) {
          std::optional<std::string> path = ItemPath(item);
          if (path) {
            paths.push_back(flutter::EncodableValue(*path));
          }
          item->Release();
        }
      }
      items->Release();
    }
  } else if (hr != HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    dialog->Release();
    result->Error(kPickerFailedError, "the open dialog failed");
    return;
  }
  dialog->Release();
  result->Success(flutter::EncodableValue(paths));
}

void DocumentWindowsHost::PickSavePath(
    HWND owner,
    const flutter::EncodableMap* arguments,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string* suggested = StringArgument(arguments, kSuggestedNameKey);
  const std::wstring suggested_wide =
      suggested == nullptr ? L"" : WideFromUtf8(*suggested);
  if (suggested_wide.empty()) {
    result->Error(kBadArgsError, "pickSavePath needs a suggestedName");
    return;
  }
  IFileSaveDialog* dialog = nullptr;
  HRESULT hr = ::CoCreateInstance(CLSID_FileSaveDialog, nullptr, CLSCTX_ALL,
                                  IID_PPV_ARGS(&dialog));
  if (FAILED(hr) || dialog == nullptr) {
    result->Error(kPickerFailedError, "the save dialog did not start");
    return;
  }
  FILEOPENDIALOGOPTIONS options = 0;
  dialog->GetOptions(&options);
  dialog->SetOptions(options | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT);
  dialog->SetFileName(suggested_wide.c_str());
  const std::string* directory = StringArgument(arguments, kInitialDirectoryKey);
  if (directory != nullptr && !directory->empty()) {
    IShellItem* folder = nullptr;
    if (SUCCEEDED(::SHCreateItemFromParsingName(
            WideFromUtf8(*directory).c_str(), nullptr,
            IID_PPV_ARGS(&folder))) &&
        folder != nullptr) {
      dialog->SetDefaultFolder(folder);
      folder->Release();
    }
  }
  hr = dialog->Show(owner);
  if (hr == HRESULT_FROM_WIN32(ERROR_CANCELLED)) {
    dialog->Release();
    result->Success();
    return;
  }
  if (FAILED(hr)) {
    dialog->Release();
    result->Error(kPickerFailedError, "the save dialog failed");
    return;
  }
  IShellItem* item = nullptr;
  hr = dialog->GetResult(&item);
  dialog->Release();
  if (FAILED(hr) || item == nullptr) {
    result->Success();
    return;
  }
  std::optional<std::string> path = ItemPath(item);
  item->Release();
  result->Success(path ? flutter::EncodableValue(*path)
                       : flutter::EncodableValue());
}

void DocumentWindowsHost::ShowPending() {
  for (const int64_t view_id : pending_show_) {
    if (DocumentFlutterWindow* window = ExtraWindow(view_id)) {
      window->Show();
      SetForegroundWindow(window->GetHandle());
    }
  }
  pending_show_.clear();
}

void DocumentWindowsHost::SendEvent(const char* event, int64_t view_id) {
  channel_->InvokeMethod(
      event, std::make_unique<flutter::EncodableValue>(flutter::EncodableMap{
                 {flutter::EncodableValue(kViewIdKey),
                  flutter::EncodableValue(view_id)}}));
}

HWND DocumentWindowsHost::WindowFor(int64_t view_id) const {
  if (view_id == kMainViewId) {
    return main_window_;
  }
  DocumentFlutterWindow* window = ExtraWindow(view_id);
  return window == nullptr ? nullptr : window->GetHandle();
}

HWND DocumentWindowsHost::ViewFor(int64_t view_id) const {
  DocumentFlutterWindow* window = ExtraWindow(view_id);
  return window == nullptr ? nullptr : window->view();
}

DocumentFlutterWindow* DocumentWindowsHost::ExtraWindow(
    int64_t view_id) const {
  const auto it = windows_.find(view_id);
  return it == windows_.end() ? nullptr : it->second.get();
}
