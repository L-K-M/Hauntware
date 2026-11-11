#include "single_instance.h"

#include <shellapi.h>
#include <windows.h>

#include <string>
#include <vector>

namespace {

constexpr wchar_t kInstanceMutexName[] =
    L"Local\\ch.lkmc.planchette.single-instance-v1";
constexpr wchar_t kPrimaryWindowProperty[] =
    L"ch.lkmc.planchette.single-instance-v1";
constexpr DWORD kInitialPathCapacity = MAX_PATH;
constexpr DWORD kMaximumPathCapacity = 32768;
constexpr DWORD kPrimaryWindowPollIntervalMs = 25;
constexpr ULONGLONG kPrimaryWindowStartupTimeoutMs = 30000;
constexpr UINT kDocumentDeliveryTimeoutMs = 5000;

// The creating UI thread owns this mutex for the process lifetime. Windows
// releases it if startup crashes, so one waiting activation can take over.
HANDLE g_primary_instance_mutex = nullptr;

struct PrimaryWindowSearch {
  std::wstring executable;
  HWND found = nullptr;
};

struct VisibleWindowSearch {
  std::wstring executable;
  HWND found = nullptr;
};

std::wstring ExecutablePath() {
  DWORD capacity = kInitialPathCapacity;
  while (capacity <= kMaximumPathCapacity) {
    std::vector<wchar_t> buffer(capacity);
    SetLastError(ERROR_SUCCESS);
    const DWORD length =
        GetModuleFileNameW(nullptr, buffer.data(), capacity);
    if (length == 0) {
      return std::wstring();
    }
    if (length < capacity - 1 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
      return std::wstring(buffer.data(), length);
    }
    capacity *= 2;
  }
  return std::wstring();
}

std::wstring ProcessExecutablePath(HWND window) {
  DWORD process_id = 0;
  GetWindowThreadProcessId(window, &process_id);
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE,
                               process_id);
  if (process == nullptr) {
    return std::wstring();
  }

  std::vector<wchar_t> buffer(kMaximumPathCapacity);
  DWORD length = static_cast<DWORD>(buffer.size());
  const bool read = QueryFullProcessImageNameW(process, 0, buffer.data(),
                                                &length) != FALSE;
  CloseHandle(process);
  if (!read) {
    return std::wstring();
  }
  return std::wstring(buffer.data(), length);
}

BOOL CALLBACK FindPrimaryWindow(HWND window, LPARAM raw_state) {
  if (GetPropW(window, kPrimaryWindowProperty) == nullptr) {
    return TRUE;
  }

  auto* state = reinterpret_cast<PrimaryWindowSearch*>(raw_state);
  const std::wstring candidate = ProcessExecutablePath(window);
  if (candidate.empty() ||
      _wcsicmp(candidate.c_str(), state->executable.c_str()) != 0) {
    return TRUE;
  }

  state->found = window;
  return FALSE;
}

HWND FindPrimaryInstanceWindow() {
  PrimaryWindowSearch state;
  state.executable = ExecutablePath();
  if (state.executable.empty()) {
    return nullptr;
  }

  EnumWindows(FindPrimaryWindow, reinterpret_cast<LPARAM>(&state));
  return state.found;
}

BOOL CALLBACK FindVisibleWindow(HWND window, LPARAM raw_state) {
  if (IsWindowVisible(window) == FALSE) {
    return TRUE;
  }

  auto* state = reinterpret_cast<VisibleWindowSearch*>(raw_state);
  const std::wstring candidate = ProcessExecutablePath(window);
  if (candidate.empty() ||
      _wcsicmp(candidate.c_str(), state->executable.c_str()) != 0) {
    return TRUE;
  }

  state->found = window;
  return FALSE;
}

HWND FindVisibleApplicationWindow() {
  VisibleWindowSearch state;
  state.executable = ExecutablePath();
  if (state.executable.empty()) {
    return nullptr;
  }

  // EnumWindows follows desktop Z order, so the first visible app window is
  // the one a normal second launch should raise.
  EnumWindows(FindVisibleWindow, reinterpret_cast<LPARAM>(&state));
  return state.found;
}

void PresentVisibleApplicationWindow() {
  const HWND window = FindVisibleApplicationWindow();
  if (window == nullptr) {
    return;
  }

  WINDOWPLACEMENT placement = {sizeof(WINDOWPLACEMENT)};
  if (GetWindowPlacement(window, &placement) != FALSE &&
      placement.showCmd == SW_SHOWMINIMIZED) {
    ShowWindow(window, SW_RESTORE);
  } else {
    ShowWindow(window, SW_SHOW);
  }
  SetWindowPos(window, HWND_TOP, 0, 0, 0, 0,
               SWP_SHOWWINDOW | SWP_NOSIZE | SWP_NOMOVE);
  SetForegroundWindow(window);
}

// Drive-qualified "C:\..." and UNC "\\..." paths forward verbatim;
// anything else resolves against this process's working directory.
bool IsAbsolutePath(const std::wstring& path) {
  if (path.size() >= 3 && path[1] == L':' &&
      (path[2] == L'\\' || path[2] == L'/')) {
    return true;
  }
  return path.size() >= 2 && path[0] == L'\\' && path[1] == L'\\';
}

std::wstring CurrentDirectory() {
  const DWORD capacity = GetCurrentDirectoryW(0, nullptr);
  if (capacity == 0) {
    return std::wstring();
  }
  std::wstring cwd(capacity, L'\0');
  const DWORD length = GetCurrentDirectoryW(capacity, cwd.data());
  cwd.resize(length);
  return cwd;
}

