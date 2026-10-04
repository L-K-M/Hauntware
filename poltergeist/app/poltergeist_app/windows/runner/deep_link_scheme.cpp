#include "deep_link_scheme.h"

#include <shellapi.h>
#include <windows.h>

#include <string>
#include <vector>

#include "app_links/app_links_plugin_c_api.h"

namespace {

constexpr wchar_t kProtocolKey[] = L"Software\\Classes\\poltergeist";
constexpr wchar_t kProtocolName[] = L"URL:Poltergeist";
constexpr wchar_t kProtocolMarker[] = L"URL Protocol";
constexpr wchar_t kCommandKey[] = L"shell\\open\\command";
constexpr wchar_t kArgumentPlaceholder[] = L"%1";
constexpr wchar_t kSchemeArgumentPrefix[] = L"poltergeist:";
constexpr size_t kSchemeArgumentPrefixLength =
    sizeof(kSchemeArgumentPrefix) / sizeof(kSchemeArgumentPrefix[0]) - 1;
constexpr wchar_t kInstanceMutexName[] =
    L"Local\\ch.lkmc.poltergeist.deep-link-primary-v1";
constexpr wchar_t kPrimaryWindowProperty[] =
    L"ch.lkmc.poltergeist.deep-link-primary-v1";
constexpr DWORD kInitialPathCapacity = MAX_PATH;
constexpr DWORD kMaximumPathCapacity = 32768;
constexpr DWORD kPrimaryWindowPollIntervalMs = 25;
constexpr ULONGLONG kPrimaryWindowStartupTimeoutMs = 30000;

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

bool SetStringValue(HKEY key, const wchar_t* name,
                    const std::wstring& value) {
  const auto bytes = static_cast<DWORD>(
      (value.size() + 1) * sizeof(std::wstring::value_type));
  return RegSetValueExW(key, name, 0, REG_SZ,
                        reinterpret_cast<const BYTE*>(value.c_str()),
                        bytes) == ERROR_SUCCESS;
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

HWND FindPrimaryDeepLinkWindow() {
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

}  // namespace

bool RegisterDeepLinkScheme() {
  const std::wstring executable = ExecutablePath();
  if (executable.empty()) {
    return false;
  }

  HKEY protocol_key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kProtocolKey, 0, nullptr,
                      REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr,
                      &protocol_key, nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const bool protocol_written =
      SetStringValue(protocol_key, nullptr, kProtocolName) &&
      SetStringValue(protocol_key, kProtocolMarker, L"");

  HKEY command_key = nullptr;
  const bool command_created =
      RegCreateKeyExW(protocol_key, kCommandKey, 0, nullptr,
                      REG_OPTION_NON_VOLATILE, KEY_WRITE, nullptr,
                      &command_key, nullptr) == ERROR_SUCCESS;
  bool command_written = false;
  if (command_created) {
    const std::wstring command =
        L"\"" + executable + L"\" \"" + kArgumentPlaceholder + L"\"";
    command_written = SetStringValue(command_key, nullptr, command);
    RegCloseKey(command_key);
  }
  RegCloseKey(protocol_key);

  return protocol_written && command_written;
}

DeepLinkLaunchIntent CurrentLaunchIntent() {
  int argument_count = 0;
  wchar_t** arguments = CommandLineToArgvW(GetCommandLineW(), &argument_count);
  if (arguments == nullptr) {
    return DeepLinkLaunchIntent::kActivate;
  }

  const bool has_uri =
      argument_count == 2 &&
      _wcsnicmp(arguments[1], kSchemeArgumentPrefix,
                 kSchemeArgumentPrefixLength) == 0;
  LocalFree(arguments);
  return has_uri ? DeepLinkLaunchIntent::kOpenUri
                 : DeepLinkLaunchIntent::kActivate;
}

DeepLinkInstanceDisposition ClaimOrForwardDeepLinkInstance(
    DeepLinkLaunchIntent intent) {
  SetLastError(ERROR_SUCCESS);
  HANDLE instance_mutex = CreateMutexW(nullptr, TRUE, kInstanceMutexName);
  if (instance_mutex == nullptr) {
    return DeepLinkInstanceDisposition::kFailed;
  }
  if (GetLastError() != ERROR_ALREADY_EXISTS) {
    g_primary_instance_mutex = instance_mutex;
    return DeepLinkInstanceDisposition::kRunPrimary;
  }

  const ULONGLONG deadline =
      GetTickCount64() + kPrimaryWindowStartupTimeoutMs;
  while (GetTickCount64() < deadline) {
    const HWND primary_window = FindPrimaryDeepLinkWindow();
    if (primary_window != nullptr) {
      if (intent == DeepLinkLaunchIntent::kOpenUri) {
        SendAppLink(primary_window);
      } else {
        PresentVisibleApplicationWindow();
      }
      if (IsWindow(primary_window) != FALSE) {
        CloseHandle(instance_mutex);
        return DeepLinkInstanceDisposition::kForwarded;
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
      return DeepLinkInstanceDisposition::kRunPrimary;
    }
    if (result != WAIT_TIMEOUT) {
      CloseHandle(instance_mutex);
      return DeepLinkInstanceDisposition::kFailed;
    }
  }

  CloseHandle(instance_mutex);
  return DeepLinkInstanceDisposition::kFailed;
}

bool MarkPrimaryDeepLinkWindow(HWND window) {
  const auto marker = reinterpret_cast<HANDLE>(static_cast<INT_PTR>(1));
  return SetPropW(window, kPrimaryWindowProperty, marker) != FALSE;
}
