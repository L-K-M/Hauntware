# S4 UI captures

Light-theme, real-font widget renders captured with Flutter 3.47.2 on
2026-09-29. `before-*` is `origin/main` at `75bc19a5`; `after-*` is this
PR's worktree. Each pair uses the same 1000×900 Linux-target harness.

| Surface | Before | After |
|---|---|---|
| New server authentication | `before-server-editor-light.png` | `after-server-editor-light.png` |
| Keyboard-interactive challenge | `before-keyboard-interactive-light.png` | `after-keyboard-interactive-light.png` |
| Server mark picker | `before-mark-picker-light.png` | `after-mark-picker-light.png` |

The capture command in each worktree was:

```bash
FLUTTER_ROOT=<flutter-sdk> \
POLTERGEIST_CAPTURE_DIR=<pr-worktree>/tasks/s4-fast-follow/screenshots \
flutter test test/_tmp_s4_capture_test.dart
```

The temporary capture harness was removed after both three-test runs passed.
Native `flutter run` capture was unavailable: this container has no display,
`Xvfb`, `xvfb-run`, CMake, Ninja, or GTK `pkg-config` toolchain. These are
widget renders, not native-window captures.
