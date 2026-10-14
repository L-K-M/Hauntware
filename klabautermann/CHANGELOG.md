# Changelog

## Unreleased

- Initial scaffold: the `klabautermann_host`, `klabautermann_docker` and
  `klabautermann_core` packages, the five-platform app shell (desktop
  three-pane layout, phone master-detail stack, settings route), light
  and dark themes, and suite registration. Nothing connects to a host
  yet.
- Desktop import from `~/.ssh/config` (FL-02): the hosts appear in the
  fleet rail for the current session; they are not saved yet.
- Desktop settings window: on macOS, Linux and Windows, Settings opens in
  a window of its own, and a theme change there applies to the app.
  Phones keep the settings page.
- The theme you pick in Settings is kept across restarts, in this
  device's `settings.json`, which also records the device's sync id.
  A damaged settings file is kept aside as `settings.json.corrupt-<time>`
  and you are told at startup; a file Klabautermann cannot read, or one
  from a newer version, is left as it is.
- On macOS the window's titlebar is part of the app: the traffic lights
  sit in a band above the fleet rail, and full screen gives the band back
  to the content.
- The desktop window opens at the size you closed it at and, where the
  window system lets apps place windows (not Wayland), in the same place;
  maximized or full screen if it was. A window whose display is gone
  opens fully on one that is still connected.
- Desktop menus: Settings… (⌘, on macOS, Ctrl+, on Linux and Windows),
  Import from ~/.ssh/config, and on Linux and Windows a File menu with
  Quit. On macOS the menu bar also has About, Enter Full Screen and the
  window commands, but no longer an Edit or Help menu until commands for
  them land; ⌘C, ⌘V, ⌘X, ⌘A and ⌘Z still work in text fields.
