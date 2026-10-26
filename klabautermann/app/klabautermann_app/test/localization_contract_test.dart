import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_contract/l10n_contract.dart';

// Klabautermann's localization contract (03 §10.10, D35, A11Y-05): the
// suite's shared scanner (`tool/l10n_contract`, 03 §3.5 F1b) rejects every
// authored literal in lib/ outside the ARB catalogue and this reviewed
// allowlist, as in Poltergeist's localization_contract_test.dart. The
// allowlist holds technical literals only. Two
// checks the scanner does not make stay from the app's interim test: every
// ARB key is referenced from lib/, and no literal fills a slot that
// _userFacingSlotLiteral lists, so a reviewed literal reused in such a slot
// of its own file fails too. Other parameters a surface shows, such as
// Tooltip's message or InputDecoration's labelText, are not checked, and
// neither is a literal routed through a variable before a listed slot
// (`final words = '...'; Text(words)`): the slot check reads the slot's
// own argument, so the allowlist review is what keeps such a literal out.

const _generatedLocalizationPrefix = 'lib/l10n/app_localizations';
const _generatedLocalizationPaths = {
  '$_generatedLocalizationPrefix.dart',
  '${_generatedLocalizationPrefix}_en.dart',
};

// gen-l10n is the app's only code generator; one added later brings its
// file suffix here.
const _generatedDartSuffixes = <String>{};

