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
