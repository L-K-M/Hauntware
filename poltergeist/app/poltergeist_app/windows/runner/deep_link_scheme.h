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

// Determines whether this launch carries a poltergeist:// URI argument.
DeepLinkLaunchIntent CurrentLaunchIntent();

// Claims the process-wide primary role or forwards this launch to it.
DeepLinkInstanceDisposition ClaimOrForwardDeepLinkInstance(
    DeepLinkLaunchIntent intent);

// Makes the primary window discoverable once the first frame is presented.
bool MarkPrimaryDeepLinkWindow(HWND window);

#endif  // RUNNER_DEEP_LINK_SCHEME_H_
