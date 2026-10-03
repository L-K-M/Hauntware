# Sync trash purge captures

Light-theme native Linux runs captured with Flutter 3.47.2 on 2026-10-03.
`before-*` is baseline `8ac232288a96`; `after-*` is this task rebased onto
that commit. All captures use the production GTK runner and Poltergeist theme
under Weston 16 on a 1280×900 Mesa software framebuffer. Purge surfaces use
an 1180×760 window; the menu pair uses the runner's default window.

| Surface | Before | After |
|---|---|---|
| Server menu sync block | [`before-server-menu-light.png`](before-server-menu-light.png) | [`after-server-menu-light.png`](after-server-menu-light.png) |
| Aged-trash notice | — | [`after-aged-trash-notice-light.png`](after-aged-trash-notice-light.png) |
| Purge scope and restore-forfeit confirmation | — | [`after-trash-purge-confirmation-light.png`](after-trash-purge-confirmation-light.png) |
| Purge progress and cancellation | — | [`after-trash-purge-progress-light.png`](after-trash-purge-progress-light.png) |

The menu pair used a temporary entrypoint to open the production
`AppMainMenuButton` with a deterministic command-registry fixture. The purge
captures used another temporary entrypoint to stage journaled local trash and
render the production `SyncPlanView`, confirmation dialog, controller,
inventory, and purge path. Only the scan and diff result was deterministic.
For the progress capture, a filesystem wrapper paused deletion after purge
began so the Cancel action remained visible. Both entrypoints were removed.

```bash
# Menu pair
flutter run -d linux --debug --no-pub \
  -t /absolute/path/to/menu_capture.dart \
  --dart-define=SHOW_PURGE=<false|true>

# Purge surfaces
flutter run -d linux --debug --no-pub \
  -t /absolute/path/to/sync_trash_capture.dart \
  --dart-define=CAPTURE_STATE=<notice|dialog|progress>
weston-screenshooter
```

These images cover native light-theme layout, local trash discovery, the
scope and restore-forfeit warning, and an in-flight purge. They do not cover
remote SFTP, completion or failure results, or accessibility behavior.
Automated command, controller, and widget tests cover the safety rules and
state transitions.
