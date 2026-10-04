# S4 UI captures

Light-theme native Linux runs captured with Flutter 3.47.2 on 2026-09-30.
`before-*` is commit `75bc19a5`; `after-*` is this PR. Both builds ran in the
production GTK runner at 1280×900 under Weston with Mesa llvmpipe.

| Surface | Before | After |
|---|---|---|
| New server authentication | [`before-server-editor-light.png`](before-server-editor-light.png) | [`after-server-editor-light.png`](after-server-editor-light.png) |
| Keyboard-interactive challenge | [`before-keyboard-interactive-light.png`](before-keyboard-interactive-light.png) | [`after-keyboard-interactive-light.png`](after-keyboard-interactive-light.png) |
| Server mark picker | [`before-mark-picker-light.png`](before-mark-picker-light.png) | [`after-mark-picker-light.png`](after-mark-picker-light.png) |
| ssh_config import preview | [`before-ssh-config-import-light.png`](before-ssh-config-import-light.png) | [`after-ssh-config-import-light.png`](after-ssh-config-import-light.png) |
| Blocked host-key menu | [`before-blocked-host-key-menu-light.png`](before-blocked-host-key-menu-light.png) | [`after-blocked-host-key-menu-light.png`](after-blocked-host-key-menu-light.png) |

Each worktree used the same temporary entrypoint and production widgets:

```bash
flutter run -d linux --debug --no-pub \
  -t lib/s4_capture_harness.dart \
  --dart-define=S4_SURFACE=<surface>
weston-screenshooter
```

The temporary entrypoints were removed after all ten native captures were
inspected.
