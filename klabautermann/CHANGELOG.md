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
- The fleet list shows whether each server answers on its SSH port:
  Online, Offline or Reachability unknown, checked about every 45
  seconds. Only servers you imported or confirmed on this device are
  checked; a server reached through a jump host shows Reachability
  unknown, and phones stop checking while Klabautermann is in the
  background.
- The fleet list on desktops and phones is sectioned as in Séance: your
  synced servers sit under Servers, grouped by their Séance groups in
  sections you can fold, and your imports follow under Imported. Pin a
  synced server to the top from its menu (right-click, Shift+F10, the Menu
  key or a long-press); pins are kept on this device only.
- Until v1 the app calls itself Klabautermann (preview). About
  Klabautermann, in the application menu on macOS and the Help menu on
  Linux and Windows, shows the version and the licence, and Settings >
  General shows the version and opens the same dialog on every device.
- Choose which servers Klabautermann reads continuously while it is
  open: Monitor or Stop monitoring from a server's menu, or the switches
  under Settings > Servers. Monitored servers show CPU, memory and disk
  in their rows without being opened, up to 10 per device. A server can
  be monitored once its address is confirmed on this device and it
  signs in with an SSH agent or a key file; Settings says why one
  cannot. Until you choose, desktops monitor up to 10 eligible servers
  and phones none. Your choice is kept on this device only.
- A server's Docker tab shows its containers, images and compose stacks
  over the same SSH connection, with nothing installed on the server.
  Klabautermann reaches the engine by forwarding its socket over SSH, or
  through the server's docker or podman command, or its socat, when sshd
  forbids forwarding; the server header says which, and says so when the
  server allows too few SSH sessions to keep everything live. Containers
  are listed with state, health, CPU and memory, grouped by compose
  project, with a running-only filter and a search; a container's row
  opens its details and its logs, which you can search. Passwords and
  tokens in environment variables, labels, commands and compose files
  are masked, and you can reveal them for 30 seconds. Images show their
  size, age and whether a container uses them. A stack shows whether its
  files on the server still match what runs, which tool manages it, and
  its compose and `.env` files, read-only. The Overview counts running,
  paused, stopped and unhealthy containers and images, and measures the
  space you could reclaim when you ask. When Klabautermann picks the
  wrong engine socket, choose another one, or type its path, in the
  Docker tab; the choice is kept on this device. The Access tab says
  whether socket forwarding works and which Compose is installed.
- Klabautermann can now act on a server as well as read it, once you
  allow actions on it from the server header's Safety menu. Every server
  starts observe-only, a server or the whole app can be set read-only
  (Settings > Safety), and nothing you have not allowed shows an action.
  Before anything runs you see its exact commands, which of them run as
  root, the risks Klabautermann recognises in them, what the action
  affects and which tool manages the target. You confirm with a tap,
  and type the target's name where an action could cut you off or
  affects a lot: stopping the service your connection depends on,
  removing a container with its volumes, or acting on a stack another
  tool manages. You can
  mark your own protected targets in Settings > Safety; they are kept on
  this device.
- Processes, services and timers: terminate, kill or send any signal to
  a process, start, stop, restart or reload a service, and run a timer's
  service now and follow its journal as it runs. Another user's process
  is signalled only in admin mode, and a process that was replaced
  meanwhile is left alone.
- Admin mode: turn it on from the server header with your sudo password,
  which is kept in memory only while admin mode lasts. It ends after the
  time you choose in Settings > Safety, when the connection drops, when
  the app goes to the background, or when you turn it off. In admin mode
  you can read other users' crontabs (masked) and log or stack files
  only root may read, and reach a Docker socket your account cannot use
  through sudo, which the server header marks as root-equivalent.
- Docker: start, stop, restart, pause, unpause and kill containers,
  remove a stopped one, remove images (an image a container uses
  needs force and typing its name), and start, stop and restart compose
  stacks. Pull and redeploy a stack you deployed with compose: it runs on
  the server as an operation that carries on if you disconnect or close
  the app, and the chip in the server header shows it, follows its output
  and shows its result when you are back. A server that allows only a
  few SSH sessions lends one to your action and takes it back afterwards.
- Every action you run is recorded on this device, without its secrets:
  Activity, in the server header's Safety menu, lists the records and
  copies them.
- Settings > Appearance edits the theme as Séance does: presets, light
  or dark, colours, font and corners, with copy, paste and reset.
