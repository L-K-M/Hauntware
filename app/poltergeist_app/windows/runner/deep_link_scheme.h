#ifndef RUNNER_DEEP_LINK_SCHEME_H_
#define RUNNER_DEEP_LINK_SCHEME_H_

#include <windows.h>

enum class DeepLinkInstanceDisposition {
  kRunPrimary,
  kForwarded,
  kFailed,
};

enum class DeepLinkLaunchIntent {
  kActivate,
  kOpenUri,
};

// Registers poltergeist:// for this executable under the current user.
bool RegisterDeepLinkScheme();

// Claims the process-wide primary role or forwards this launch to it.
DeepLinkLaunchIntent CurrentLaunchIntent();

DeepLinkInstanceDisposition ClaimOrForwardDeepLinkInstance(
    DeepLinkLaunchIntent intent);

// Makes the primary window discoverable after Dart has subscribed to links.
bool MarkPrimaryDeepLinkWindow(HWND window);

#endif  // RUNNER_DEEP_LINK_SCHEME_H_
