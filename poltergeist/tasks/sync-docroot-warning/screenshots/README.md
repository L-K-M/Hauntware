# Sync document-root warning captures

Light-theme Android captures made with Flutter 3.47.2 on 2026-10-04.
`before-*` is baseline `41eed4e0`; `after-*` contains this task. The real app
ran on an API 28 x86_64 emulator through `flutter run`, using SwiftShader at
1280×900 and 160 dpi.

| Surface | Before | After |
|---|---|---|
| Ready sync plan | [`before-plan-light.png`](before-plan-light.png) | [`after-plan-light.png`](after-plan-light.png) |
| Sync-pair editor | [`before-editor-light.png`](before-editor-light.png) | [`after-focused-editor-light.png`](after-focused-editor-light.png) |

Temporary entrypoints supplied deterministic local roots while rendering the
production `SyncPlanView` and `SyncPairEditor`. They were removed after capture.
The after pair shows the persistent warning and action; the editor shows the
expanded options, proposed safe trash path, and focused field.

TCG emulation was used because this host lacks KVM. The Android system bars
remain visible. Automated tests cover policy detection, editor updates,
command gating, persistence, rescan behavior, and bidirectional path isolation.