- Servers in your sync account can be added, edited, duplicated and
  deleted from the fleet, and the change reaches Séance and Poltergeist
  on your other devices. Test connection tries the form before you save,
  without trusting a host key for good; Browse picks a key file on a
  desktop, and Import from file stores a key in the app's vault, which
  is how a phone gets one. Passwords and keys sync only when you turn
  on "Sync passwords" and the server opts in.
- Each server's read-only switch and protected targets sync with your
  account. A host key you confirm can be shared with your
  other devices once you assert they all run a Séance release that
  checks shared keys; until such a release is out, nothing is shared.
- Containers: open a shell in a running container, or run one command
  and see its output, where actions are allowed.
- Edit files on the server: your own files, stack compose and `.env`
  files and crontabs, and in admin mode files only root may write. You
  review a diff before saving; the file is checked first (a compose
  file, a unit file, a crontab), backed up, and replaced keeping its
  owner, mode and label, and a file changed meanwhile is never
  overwritten. Footprint, in the server header's Safety menu, lists the
  backups and the files the app keeps on the server, checks them when
  you connect, and removes what you no longer want.
- Every action writes one line to the server's system log, naming the
  device you set in Settings > General.
- Jobs: anacron jobs, timers' last runs and cron's run log; run a cron
  line now, pause and resume it, and see lines another tool manages.
- Services: enable, disable, mask, unmask and reset failed units, your
  own user units and timers, a unit's file and resources, and the
  listening sockets.
- Logs: search with a regular expression or on the server, pick a boot,
  browse `/var/log` with rotated archives, highlighted addresses, URLs
  and HTTP codes, and copy, save or share an export, redacted unless you
  say otherwise.
- Stacks: act on one service, choose profiles, find stacks in folders
  you name that never ran, edit their files, and take a stack down
  keeping its volumes.
- Open a server, a stack's folder or a log folder in Séance or
  Poltergeist where they take links; a link opens the server and folder
  only and never runs a command.
- Paste a theme copied in Séance or Poltergeist into Settings >
  Appearance.
- Docker: Volumes and Networks sub-tabs that create and remove them,
  prune with a preview of what goes, image pulls with progress, an
  image's history, update checks against the registries, container
  flags, bulk actions and columns, per-container CPU, memory, network
  and block I/O charts with a note when memory nears its limit, a
  container's processes and label links, a review of risky container
  settings, the daemon's events, and a diagnosis for a container that
  failed: out of memory, its exit code, a restart loop or a failing
  health check. Container logs can be coloured by level, merged by time
  for a stack, and exported redacted.
- Apps: the Docker tab lists the web ports and links of running
  containers and opens them in your browser through a port forward that
  listens only on this device; "Forward a port…" reaches any host and
  port the server reaches.
- Docker access: offer to enable the Podman socket, name a server's
  `docker` program where it is not on the `PATH`, and a warning when a
  Dropbear server's forwarding exposes the engine as root.
- System tab: disk activity, mounts and swap devices, a disk space
  explorer that drills into a mount's folders, interfaces and
  connections, listening ports, the firewall, pending updates, CPU
  breakdown and pressure, out-of-memory kills, temperatures, GPUs, and
  in admin mode drive health, the SSH server's settings, reboot and
  shutdown with a wait for the server to return. Also time and clock
  sync, boots, the processor, users and logins, and the expiry of TLS certificates on endpoints you
  list.
- Jobs: a timer's details show its triggers and each calendar trigger's
  next runs.
- Alerts: rules evaluated on this device while Klabautermann is open,
  with separate raise and clear thresholds and durations, an alert
  center with badges, system notifications you turn on, and an
  on-device history of each server's usage in the Overview.
- Overview: arrange its cards, see the top processes and containers,
  quick actions, usage bands you can set in Settings, and share a status
  card.
- Fleet: a summary of what needs attention, a board with card and grid
  layouts, and a connection tree.
- Desktop: a command palette (⌘K or Ctrl+K) for commands, servers, tabs,
  containers, units and stacks; keyboard navigation of every list, with
  `/` to filter, single-key actions and a keyboard map on `?`; a bottom
  dock for shells; and a split of the fleet and the server on tablets.
- Settings: an app lock that asks for the device's own unlock, a polling
  budget and per-server caps, log text size and wrapping, server times
  in the server's zone, and your sync account's size.
- Copy the commands an action runs, run Séance's synced snippets on a
  server, and export a redacted diagnostic bundle.
