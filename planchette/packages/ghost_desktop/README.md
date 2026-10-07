# ghost_desktop

The shared desktop main-window lifecycle used by Planchette, Poltergeist, and
Séance: restore the remembered frame before the window appears, track geometry
changes while it runs, and coordinate the close path — with each host's file
format, close guards, and native hooks kept in its own thin adapter.

## What it owns

- `GhostWindowSnapshot` — the last *normal* frame plus `isMaximized` /
  `isFullScreen` flags, with the tolerant JSON codec Séance's
  `window_state.json` established.
- `resolveRestorableFrame` / `clampFrameToWorkArea` — missing-monitor
  geometry (`MissingMonitorPolicy.rejectAndKeep` keeps a dead-monitor frame
  for reconnect; `clampToNearest` relocates onto the closest live display).
- `GhostWindowLifecycle` — serialized operations, restore-before-show with
  per-OS maximize/full-screen sequencing, debounced geometry capture that
  skips minimized windows and never lets a maximized frame overwrite the
  remembered normal one, close veto/retry, and a bounded close flush.
- `WindowManagerAdapter` / `ScreenRetrieverAdapter` — the default native
  backs over `window_manager` and `screen_retriever`; tests inject fakes.
- `semanticsActionView` — the view whose semantics tree holds a node, so a
  host binding with extra windows can return a VoiceOver action that macOS
  addressed to the main view to the window it belongs to.

## What hosts keep

- **Persistence format and location.** `GhostWindowPersistence` is the seam:
  Séance and Planchette write the shared `window_state.json` schema;
  Poltergeist's adapter writes only `snapshot.bounds` into its flat
  `window.*` settings keys, ignoring the flags entirely.
- **Coordinate space.** `GhostCoordinateSpace.physicalOnWindows` stores
  physical pixels on Windows (window_manager converts with the *current*
  monitor's ratio while screen_retriever scales per display, so no single
  logical space survives a relaunch); `logical` elsewhere.
- **Close policy.** `GhostClosePolicy.intercept` installs `setPreventClose`
  and routes the close through confirm/flush hooks (Poltergeist, and
  Planchette's `confirmQuit`); `GhostClosePolicy.observe` leaves native close
  alone and just saves the final frame (Séance).
- **Hooks.** macOS titlebar setup, "close this window instead" for multi-
  window shells, readiness futures, and error reporting all arrive as
  constructor callbacks — the lifecycle stays ignorant of product surface.

## Platform notes

- macOS runners must hide the window at launch (`hiddenWindowAtLaunch()` via
  the `order` override) so restore lands before first paint; `show()` always
  re-shows, even when restoring fails, so the contract can never leave the
  app invisible.
- Windows runners show the window on first frame with `SW_SHOWNORMAL`, which
  cancels an early maximize — flags are re-applied on the `show` event.
- Wayland ignores pre-map positioning; the restored frame still applies on
  X11 and lands as soon as the compositor allows.

## Status

- Used by `app/seance_app` (`WindowStateService` delegates while keeping the
  pre-`runApp` entry and file location) and `app/poltergeist_app`
  (`DesktopWindowLifecycle` is a facade over `GhostWindowLifecycle`).
- `app/planchette_app`: `WindowStateStore` implements
  `GhostWindowPersistence` (`window_state.json` beside `settings.json`) and
  `DesktopWindow` drives `GhostWindowLifecycle` for the primary window —
  restore runs before `runWidget` so the frame lands before the runners'
  first-frame show; macOS hides the window at launch. Planchette's document
  windows stay on the runner's window host with their cascade placement and
  never touch this lifecycle.