// One forwarded argument: relative paths resolve against this launch's
// working directory. A dash-led name is absolutized only when it exists
// there; otherwise it goes verbatim so Dart's _documentArguments keeps
// reading it as an option ("--" included), the Linux runner's rule.
std::wstring ForwardedArgument(const std::wstring& argument,
                               const std::wstring& cwd) {
  if (argument.empty() || cwd.empty() || IsAbsolutePath(argument)) {
    return argument;
  }
  std::wstring joined = cwd;
  if (joined.back() != L'\\') {
    joined += L'\\';
  }
  joined += argument;
  if (argument[0] == L'-' &&
      GetFileAttributesW(joined.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return argument;
  }
  // Canonicalize "." and ".." components so Dart sees the file's path.
  const DWORD capacity = GetFullPathNameW(joined.c_str(), 0, nullptr,
                                          nullptr);
  if (capacity == 0) {
    return joined;
  }
  std::wstring full(capacity, L'\0');
  const DWORD length =
      GetFullPathNameW(joined.c_str(), capacity, full.data(), nullptr);
  if (length == 0 || length >= capacity) {
    return joined;
  }
  full.resize(length);
  return full;
}

// This launch's document arguments, built once: a dash-led name that is
// not a file stays an option for the Dart side to drop.
std::vector<std::wstring> ForwardedArguments() {
  std::vector<std::wstring> forwarded;
  int argument_count = 0;
  wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &argument_count);
  if (arguments == nullptr) {
    return forwarded;
  }
  const std::wstring cwd = CurrentDirectory();
  for (int i = 1; i < argument_count; i++) {
    forwarded.push_back(ForwardedArgument(arguments[i], cwd));
  }
  LocalFree(arguments);
  return forwarded;
}

// Windows marshals this NUL-separated UTF-16 WM_COPYDATA payload. Require
// the receiver's acknowledgement, and bound the wait if its UI is hung.
bool SendForwardedArguments(HWND primary_window,
                            const std::vector<std::wstring>& arguments) {
  std::wstring payload;
  for (const std::wstring& argument : arguments) {
    payload += argument;
    payload += L'\0';
  }
  // The primary raises the window that takes the documents. Windows lets
  // a background process do that only when the foreground process, this
  // launch, allows it.
  DWORD primary_process = 0;
  GetWindowThreadProcessId(primary_window, &primary_process);
  if (primary_process != 0) {
    AllowSetForegroundWindow(primary_process);
  }

  COPYDATASTRUCT data = {};
  data.dwData = kOpenDocumentsCopyDataId;
  data.cbData = static_cast<DWORD>(payload.size() * sizeof(wchar_t));
  data.lpData = payload.data();
  DWORD_PTR accepted = FALSE;
  const LRESULT delivered = SendMessageTimeoutW(
      primary_window, WM_COPYDATA, reinterpret_cast<WPARAM>(nullptr),
      reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG | SMTO_BLOCK,
      kDocumentDeliveryTimeoutMs, &accepted);
  return delivered != 0 && accepted == TRUE;
}

}  // namespace

InstanceDisposition ClaimOrForwardInstance() {
  SetLastError(ERROR_SUCCESS);
  HANDLE instance_mutex = CreateMutexW(nullptr, TRUE, kInstanceMutexName);
  if (instance_mutex == nullptr) {
    return InstanceDisposition::kFailed;
  }
  if (GetLastError() != ERROR_ALREADY_EXISTS) {
    g_primary_instance_mutex = instance_mutex;
    return InstanceDisposition::kRunPrimary;
  }

  const std::vector<std::wstring> arguments = ForwardedArguments();
  const ULONGLONG deadline =
      GetTickCount64() + kPrimaryWindowStartupTimeoutMs;
  while (GetTickCount64() < deadline) {
    const HWND primary_window = FindPrimaryInstanceWindow();
    if (primary_window != nullptr) {
      bool forwarded = true;
      if (arguments.empty()) {
        PresentVisibleApplicationWindow();
      } else {
        forwarded = SendForwardedArguments(primary_window, arguments);
      }
      if (IsWindow(primary_window) != FALSE) {
        CloseHandle(instance_mutex);
        return forwarded ? InstanceDisposition::kForwarded
                         : InstanceDisposition::kFailed;
      }
    }

    const ULONGLONG now = GetTickCount64();
    if (now >= deadline) {
      break;
    }
    const ULONGLONG remaining = deadline - now;
    const DWORD wait = remaining < kPrimaryWindowPollIntervalMs
                           ? static_cast<DWORD>(remaining)
                           : kPrimaryWindowPollIntervalMs;
    const DWORD result = WaitForSingleObject(instance_mutex, wait);
    if (result == WAIT_OBJECT_0 || result == WAIT_ABANDONED) {
      g_primary_instance_mutex = instance_mutex;
      return InstanceDisposition::kRunPrimary;
    }
    if (result != WAIT_TIMEOUT) {
      CloseHandle(instance_mutex);
      return InstanceDisposition::kFailed;
    }
  }

  CloseHandle(instance_mutex);
  return InstanceDisposition::kFailed;
}

bool MarkPrimaryWindow(HWND window) {
  const auto marker = reinterpret_cast<HANDLE>(static_cast<INT_PTR>(1));
  return SetPropW(window, kPrimaryWindowProperty, marker) != FALSE;
}
