# Local ZIP archive evidence

## Scope

- Create a ZIP from selected local roots.
- Extract one local ZIP beside its source.
- Surface progress, pause, cancel, failure, and retry in Activity.
- Stage output and commit with Keep Both naming.
- Reject unsafe or unsupported archive entries before extraction.

Remote archives and archive browsing remain out of scope.

## Visual evidence

| State | Capture |
| --- | --- |
| Before | [File menu before](screenshots/before/menu-file.png) |
| After | [File menu with archive commands](screenshots/after/menu-file.png) |

Both captures come from debug APKs running in the real Flutter app on the same
Android 28 x86_64 emulator at 1080 x 1920. The before build is revision
`0f70c6b3`; the after build is implementation revision `621604b7`. The AVD
(`poltergeist_capture`), workspace, File-menu scroll, and viewport are
unchanged. These images prove adaptive menu placement, not archive I/O or
native desktop-menu behavior; tests cover those contracts.

## Verification

- Core analysis passed; 1,835 tests passed with 27 environment skips.
- Archive/native and local-filesystem suites passed 68 tests each.
- Flutter analysis passed; all 3,051 app tests passed.
- Import guard passed 95 tests; benchmark coverage passed 140 tests.
- The Android debug APK built, installed, launched, and produced the after
  capture on API 28 x86_64.

Linux native behavior is covered by the core run. Android archive I/O and the
macOS, iOS, and Windows native paths were not runtime-tested here.