// Literals are reviewed per file so an allowlist cannot hide UI copy. Every
// entry is technical.
const _allowedTechnicalLiterals = <String, Set<String>>{
  // The separator between group names and root reasons, the UID as the
  // host prints it, an empty root cell, and the groups' sort key.
  'lib/ui/accounts.dart': {"', '", r"'${account.uid}'", "''", "','"},
  // An account read's request id, matched in the engine's answer.
  'lib/controllers/account_reads.dart': {r"'accounts-${_count++}'"},
  'lib/app.dart': {
    // The settings route's Navigator name.
    "'/settings'",
    // Error-report context; a window that fails to open falls back to the
    // settings route, which is what the user sees.
    "'while opening the settings window'",
  },
  // The preview label's marker, which tests tie the ARB title and the
  // Linux package description to; never displayed by itself.
  'lib/app_identity.dart': {"'(preview)'"},
  // A diagnostic; the About dialog shows its own ARB text
  // (aboutVersionUnknown) when the version cannot be read.
  'lib/services/app_version.dart': {
    r"'The app version could not be read: $error'",
  },
  'lib/main.dart': {
    // A file path inside the app's support directory.
    r"'${supportDirectory.path}${Platform.pathSeparator}$name'",
    // Startup debugPrint diagnostics; StartupIssueNotice tells the user
    // the same issues in ARB text.
    r"'settings.json: ${issue.kind.name} ${issue.error ?? ''}'",
    "''",
    r"'ssh_config_imports.json: ${importStoreIssue.kind.name} '",
    r"'${importStoreIssue.detail ?? ''}'",
    // Instance-lock debugPrint diagnostics; AlreadyRunningApp and
    // StartupIssueNotice tell the user in ARB text.
    "'Klabautermann is already running; this instance quits.'",
    r"'$instanceLockFileName: ${issue.error}'",
    // Sync state file debugPrint diagnostics; StartupIssueNotice tells
    // the user in ARB text.
    r"'${issue.fileName}: ${issue.kind.name} ${issue.detail ?? ''}'",
  },
  // The not-saved diagnostic; the Appearance tab prints it and shows its
  // own ARB text (themeNotSaved).
  'lib/controllers/appearance_controller.dart': {
    r"'The theme was not saved: $error'",
  },
  // The not-saved diagnostic; the General tab prints it and shows its own
  // ARB text (settingsAnnounceNotSaved).
  'lib/controllers/announcement_controller.dart': {
    r"'The announcement setting was not saved: $error'",
  },
  // The host syslog line's device name, written into host journals in
  // one form (M5 plan Q6).
  'lib/controllers/device_name.dart': {
    r"'Klabautermann on $name'",
    // The not-saved diagnostic; General shows its own ARB toast.
    r"'The device name was not saved: $error'",
    "'Android'",
    "'Fuchsia'",
    "'iOS'",
    "'Linux'",
    "'macOS'",
    "'Windows'",
  },
  // A job history read's request id, matched in the engine's answer.
  'lib/controllers/job_history_reads.dart': {r"'history-${_count++}'"},
  // A package check's request id, matched in the engine's answer.
  'lib/controllers/package_reads.dart': {r"'packages-${_count++}'"},
  // An empty security cell, a missing detail, and the separator between
  // package names the server reported.
  'lib/ui/updates.dart': {"''", "', '"},
  // A failed check's missing detail.
  'lib/ui/fleet_updates.dart': {"''"},
  // A history rollup read's request id, matched in the engine's answer.
  'lib/controllers/history_reads.dart': {r"'rollup-${_count++}'"},
  // The not-saved diagnostic; the Safety tab and the header's Safety menu
  // print it and show their own ARB text (settingsSafetyNotSaved).
  'lib/controllers/safety_controller.dart': {
    r"'The safety settings were not saved: $error'",
    // A migration the engine refused, printed; it is tried again.
    r"'Safety preferences of $serverId stay on this device: $error'",
  },
  // A refused post's diagnostic, printed.
  'lib/controllers/alert_notifications.dart': {
    "'while posting an alert notification'",
  },
  // The plugin's start-up diagnostic, the Android icon resource, the
  // Windows toast identity (the product name, the application id of
  // 04 §12.3 and a fixed GUID) and the Android channel's id.
  'lib/services/system_notifications.dart': {
    "'while starting system notifications'",
    "'@mipmap/ic_launcher'",
    "'Klabautermann'",
    "'ch.lkmc.klabautermann'",
    "'5b0e8d0c-7f43-4c55-9a1e-2f6b7a3d9c41'",
    "'alerts'",
  },
  // A rule write's request id, never shown, and its refusal's diagnostic.
  'lib/controllers/alert_rules_controller.dart': {
    r"'rule-${_count++}'",
    r"'AlertRuleNotSavedException: $failure, $detail'",
  },
  // An unexpected write error, printed in the refusal's other case; a
  // missing target's empty name; and a typed number's comma and point.
  'lib/ui/alert_rules.dart': {r"'$error'", "''", "','", "'.'"},
  // A pref write's request id, never shown, and its refusal's diagnostic.
  'lib/controllers/server_prefs_controller.dart': {
    r"'prefs-${_count++}'",
    r"'ServerPrefsNotSavedException: $failure, $detail'",
  },
  // A server edit's request id, matched in the engine's answer, and the
  // rejected request's class name, which RequestRejected carries.
  'lib/controllers/server_editor_controller.dart': {
    r"'server-edit-${_count++}'",
    r"'$TestServerConnection'",
  },
  // The not-saved diagnostic; the Sync tab prints it and shows its own
  // ARB text (settingsSyncSecretsNotSaved).
  'lib/controllers/sync_secrets_controller.dart': {
    r"'The sync passwords setting was not saved: $error'",
  },
  // The host key assertion's diagnostics, which Settings words in ARB, and
  // the request name a refusal carries.
  'lib/controllers/pin_publication_controller.dart': {
    "'No release is offered for pin publication'",
    "'The engine stopped'",
    "'The pin publication assertion was not saved'",
    "'SetPinPublication'",
  },
  // A failed host key assertion's diagnostic; the toast is ARB's.
  'lib/ui/sync_sign_in.dart': {r"'$error'"},
  // A caller error's diagnostic: the preview is modal, so no screen ever
  // shows it.
  // The display path that picks the unit file view's INI highlighting,
  // never shown.
  'lib/ui/unit_details.dart': {"'unit.service'"},
  // The subscription id the Services tab reads the user manager under,
  // never shown.
  'lib/ui/services_panel.dart': {r"'${ServerPanel.services.name}.user'"},
  'lib/controllers/operations_controller.dart': {
    "'a preview is already pending'",
    // An edit read's request id, never shown.
    r"'edit-${_nextEditRead++}'",
    // The rejected request's class name, which RequestRejected carries,
    // and the server id its reason ends with; never shown.
    r"'$FootprintQuery'",
    r"' $id'",
  },
  'lib/ui/footprint_page.dart': {
    // The index's source prefix for a crontab's backups (03 §8.11), which
    // the page strips before it shows the account.
    "'crontab:'",
    // A backup's path in its directory, which only the read takes.
    r"'$directory/${entry.name}'",
  },
  'lib/ui/edit/remote_editor.dart': {
    // A crontab's highlighting and validation key, never shown.
    "'crontab'",
    // The path separator a file's title takes its name after.
    "'/'",
    // A problem without a subject or detail fills its slot with nothing.
    "''",
    // The unified diff's line break and its line markers, which pick a
    // row's tint; the rows show the diff's own text.
    r"'\n'",
    "'+++'",
    "'---'",
    "'+'",
    "'-'",
    "'@@'",
  },
  // The Activity table's key prefix, never shown, and the copied log's
  // line break between JSON records.
  'lib/ui/actions/activity_page.dart': {"'activity'", r"'\n'"},
  // The ARB select key of every unused image's prune (DKE-05).
  'lib/ui/actions/docker_actions.dart': {"'imagesAll'"},
  'lib/controllers/fleet_controller.dart': {
    // The row subtitle's address: host or user@host, with :port when the
    // port is not 22 and an IPv6 host then bracketed before it. Machine
    // data, not copy.
    "''",
    r"'${entry.user}@'",
    r"'$login${entry.host}'",
    "':'",
    r"'[${entry.host}]'",
    r"'$login$host:${entry.port}'",
    // The endpoint key a device preference is kept with (SYN-08): login,
    // host and port, then the jump hops, space-separated. Never shown.
    r"'${entry.user ?? ''}@${entry.host}:${entry.port}'",
    "' '",
    // A programmer error and import diagnostics: surfaces show ARB text
    // for a rejected import (sshConfigImportFailed), never its reason.
    "'this platform has no ssh_config to import'",
    "'the engine is not running'",
    "'the engine stopped'",
    "'the fleet controller was disposed'",
    // The rejected requests' class names, which RequestRejected carries.
    r"'$ImportSshConfig'",
    r"'$ConfirmEndpoints'",
    r"'$SetMonitorSet'",
    // A rejected monitor set's debugPrint diagnostic, an ineligible
    // server's programmer error and the not-saved diagnostic; surfaces
    // show ARB text (monitorSetNotSaved, monitorSetNotChanged).
    r"'$requestName: $reason'",
    "'serverId'",
    "'not eligible'",
    r"'The monitor set was not saved: $error'",
  },
  // The full set's diagnostic; surfaces show their own ARB text
  // (monitorSetFull).
  'lib/controllers/monitor_set.dart': {
    r"'The monitor set already holds $kMonitorSetLimit servers'",
  },
  // debugPrint diagnostics beside the toasts' ARB text.
  'lib/ui/monitor_set_feedback.dart': {r"'$error'"},
  // The diagnostic of a sync answer the stopped engine never gave;
  // surfaces show ARB text for its failure kind (syncFailed).
  'lib/controllers/stack_folders.dart': {
    // The line break the folders field separates folders by, and the
    // path separator and parent segment a folder is checked for.
    r"'\n'",
    "'/'",
    "'..'",
  },
  'lib/controllers/sync_controller.dart': {"'the engine stopped'"},
  // A Docker query id the engine echoes in its answer (03 §10.1).
  // The query and watch ids the engine keys Docker answers by (03 §10.1).
  'lib/controllers/docker_controller.dart': {
    r"'docker-${_count++}'",
    r"'containers-${_count++}'",
    r"'summary-${_count++}'",
    r"'df-${_count++}'",
    r"'container-${_count++}'",
    r"'compose-${_count++}'",
    r"'images-${_count++}'",
    r"'stacks-${_count++}'",
    r"'volumes-${_count++}'",
    r"'networks-${_count++}'",
    r"'stack-file-${_count++}'",
  },
  'lib/controllers/docker_endpoint_choices.dart': {
    // The not-saved diagnostic of a purge, which no surface starts; a
    // choice the user makes shows ARB text when not saved
    // (dockerSocketNotSaved).
    r"'The Docker socket choices were not saved: $error'",
    // The endpoint key of a server the last fleet did not list, which the
    // next fleet then drops. Never shown.
    "''",
  },
  'lib/controllers/container_terminals.dart': {
    // A terminal id the engine keys a shell's events by (03 §7.13), and
    // the rejected request's class name, which RequestRejected carries.
    r"'shell-${_count++}'",
    r"'$OpenTerminal'",
  },
  'lib/controllers/log_streams.dart': {
    // A log stream id the engine keys a stream's events by (03 §10.1), and
    // the rejected request's class name, which RequestRejected carries.
    r"'log-${_count++}'",
    r"'$OpenLogStream'",
  },
  'lib/controllers/monitoring_controller.dart': {
    // Assert messages; programmer diagnostics, never rendered.
    r"'$stream carries no metrics'",
    "'unsubscribe instead of naming no stream'",
    r"'leaveServer without openServer for $serverId'",
    // A subscription id the engine keys a surface's streams by (D45).
    r"'$surface-${_subscriptionCount++}'",
    // A host query's id, which its HostResult answers by (LOG-08, LOG-09).
    r"'host-${_nextHostQuery++}'",
    // A unit read's request id, never shown.
    r"'unit-${_nextUnitQuery++}'",
    // An export redaction's id, which its RedactedLines answers by
    // (LOG-10).
    r"'redact-${_nextRedaction++}'",
  },
  // Services panel (SVC-01 to SVC-04, CN-10).
  'lib/controllers/log_reads.dart': {
    // An assert message; programmer diagnostic, never rendered.
    "'a follow is not a bounded read'",
  },
  // The coverage card's one `units` read: a subscription surface kind the
  // engine keys its streams by (D45).
  'lib/ui/server_coverage.dart': {"'coverage'"},
  'lib/ui/services_view.dart': {
    // systemd's spelling of load and sub states and the dot before a unit
    // type, matched against server data; the panel shows ARB text for
    // what does not match (chartUnknownValue).
    "'[A-Z]'",
    r"'-${capital[0]!.toLowerCase()}'",
    r"r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$'",
    "'.'",
  },
  'lib/services/macos_titlebar.dart': {
    // The 04 §12.3 method channel name.
    "'klabautermann/window'",
    // debugPrint diagnostics of a failed titlebar install or reset, and of
    // an unavailable toolbar band state.
    r"'Integrated titlebar install failed: $error'",
    r"'Standard titlebar reset failed: $error'",
    r"'Toolbar band state unavailable: $error'",
  },
  // The settings window's wire: channel names, the argument its engine
  // starts with, an error's text as the link carries it, an unknown
  // method's diagnostic and the lost link's diagnostic. Plumbing between
  // two engines; the window shows ARB text for every failure.
  'lib/services/settings_window/settings_window_link.dart': {
    "'klabautermann/settings_window'",
    "'klabautermann/settings_link'",
    "'--klabautermann-settings-window'",
    r"'$error'",
    "'The app is locked'",
  },
  'lib/services/settings_window/settings_window_host.dart': {
    r"'No settings window method $name'",
    "'No pin publication settings'",
    "'No app lock settings'",
  },
  'lib/services/settings_window/remote_settings.dart': {
    "'Settings link closed'",
    // The device name until the first snapshot, which comes with hello.
    "''",
  },
  // The app lock (SAF-20): a failed change's text for the debug log, the
  // empty reason that picks the toast's generic branch, and the line break
  // between the switch's detail and its note.
  'lib/ui/app_lock_settings.dart': {r"'$error'", "''", r"'\n'"},
  // Diagnostics in AppLockException, never shown: the lock's screens word
  // failures from its availability alone.
  'lib/services/device_authenticator.dart': {
    r"'device authentication failed: ${error.code}'",
    "'device authentication was rejected'",
    "'device authentication is unavailable'",
  },
  // A keystore failure's text, which the answer carries to the engine as
  // a diagnostic; surfaces show ARB text (syncFailedKeystore).
  'lib/services/engine_keystore.dart': {r"'$error'"},
  'lib/services/ssh_config_source.dart': {
    // The environment variable the Windows home directory is read from, and
    // the file path the import expands.
    "'USERPROFILE'",
    "'~/.ssh/config'",
    // The config text with the byte-order mark the decoder dropped, which
    // the engine must see as ssh does.
    r"'\u{FEFF}$text'",
  },
  'lib/services/window_state.dart': {
    // The state file's name in the support directory (03 §4.10).
    "'window_state.json'",
    // debugPrint diagnostic of a failed restore or save.
    r"'Window state: $error'",
  },
  // The brand preset's stored name, English across the family like the
  // siblings' preset names; no surface shows it yet.
  'lib/theme/app_theme.dart': {"'Klabautermann'"},
  // The Access tab's copied fix command: the pattern of a shell word that
  // needs no quoting, and the space between the command's words.
  'lib/ui/access/access_panel.dart': {r"r'^[A-Za-z0-9_./:@+,-]+$'", "' '"},
  // Chart assert messages, RangeError argument names and the read-only
  // ring view's UnsupportedError: programmer diagnostics, never rendered.
  'lib/ui/charts/bars.dart': {
    "'a stacked bar needs a segment'",
    "'a colour per segment'",
    "'a pressure bar needs a cell'",
    "'a colour per cell'",
    "'a bar has a cell'",
  },
  'lib/ui/charts/chart_style.dart': {"'warning must not exceed critical'"},
  'lib/ui/charts/chart_values.dart': {"'samples are finite'"},
  'lib/ui/charts/series_ring.dart': {
    "'a series needs two slots to draw a line'",
    "'index'",
    "'A series ring changes only through add'",
    "'a column holds at least one sample'",
  },
  'lib/ui/charts/sparkline.dart': {"'the scale needs a positive top'"},
  'lib/ui/charts/time_series.dart': {
    "'a series needs two slots to draw a line'",
    r"'a chart draws 1 to $_maxLanes series'",
    "'lane'",
    "'one value per lane'",
    "'index'",
    "'a column spans time'",
  },
  'lib/ui/charts/time_series_chart.dart': {
    "'one label per lane'",
    "'the window spans time'",
    "'the scale needs a positive top'",
  },
  // debugPrint of a dismissal that was not saved; the toast is ARB text.
  'lib/ui/coverage.dart': {r"'$error'"},
  'lib/ui/docker/container_details.dart': {
    // A mount's type as the Engine API names it, matched, never shown;
    // the empty type a mount without one reads as; the separator between
    // a network's aliases, machine data.
    "'volume'",
    "''",
    "', '",
  },
  // The ps column title of resident memory, matched, never shown.
  'lib/ui/docker/container_processes.dart': {"'RSS'"},
  'lib/ui/docker/container_details_view.dart': {
    // The Engine API's restart policy names, matched, never shown; the
    // empty one is the default.
    "''",
    "'no'",
    "'always'",
    "'unless-stopped'",
    "'on-failure'",
    // The raw view's JSON: the Engine API's inspect field names, as
    // `docker inspect` prints them, its indent, and an environment
    // variable in the API's KEY=value form, its value masked. Machine
    // data, never translated (03 §10.10).
    "'Aliases'",
    "'Args'",
    "'AutoRemove'",
    "'Binds'",
    "'Cmd'",
    "'Config'",
    "'Created'",
    "'Dead'",
    "'Destination'",
    "'Driver'",
    "'End'",
    "'Entrypoint'",
    "'Env'",
    "'Error'",
    "'ExitCode'",
    "'FailingStreak'",
    "'FinishedAt'",
    "'Gateway'",
    "'Health'",
    "'HostConfig'",
    "'Hostname'",
    "'IPAddress'",
    "'Id'",
    "'Image'",
    "'Labels'",
    "'Log'",
    "'LogConfig'",
    "'MacAddress'",
    "'MaximumRetryCount'",
    "'Memory'",
    "'Mode'",
    "'Mounts'",
    "'Name'",
    "'NanoCpus'",
    "'NetworkID'",
    "'NetworkMode'",
    "'NetworkSettings'",
    "'Networks'",
    "'OOMKilled'",
    "'Output'",
    "'Path'",
    "'Paused'",
    "'Pid'",
    "'PidMode'",
    "'Platform'",
    "'Privileged'",
    "'Propagation'",
    "'RW'",
    "'ReadonlyRootfs'",
    "'RestartCount'",
    "'RestartPolicy'",
    "'Restarting'",
    "'Running'",
    "'Source'",
    "'Start'",
    "'StartedAt'",
    "'State'",
    "'Status'",
    "'StopSignal'",
    "'Tty'",
    "'Type'",
    "'User'",
    "'WorkingDir'",
    "'  '",
    r"'${variable.name}=${variable.value.display}'",
  },
  'lib/ui/logs/container_lines.dart': {
    // The space after a word a view puts before a line's own text.
    "' '",
  },
  'lib/ui/docker/stack_logs.dart': {
    // A merged line: the container's name in its colour as SGR escapes,
    // then the line as the container wrote it.
    r"'\x1b[38;5;${colour}m$name\x1b[0m $text'",
  },
  'lib/ui/docker/container_terminal.dart': {
    // Shell paths the picker offers, run as typed, and the empty field
    // that leaves the choice to the engine.
    "'/bin/bash'",
    "'/bin/sh'",
    "'/bin/ash'",
    "''",
    // The separator of the command's words, as the exec runs them.
    "' '",
    // The select key whose ARB branch says the engine stopped.
    "'engineStopped'",
  },
  'lib/ui/docker/container_logs.dart': {
    // The logging driver Docker names `none`, matched, never shown, and
    // the driver an unnamed one fills the ARB text's slot with, which its
    // wording then leaves out.
    "'none'",
    "''",
  },
  'lib/ui/docker/containers_panel.dart': {
    // The key tests find a phone row by, in the table rows' form, and the
    // line break between its cells in its screen-reader label, each ARB
    // text; a heading's row key; empty cells and no ports.
    r"'${DockerWatchList.containers.name}.row.${_rowKey(entry)}'",
    r"'\n'",
    r"'group.${project ?? ''}'",
    "''",
  },
  'lib/ui/docker/containers_view.dart': {
    // The compose project label key (compose's pkg/api/labels.go).
    "'com.docker.compose.project'",
    // The search's term separator and the line break between the fields
    // it searches; empty values.
    r"r'\s+'",
    r"'\n'",
    "''",
    // The engine's Status text as go-units prints it, matched, never
    // shown: the health marker the health column replaces, the uptime's
    // words, and the wildcard addresses `docker ps` leaves out.
    r"r'\s*\((healthy|unhealthy|health: starting)\)'",
    "'less than a second'",
    "'about a minute'",
    "'about an hour'",
    r"r'^Up (.+?)(?: ago)?(?: \(.*\))?$'",
    r"r'^(\d+) (second|minute|hour|day|week|month|year)s?$'",
    "'0.0.0.0'",
    "'::'",
    // The separator `docker ps` prints between ports; machine data.
    "', '",
  },
  // debugPrint of a socket choice that was not saved; the toast is ARB
  // text (dockerSocketNotSaved).
  'lib/ui/docker/docker_endpoint_picker.dart': {r"'$error'"},
  'lib/ui/docker/images_panel.dart': {
    // The key tests find a phone row by, in the table rows' form, and the
    // line break between its cells in its screen-reader label, each ARB
    // text.
    r"'${DockerWatchList.images.name}.row.${_rowKey(entry)}'",
    r"'\n'",
  },
  'lib/ui/docker/images_view.dart': {
    // The tag `docker images` prints for none and the digest algorithm
    // image ids start with, matched, never shown; the one an image id's
    // algorithm ends with; the line break between the fields the search
    // reads; the separator between an image's tags, machine data.
    "'<none>:<none>'",
    "'sha256:'",
    "':'",
    r"'\n'",
    "', '",
  },
  'lib/ui/docker/stacks_panel.dart': {
    // The keys tests find a stack's row and the unlisted section by.
    r"'stacks.row.${project.name}'",
    r"'stacks.unlisted.${widget.serverId}'",
  },
  'lib/ui/docker/volumes_panel.dart': {
    // The key tests find a phone row by, in the table rows' form, and the
    // line break between its cells in its screen-reader label, each ARB
    // text.
    r"'${DockerWatchList.volumes.name}.row.${_rowKey(entry)}'",
    r"'\n'",
  },
  'lib/ui/docker/networks_panel.dart': {
    // The key tests find a phone row by, in the table rows' form, and the
    // line break between its cells in its screen-reader label, each ARB
    // text.
    r"'${DockerWatchList.networks.name}.row.${_rowKey(entry)}'",
    r"'\n'",
  },
  'lib/ui/docker/networks_view.dart': {
    // The line break between the fields the search reads.
    r"'\n'",
  },
  'lib/ui/docker/volumes_view.dart': {
    // The mount type of a named volume, matched, never shown; the line
    // break between the fields the search reads; the name pattern Docker
    // accepts (VOL-02).
    "'volume'",
    r"'\n'",
    "r'^[a-zA-Z0-9][a-zA-Z0-9_.-]+\$'",
  },
  'lib/ui/docker/unlisted_stacks.dart': {
    // The path separator a found file's folder and name split at, the
    // folders' list separator inside the ARB sentence, and the line
    // break the folders field shows one folder per line with.
    "'/'",
    "', '",
    r"'\n'",
  },
  'lib/ui/docker/stacks_view.dart': {
    // The name compose reads a working directory's environment file by,
    // the path separator, and the file's path joined from them, as the
    // engine joins it; machine data.
    "'.env'",
    "'/'",
    r"'$directory$_dotEnv'",
    r"'$directory/$_dotEnv'",
  },
  'lib/ui/docker/docker_panel.dart': {
    // An assert message; programmer diagnostic, never rendered.
    "'new controllers come with a new tree (KlabautermannApp, D44)'",
    // debugPrint of a dismissal that was not saved; the toast is ARB text.
    r"'$error'",
  },
  'lib/ui/fleet_row_state.dart': {
    // The root mount point whose use the pressure bar shows.
    "'/'",
    // The filter's term separator, and the name-and-address haystack that
    // stands in for the engine's search text.
    r"r'\s+'",
    r"'${server.displayName} ${server.address ?? ''}'",
    "''",
  },
  'lib/ui/fleet_rows.dart': {
    // The filter's empty query.
    "''",
    // A FocusNode debug label.
    "'Fleet filter'",
    // The key tests find a row's age by.
    "'fleetRowAge'",
    // The imports' section collapse key, and the key tests find a section
    // or group header by.
    "' imported'",
    r"'fleet.section.$key'",
    // The pin-not-saved diagnostic; the toast shows ARB text
    // (fleetPinNotSaved).
    r"'$error'",
    // The line break between the row tooltip's facts, each ARB text.
    r"'\n'",
    // An assert message; programmer diagnostic, never rendered.
    "'new controllers come with a new tree (KlabautermannApp, D44)'",
  },
  // The probe's tool name for crontab, looked up in its answer; never
  // rendered.
  'lib/ui/jobs_panel.dart': {
    "'crontab'",
    // The other users' table's key prefix, never shown.
    r"'${ServerPanel.jobs.name}.others'",
    // systemd's Result word for a service that succeeded, matched in
    // its answer (JOB-05); the details word it themselves.
    "'success'",
  },
  'lib/ui/interfaces.dart': {"'lo'"},
  'lib/ui/logs/logs_panel.dart': {
    // The empty server pattern, which reads the whole journal again.
    "''",
    // The folder LOG-08 browses, a path on the server handed to the
    // siblings (X-10), never shown.
    "'/var/log'",
  },
  'lib/ui/logs/log_query.dart': {
    // PCRE2's inline flags that pin journalctl's case rule (LOG-06):
    // sent to the server, shown only as the pattern sent.
    r"'(?-i)$pattern'",
    r"'(?i)$pattern'",
    "'/'",
    "'..'",
    "'/.'",
    "'/./'",
    "''",
    // LOG-22's common paths: paths on the server, shown verbatim as
    // server data (03 §10.10).
    "'/var/log/syslog'",
    "'/var/log/messages'",
    "'/var/log/auth.log'",
    "'/var/log/secure'",
    "'/var/log/nginx/access.log'",
    "'/var/log/nginx/error.log'",
    "'/var/log/apache2/access.log'",
    "'/var/log/apache2/error.log'",
    "'/var/log/httpd/access_log'",
    "'/var/log/httpd/error_log'",
  },
  // The search's initial empty query.
  'lib/ui/logs/log_search.dart': {"''"},
  'lib/ui/logs/log_tokens.dart': {
    // LOG-07's token patterns (URLs, IP addresses, HTTP status codes):
    // matched against server output, never shown.
    r"""r'''\b(?:https?|wss?|ftp)://[^\s<>"'`]+'''""",
    r"""r'[.,;:!?)\]}]+$'""",
    r"""r'(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)'""",
    r"""'(?<![\\w.])(?:$_octet\\.){3}$_octet(?::\\d{1,5}|/\\d{1,2})?(?!\\.?\\w)'""",
    r"""r'(?<![\w:])(?:'""",
    r"""r'(?:[0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}'""",
    r"""r'|(?:[0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{0,4}::'""",
    r"""r'(?:[0-9a-fA-F]{1,4}:){0,6}[0-9a-fA-F]{0,4}'""",
    r"""r')(?:%[\w.]+)?(?![\w:])'""",
    r"""r'(?:HTTP/\d(?:\.\d)?"?\s+'""",
    r"""r'|\b(?:GET|HEAD|POST|PUT|DELETE|PATCH|OPTIONS|CONNECT|TRACE)\s+\S+\s+'""",
    r"""r'|\b(?:[Ss]tatus|STATUS|[Cc]ode|CODE)(?:_code)?["\x27]?\s*[=:]\s*"?)'""",
    r"""r'([1-5]\d\d)\b'""",
  },
  'lib/ui/logs/log_export.dart': {
    // LOG-10's export: the lines joined as a text file, ending in a
    // newline, and the file's media type for the save dialog and the
    // share sheet.
    r"'\n'",
    r"'$text\n'",
    "'text/plain'",
  },
  'lib/ui/logs/log_text.dart': {
    // A row's unit and PID prefix in classic syslog notation, as
    // journalctl's short format prints it, or none.
    "''",
    r"'[${journal.pid}]'",
    r"'${journal.source ?? ''}$pid'",
    r"'$source: '",
    // The newline a journal MESSAGE's return mark and line separator
    // replace, the mark itself (a symbol, not words) and the space before
    // a cut line's note, whose words are ARB text (logLineCut).
    r"'\n'",
    r"'\u23ce\u2028'",
    "' '",
    // A container row's time in ISO 8601 order with a space for the T,
    // machine data, then its stream as the Engine API names it (CTX-01),
    // whose spoken name is ARB text (logContainerStream).
    r"'${iso.substring(0, 10)} ${iso.substring(11, _containerTimeWidth)}'",
    r"'${_containerTime(container.at)} ${container.stream.name} '",
  },
  'lib/ui/logs/log_view.dart': {
    // A FocusNode debug label.
    "'LogView'",
    // A journal field in journald's NAME=value notation, with newlines and
    // line or paragraph separators flattened to spaces to keep one row.
    r"'$name=$value'",
    r"'\n'",
    "' '",
    r"'[\u2028\u2029]'",
    // Glyph probes that measure the line height (the space above) and the
    // advance, never shown.
    "'W'",
  },
  // The command registry's ids, keys of the menus and shortcuts.
  'lib/ui/menus/app_commands.dart': {
    "'app.about'",
    "'app.settings'",
    "'fleet.importSshConfig'",
    "'app.quit'",
  },
  'lib/ui/menus/app_menu_host.dart': {
    // A FocusNode debug label.
    "'AppMenuHost'",
    // Error-report context of a failed command.
    r"'while running ${command.id}'",
  },
  // Menu-model assert messages and the slot key the duplicate check
  // compares; programmer diagnostics, never rendered.
  'lib/ui/menus/app_menus.dart': {
    "'commands reach the macOS application menu through appMenuOnMac'",
    r"'${placement.group}:${placement.order}'",
    r"'${command.id} shares menu slot ${placement.group}:${placement.order}'",
  },
  'lib/ui/mounts.dart': {
    // The separator between a mount's options, machine data as the kernel
    // lists them.
    "', '",
  },
  'lib/ui/oom_kills.dart': {
    // The journal pattern of an OOM report's kernel lines and the syslog
    // identifier the kernel's lines carry, both machine data.
    "'oom-kill|out of memory|killed process'",
    "'kernel'",
  },
  'lib/ui/processes_panel.dart': {
    // The key tests find a phone row by, in the table rows' form, and the
    // line break between its cells in its screen-reader label, each ARB
    // text.
    r"'${SampleStream.procs.name}.row.${row.pid}'",
    r"'\n'",
  },
  'lib/ui/processes_view.dart': {
    // The ellipsis ending a cut command line, the space between its
    // arguments, and the filter's term separator and the line break
    // between the fields it searches. The plus sign GNU ps ends a cut
    // user name with, and the run states PRC-06 flags (zombie and
    // uninterruptible sleep), which are matched, never shown.
    "'Z'",
    "'D'",
    r"'${text.substring(0, end)}…'",
    "' '",
    r"r'\s+'",
    r"'\n'",
    "'+'",
  },
  'lib/ui/prompts/prompt_host.dart': {
    // An assert message; programmer diagnostic, never rendered.
    "'new controllers come with a new tree (KlabautermannApp, D44)'",
    // Error-report context of a dialog that failed; the prompt is then
    // declined, and the dialog's own words are ARB text.
    "'while showing an engine prompt'",
    // An IPv6 host's brackets in the endpoint line, which ARB text
    // (promptEndpoint) frames; machine data, not copy.
    "':'",
    "'['",
    r"'[$host]'",
  },
  // A refusal's detail, which only the ARB's `other` branch shows: none,
  // or the error itself for one that is not a refusal.
  'lib/ui/server_editing.dart': {"''", r"'$error'"},
  // An assert message; programmer diagnostic, never rendered.
  'lib/ui/server_surfaces.dart': {
    "'new controllers come with a new tree (KlabautermannApp, D44)'",
  },
  'lib/ui/overview_panel.dart': {
    // The trailing core number of a /proc/stat name such as cpu12, which
    // orders the per-core figures; the names themselves are server data.
    r"r'\d+$'",
    // An assert message; programmer diagnostic, never rendered.
    "'new controllers come with a new tree (KlabautermannApp, D44)'",
  },
  // debugPrint of a failed theme change; the toast is ARB text.
  'lib/ui/settings_page.dart': {r"'$error'"},
  'lib/ui/sortable_table.dart': {
    // FocusNode debug labels.
    "'SortableTable'",
    "'SortableTable menu'",
    // Widget keys built from the caller's table, column and row ids.
    r"'${widget.tableId}.columns'",
    r"'${widget.tableId}.column.${column.id}'",
    r"'${widget.tableId}.rowActions.$key'",
    r"'${widget.tableId}.row.$key'",
  },
  // What systemd-detect-virt prints for no virtualization, compared with
  // the probe's answer; the System tab shows ARB text for it
  // (systemVirtualizationNone).
  'lib/ui/system_view.dart': {"'none'"},
};

