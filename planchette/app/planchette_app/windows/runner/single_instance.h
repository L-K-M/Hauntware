#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

enum class InstanceDisposition {
  kRunPrimary,
  kForwarded,
  kFailed,
};

// The WM_COPYDATA dwData tag a second launch's document forward carries
// ("PLDO", Planchette documents); OpenDocumentsHost decodes it.
constexpr ULONG_PTR kOpenDocumentsCopyDataId = 0x504C444F;

// Claims the process-wide primary role or forwards this launch's document
// arguments to it. A forward with no arguments raises the running window.
InstanceDisposition ClaimOrForwardInstance();

// Makes the primary window discoverable once the first frame is presented.
bool MarkPrimaryWindow(HWND window);

#endif  // RUNNER_SINGLE_INSTANCE_H_
