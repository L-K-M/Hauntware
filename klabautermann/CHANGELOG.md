# Changelog

## Unreleased

- Initial scaffold: the `klabautermann_host`, `klabautermann_docker` and
  `klabautermann_core` packages, the five-platform app shell (desktop
  three-pane layout, phone master-detail stack, settings route), light
  and dark themes, and suite registration. Nothing connects to a host
  yet.
- Desktop import from `~/.ssh/config` (FL-02): the hosts appear in the
  fleet rail and are kept across restarts in this device's
  `ssh_config_imports.json`; each import replaces the previous one. A
  damaged file is kept aside as `ssh_config_imports.json.corrupt-<time>`
  and you are told at startup; an import that cannot be saved still shows
  until you quit, and you are told it will not be kept.
- The theme you pick in Settings is kept across restarts, in this
  device's `settings.json`, which also records the device's sync id.
  A damaged settings file is kept aside as `settings.json.corrupt-<time>`
  and you are told at startup; a file Klabautermann cannot read, or one
  from a newer version, is left as it is.