const _config = L10nContractConfig(
  generatedLocalizationPrefix: _generatedLocalizationPrefix,
  generatedDartSuffixes: _generatedDartSuffixes,
  scannedDirectories: ['lib'],
);

/// Text and some of the parameters a screen reader or the paint path
/// reaches; not every user-facing parameter (see above).
final _userFacingSlotLiteral = RegExp(
  r'''\b(Text|text|title|subtitle|label|tooltip|hintText|semanticLabel)\s*[(=:]\s*['"][^'"]''',
);

void main() {
  final contract = LocalizationContract(
    appRoot: Directory.current.path,
    config: _config,
    allowedTechnicalLiterals: _allowedTechnicalLiterals,
  );

  /// The authored sources the contract covers, by app-root-relative path.
  Map<String, String> authoredSources() => {
    for (final entity in Directory('lib').listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart'))
        if (entity.path.replaceAll('\\', '/') case final path
            when !contract.isGeneratedPath(path))
          path: entity.readAsStringSync(),
  };

  test('limits technical exceptions to their reviewed file', () {
    const source = "const String kSettingsRoute = '/settings';";

    expect(
      contract.findDisallowedLiterals(path: 'lib/app.dart', source: source),
      isEmpty,
    );
    expect(
      contract.findDisallowedLiterals(
        path: 'lib/ui/example.dart',
        source: source,
      ),
      isNotEmpty,
    );
  });

  test('keeps every technical exception live', () {
    final dead = contract.scan().whereType<DeadAllowlistEntry>().toList();

    expect(dead, isEmpty, reason: dead.join('\n'));
  });

  test('authors user-facing strings only in ARB', () {
    final findings = contract.scan();

    expect(findings, isEmpty, reason: findings.join('\n'));
  });

  test('generated localization exclusions are present', () {
    for (final path in _generatedLocalizationPaths) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'generated localization output is missing: $path',
      );
    }
  });

  test('every ARB key is used by lib/', () {
    final arb =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
            as Map<String, Object?>;
    final keys = [
      for (final key in arb.keys)
        if (!key.startsWith('@')) key,
    ];
    // gen-l10n output names every key by construction, so it is left out.
    final sources = authoredSources().values.join('\n');

    expect(keys, isNotEmpty);
    for (final key in keys) {
      expect(
        RegExp('\\b$key\\b').hasMatch(sources),
        isTrue,
        reason: 'ARB key "$key" is never referenced in lib/',
      );
    }
  });

  test('no listed user-facing slot takes a string literal', () {
    for (final MapEntry(key: path, value: source)
        in authoredSources().entries) {
      final match = _userFacingSlotLiteral.firstMatch(source);
      expect(
        match,
        isNull,
        reason: '$path carries a literal into a user-facing slot: ${match?[0]}',
      );
    }
  });
}
