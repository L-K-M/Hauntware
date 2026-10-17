# Changelog

## Unreleased

- Initial scaffold: the `klabautermann_host`, `klabautermann_docker` and
  `klabautermann_core` packages, the five-platform app shell (desktop
  three-pane layout, phone master-detail stack, settings route), light
  and dark themes, and suite registration.
- Desktop import from `~/.ssh/config` (FL-02): the hosts appear in the
  fleet rail and are kept across restarts in this device's
  `ssh_config_imports.json`; each import replaces the previous one. A
  damaged file is kept aside as `ssh_config_imports.json.corrupt-<time>`
  and you are told at startup; an import that cannot be saved still shows
  until you quit, and you are told it will not be kept.
- The `~/.ssh/config` import reads each host as ssh does, for the
  connections to come: settings from `Host *`, wildcard and repeated
  blocks and lines before the first `Host` apply, the first value wins,
  `Match` blocks count where Klabautermann can evaluate them, and `%h`
  in `HostName` is the host's name. It keeps each host's `IdentityFile`
  and `ProxyJump`, and the settings of jump hosts the file names only in
  a `ProxyJump`. Of several `IdentityFile` lines it keeps only the first
  ssh would offer, so a key that `Host *` sets at the top of the file
  comes before a host's own, and a server that accepts only the host's
  own key will refuse Klabautermann. A host Klabautermann cannot connect
  to as ssh would is skipped and counted in the import message: one
  whose name ssh refuses as a host name (a leading `-`, whitespace, a
  control character or a character the shell reads) or reads as
  something else (a name holding `@`, which ssh reads as a user and a
  host, or starting with `ssh://`), one that uses a
  `ProxyCommand`, one an `Include` or a `Match` block it cannot
  evaluate could change, one whose port, user, key or jump host would
  change when ssh reads the file a second time for the name it dials (as
  Fedora's and RHEL's `/etc/ssh/ssh_config` make it do), unless that
  reading would route it through itself, one whose `HostName` or
  `IdentityFile` needs something it cannot fill in, one whose
  `HostName`, `User` or `IdentityFile` holds bytes that are not UTF-8,
  or one whose `ProxyJump` ssh would refuse or it cannot follow (a route
  of more than 16 hops included). A file ssh refuses as a whole imports
  no host: one that starts with a byte-order mark, or holds a
  `ProxyJump` or `CanonicalizeHostname` line ssh rejects anywhere.
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
- One copy at a time on macOS, Linux and Windows: opening Klabautermann
  again while it runs only shows that it is already running, with a Quit
  button, so two copies never overwrite each other's settings and
  imported servers.
- On macOS, Linux and Windows, opening a server you imported from
  `~/.ssh/config` connects to it over SSH, through its jump hosts, and
  its tabs show what the server reports. The first time, you confirm
  each machine's host key, and you answer any keyboard-interactive
  questions in the app. Trusted keys are kept across restarts in this
  device's `host_keys.json`. When a server's key changes, the server is
  blocked; to review the new key, leave the server, open it again after
  30 seconds and trust the key only if you expected the change. When
  Klabautermann has no login name for a server, or the server comes from
  an import an older version saved, the server's view tells you why it
  cannot connect. Klabautermann signs in with a host's first
  `IdentityFile` only, or through ssh-agent when the host names none; a
  key protected by a passphrase cannot be used yet, and the Flatpak
  build cannot read key files, so there only hosts that name no
  `IdentityFile` connect. A `df` that hangs on a BusyBox system, such as
  Alpine or many NAS devices, now counts as a timeout, so the System tab
  keeps the last complete disk reading instead of showing an error.
- Sign in to your Séance sync account from the sync chip at the foot of
  the fleet rail, or the sync button on phones, with the server address,
  account name, password and encryption passphrase you use in Séance.
  Before anything is sent you confirm that every device on the account
  runs Séance 0.9.0 or later. The account's servers then lead the fleet,
  ahead of your imports, and stay after a restart; select the control
  again to fetch changes. Klabautermann only reads the account and
  publishes nothing. The sign-in token and the account key are kept in
  the system keychain. Sync is off when Klabautermann cannot check
  whether another copy of it is running.
- Klabautermann connects to a synced server only once you confirm its
  address on this device, so an address changed on another device cannot
  receive your sign-in unnoticed. A notice over the server list counts
  the servers waiting; Review lists each with its host, port, user and
  jump hosts, with a search, a toggle per server and Confirm all shown.
  Confirmed servers open and connect like imported ones. When a sync
  changes a confirmed server's address, user or jump hosts, or a jump
  host's, Klabautermann disconnects it, forgets what it cached about it
  and asks you again. Servers you imported from `~/.ssh/config` need no
  confirmation on the device that imported them.
