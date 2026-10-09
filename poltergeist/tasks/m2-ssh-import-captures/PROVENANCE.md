# M2 ssh_config import composition — widget captures

Rootless container: no native screen capture. These are Flutter
widget-render captures from `flutter test` (`RepaintBoundary.toImage`,
1180x760 logical px, DPR 1.0, light theme). Text renders with the test
environment's placeholder font (glyph boxes), so these document layout
and presence, not typography.

- `before.png` — `PoltergeistApp()` with no import wiring: the toolbar
  renders no command.
- `after-toolbar.png` — `PoltergeistApp(sshConfigImport: …)`: the
  `favorite.importSshConfig` command renders in the toolbar.
- `after-dialog.png` — the preview dialog opened over the shell: title,
  one row per host, per-row import checkboxes, and the count-labeled
  import action.

Captured 2026-09-10 against the branch's head.
