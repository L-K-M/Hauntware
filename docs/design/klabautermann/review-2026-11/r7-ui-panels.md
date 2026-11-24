# r7: UI panels review (prefix UIA)

Slice: `klabautermann/app/klabautermann_app/lib/ui/*.dart` plus `ui/settings`,
`ui/menus`, `ui/prompts`, `ui/access`, `ui/edit`. Paths below are relative to
`klabautermann/app/klabautermann_app/` unless they start with `packages/`.

Counts: high 1, medium 3, low 7 (11 findings). Bugs 5, security 1, refactor 4,
test 1 (folded into UIA-01 and UIA-02 where it belongs to the same fix).

Verification done: `SecretRedactor` run against sample lines (scratch Dart
script, repo package config); two scratch widget tests run with
`flutter test --no-pub` from the app directory against files kept in the
scratchpad (nothing written to the repository, `git status` clean after);
one scratch Dart expression for UIA-07. Everything else is from reading code.

---

## UIA-01 Diagnostic bundle exports process command lines and crontab text without argument masking

- Kind: security. Severity: high. Size: M. Confidence: high.
- Files: `lib/ui/diagnostic_bundle.dart:17-25,110-114`;
  `packages/klabautermann_core/lib/src/sampling/sampling_scheduler.dart:71-75,677-685`;
  `packages/klabautermann_core/lib/src/engine/engine_isolate.dart:99,1326-1332`;
  `lib/ui/logs/log_export.dart:286-288`.
- What is wrong: the bundle carries the raw `procs` section (every
  `/proc/<pid>/cmdline`, NULs turned to `\x1f`,
  `packages/klabautermann_host/lib/src/hws/program.dart:979-982`) and the raw
  `cron` section (`crontab -l`, `/etc/crontab`, `/etc/cron.d/*`,
  program.dart:1095-1111). `kDiagnosticCollectors` is every argument-less
  collector but `probe` and `ops`, so both are in. The sections reach the app
  as `DiagnosticSection.text`, "not yet redacted" (protocol.dart:2811-2813).
  The only redaction on export is `RedactLines`, which is
  `lines.map(_exportRedactor.redact)` with seance_core's generic
  `SecretRedactor`: provider token shapes, `bearer <token>`, and
  `password|passwd|secret|api_key|token` followed by `=` or `:`. It is not
  `maskCommandLine` (03 §8.9), which is what the Processes tab, the Jobs tab
  and unit details use for the same data.
- Proof (scratch run of `SecretRedactor().redact`, mask is `«redacted»`):

  ```
  1234 mysql -uroot -phunter2 db            -> unchanged
  1235 curl -u admin:hunter2 https://x      -> unchanged
  1236 redis-cli -a hunter2                 -> unchanged
  1237 app --password hunter2               -> unchanged
  1239 psql postgres://bob:hunter2@db/x     -> unchanged
  0 3 * * * mysqldump -phunter2 db | gzip   -> unchanged
  sshpass -p hunter2 ssh h                  -> unchanged
  PGPASSWORD=hunter2 pg_dump                -> unchanged (lookbehind rejects the PG prefix)
  docker login -p hunter2 reg               -> unchanged
  app --password=hunter2                    -> app --password=«redacted»
  ```

  Every "unchanged" form is masked on screen by `maskCommandLine`
  (declined.md records the #741 argv-masking work for exactly these shapes).
- Scenario: a user files a parser bug, opens Safety > Diagnostic bundle,
  leaves "Include secrets" off, and shares the file. A `mysqldump -p<pw>`
  cron line or a running `curl -u user:pw` is in it in clear, while the
  sheet says "Passwords, tokens and keys are replaced before the lines leave
  the app" (`logsExportSecretsRedacted`, app_en.arb:4400). FEATURES SAF-07
  lists "process arguments (`-p<secret>`, `--password=`) and URL credentials"
  as masked and "every share or export path redacts by default". The
  `diagnosticsHint` warns to read the file first, but about host names and
  addresses, not about command-line secrets.
- Second gap, same path: redaction is per line, so the redactor's multi-line
  `-----BEGIN … PRIVATE KEY-----[\s\S]*?-----END` rule can never match an
  export; only relevant if a collector ever carries PEM text.
- Proposed fix: redact the bundle in the engine by collector, before or as
  part of `RedactLines`: for `procs`, split each cmdline record on `\x1f`
  and replace it with `maskCommandLine(args)` display text; for `cron`, run
  the command part of each line through the same masking the cron rows use
  (`job_history_query.dart:105` pattern), then apply `SecretRedactor`. Keep
  the "Include secrets" path raw. Either add a
  `RedactDiagnosticBundle(sections)` request or mask in
  `_finishDiagnostics` and carry both forms. Also add URL-credential and
  env-prefix (`[A-Z_]*PASSWORD=`) coverage to the generic redactor for log
  exports.
- Test gap: `test/diagnostic_bundle_test.dart:101-131` only asserts that a
  `RedactLines` request is sent and feeds back the literal `'redacted'`; no
  test runs the real redactor over a `procs` or `cron` fixture. Add an
  engine test with the lines above.
- Design note: 03 §6.5 (line 3428) says the bundle is "redacted by
  `SecretRedactor`", so the code matches that sentence; the conflict is with
  SAF-07 and §8.9. Treat as a design gap to close, not as drift.

## UIA-02 Admin-mode password dialog overflows on phones, clipping the password field

- Kind: bug. Severity: medium. Size: S. Confidence: high (reproduced).
- File: `lib/ui/prompts/elevation_dialog.dart:58-86`.
- What is wrong: `AlertDialog(content: Column(mainAxisSize: min, …))` with
  no `scrollable: true` and no scroll view. The field is `autofocus: true`,
  so on a phone the keyboard is always up when the dialog shows.
- Proof: scratch widget test (Roboto loaded, `retry: true`, real
  `showElevationPasswordDialog`):

  | view | text scale | keyboard | result |
  | --- | --- | --- | --- |
  | 320x568 | 1.0 | 0 | fits |
  | 320x568 | 1.0 | 260 | content Column 28 px high, overflows by 192 |
  | 360x640 | 2.0 | 0 | overflows by 264 |
  | 360x640 | 2.0 | 300 | content Column 0 px high |
  | 412x915 | 2.0 | 300 | overflows by 249 |
  | 360x640 | 1.3 | 300 | no exception, but content Column 0 px high |

  The overflowing flex is the content Column inside the dialog's Flexible.
- Scenario: a phone user at 200 % text (A11Y-09's target), or a small phone
  at default text, turns on admin mode; the password field and the retry
  notice are clipped or have no height, so the password cannot be seen or
  reached. Release builds clip silently.
- Proposed fix: `scrollable: true` (as `alert_rules.dart` does) or wrap the
  content in `SingleChildScrollView`.
- Test gap: STATUS (M6 N67) says `text_scaling_test.dart` sweeps panels,
  phone destinations, Settings tabs and the server editor at 200 %; it
  opens no dialog (no `showDialog`/`AlertDialog` reference in the file).
  Add the app's own dialogs to the sweep, with a keyboard inset.

## UIA-03 Jobs tab reads permanently "Stale" under the Cellular saver profile

- Kind: bug (plus stale comment). Severity: medium. Size: S. Confidence: high.
- File: `lib/ui/jobs_panel.dart:39-43,431-439,572,581`.
- Lines:

  ```dart
  /// When the list turns stale: twice the 60 s desktop and phone period of
  /// `timers` and `cron` (03 §6.4). Cellular saver reads them once per
  /// subscription, so this limit needs another look once the app sends
  /// `SetCadenceProfile`.
  const Duration _staleAfter = Duration(seconds: 120);
  ```

- What is wrong: the app now sends `SetCadenceProfile`
  (`lib/controllers/monitoring_controller.dart:657`, STATUS M6 N64b), and
  `samplingPeriod` returns null for `timers`, `cron` and `userTimers` under
  `cellularSaver` (`sampling_scheduler.dart:47-49`: read once per
  Subscribe). So two minutes after the Jobs tab opens under Cellular saver
  (the general setting or a per-server cap) the freshness line switches to
  "Stale: updated N min ago", the history icon shows and every next-run
  cell greys, for as long as the tab stays open, although nothing is wrong
  and no newer reading is due.
- Proposed fix: pass the effective cadence profile for the server to the
  panel and use no stale limit (or a "read once" freshness word) when the
  stream has no period; delete the "needs another look" comment. The same
  check is worth making for `temps`/`gpu` in the System tab, which are also
  read once under the saver (I did not find a stale limit applied to them).

## UIA-04 Threshold dialog and sign-out confirmation share the non-scrolling dialog pattern

- Kind: bug. Severity: low. Size: S. Confidence: high for thresholds
  (reproduced), medium for sign-out (same code shape, not run).
- Files: `lib/ui/thresholds_tab.dart:164-177`;
  `lib/ui/settings/sync_sign_out_section.dart:70-86`.
- What is wrong: same as UIA-02. The threshold dialog holds three text
  fields and an error line in a plain Column; at 320x568 and 200 % text it
  overflowed by 72 px without a keyboard in the scratch test. The three
  fields are numeric, so a keyboard is up whenever one is focused.
- Proposed fix: `scrollable: true` on both; fold into the UIA-02 sweep.

## UIA-05 `PanelNotice`, `StateNotice` and services' `_notice` are three copies of one widget

- Kind: refactor. Severity: medium. Size: M. Confidence: high.
- Files: `lib/ui/system_panel.dart:923-970` (`PanelNotice`, 81 call sites),
  `lib/ui/state_notice.dart:7-50` (`StateNotice`, 16 call sites),
  `lib/ui/services_panel.dart:964-990` (`_notice`).
- What is wrong: `PanelNotice` and `StateNotice` are line-for-line the same
  (MergeSemantics, 18 px muted icon, text, four-line detail); the only
  difference is that `StateNotice` drops an empty detail. `_notice` is the
  same layout with a 20 px icon and a live region. `PanelNotice` and
  `PanelSection` live in `system_panel.dart`, so 20 files import a 1000-line
  tab file `show PanelNotice, PanelSection`, while `panel_kit.dart` exists
  for shared panel pieces and holds only `TitledGroup`.
- Proposed extraction: move `PanelSection` and one notice widget into
  `panel_kit.dart` as `PanelNotice({icon, text, detail, bool live = false})`
  with the empty-detail rule; delete `state_notice.dart` and `_notice`.
  Add `PanelNotice.unavailable(CollectorUnavailable, text)` for the
  "timeout shows `timer_off_outlined`, anything else `error_outline`"
  choice repeated in `jobs_panel.dart:474`, `overview_panel.dart:273,793`,
  `processes_panel.dart:173`, `system_panel.dart:822`.

## UIA-06 Panel scaffolding is copied per panel

- Kind: refactor. Severity: medium. Size: M. Confidence: high.
- What is duplicated (my slice; the docker directory repeats all of it):
  - `const double _wideWidth = 600` in `jobs_panel.dart:26`,
    `overview_panel.dart:32`, `processes_panel.dart:25`,
    `services_panel.dart:31`, `system_panel.dart:67` (and four docker
    panels), each followed by the same
    `box.maxWidth >= MediaQuery.textScalerOf(context).scale(_wideWidth)`.
  - `const double _headerShare = 0.4` plus the same "header scrolls within
    a share of the height, 12 px gap, Expanded body" Column in
    `processes_panel.dart:298-325`, `jobs_panel.dart:213-262` and `547-647`,
    `services_panel.dart:940-960` (`_headed`), and six docker panels.
  - `static final Listenable _silent = Listenable.merge(const [])` in
    `fleet_rows.dart:708`, `server_coverage.dart:101`, `fleet_board.dart:169`,
    `jobs_panel.dart:93`, `overview_panel.dart:137`, `processes_panel.dart:68`.
  - The "latest sample, last reading, sampling, profile, merge, freshness
    line, unavailable notice, waiting notice" preamble in `processes_panel`,
    `jobs_panel`, `overview_panel`.
- Proposed extraction into `panel_kit.dart`: `kPanelWideWidth` with
  `bool panelIsWide(BuildContext, BoxConstraints)`; `HeadedPanelBody(header,
  body, {headerScroll})` (services' `_headed` promoted, padding by width);
  `kSilentListenable`; and `FreshnessNotice(freshnessOf: …, clock, ticking)`
  wrapping the ListenableBuilder that three panels write by hand.

## UIA-07 Alert rule editor accepts a duration that overflows into a negative one

- Kind: bug. Severity: low. Size: S. Confidence: high (arithmetic run).
- File: `lib/ui/alert_rules.dart:440-448`.
- Lines:

  ```dart
  if (value == null || value < 0) return l10n.alertRuleMinutesInvalid;
  …
  static Duration _minutes(String text) => Duration(
    milliseconds: (_parse(text)! * Duration.millisecondsPerMinute).round(),
  );
  ```

- What is wrong: no upper bound. `Duration(milliseconds: (1e16 *
  60000).round())` prints `-0:00:00.001000` (the double saturates to
  int64 max, the microsecond multiply wraps). A typo such as a pasted long
  number saves a synced rule with a negative "for" duration, which every
  device then evaluates.
- Proposed fix: refuse values above a sane limit (for example 7 days) in
  `_validateMinutes`; a matching check where the engine validates a rule
  write would stop other clients too.

## UIA-08 Split the largest files

- Kind: refactor. Severity: low. Size: L. Confidence: high.
- `overview_panel.dart` (1734 lines) holds the panel shell, three data
  holders and every card. Split along the classes already there:
  `overview_health.dart` (`DiskAlarm`, `diskAlarms`, `_PartTwo.health`,
  `_UnhealthyContainers`, lines 338-378, 692-945),
  `overview_docker_card.dart` (`_Docker`, `_DockerSummaryWatch`,
  `_DockerCard`, 431-690), `overview_core_cards.dart` (`_Cards`,
  `_CoreBars`, `orderedCores`, 1168-1690), `overview_host_disks.dart`
  (`_PartTwo.disks/host`, 947-1137); the shell keeps `OverviewPanel` and
  `_Slow`.
- `jobs_panel.dart` (1465): `job_details.dart` (`JobDetails`, `JobLastRun`,
  `_TimerDetailsLoader`, `_Labelled`, `_Run`, `_showDetails`, 993-1465,
  already public in part and imported by other files),
  `jobs_table.dart` (`_columns`, `_next`, `_nextWidth`, `_NextCell`,
  `_JobCell`, `_ClockGate`, 653-1131), leaving the panel state and the
  other-users view.
- `processes_panel.dart` (1115): `process_sheet.dart` (`_showProcess`,
  `_ProcessSheet`, `_Facts`, 696-1115); `_columns` could join
  `processes_view.dart`, which already holds the pure helpers.
- `system_panel.dart` (1014): after UIA-05 moves `PanelSection` and
  `PanelNotice` out, the unavailable-text helpers (815-835) go with them.
- `settings_page.dart` (1175) and `fleet_rows.dart` (1226) were only
  skimmed; each General/Sync/Servers/Safety tab body in `settings_page`
  already repeats one `writeSetting<…NotSavedException>` wrapper per
  setting (lines 300-342, 594, 742, 857, 873, 1169) and would split per tab
  into `ui/settings/`, where `editor_settings.dart` and
  `recovery_settings.dart` already live.

## UIA-09 "Newest read wins" boilerplate is hand-written in 14 places beside a mixin that does it

- Kind: refactor. Severity: low. Size: M. Confidence: high.
- Files: `read_section.dart:20-70` has `HostReadSectionState` (ticket,
  reading flag, reread on server or controller change). The same
  `final ticket = ++_ticket; … if (!mounted || ticket != _ticket) return;`
  with its own `didUpdateWidget` reset is repeated in `accounts.dart:134-163`,
  `updates.dart:145-183`, `boots.dart:67-101`, `certificates.dart:56-98`,
  `doctor.dart:420-447`, `unit_details.dart:72-90,288-296`,
  `history_card.dart:123-141`, `processes_panel.dart:785-802`,
  `mounts.dart:43-49` (this one has no ticket and no server-change reset; it
  is only shown in a sheet today).
- Proposed extraction: a small `LatestRead<T>` value class
  (`Future<void> run(Future<T> Function())`, `T? value`, `bool reading`,
  `reset()`) owned by the State, or widen the mixin to a generic
  `ReadSectionState<W, T>` whose `read()` the section supplies; the admin
  variant keeps its per-server reading set.
- Related, not verified as reachable: `AdminReadSectionState.readAdmin`
  (`read_section.dart:112-122`) and `disk_explorer.dart:138-154` have no
  error path, so a throwing read would leave the "reading" state set for
  good. I did not trace whether `AdminController.read*` or
  `diskUsage.read` can throw; a shared helper with `try/finally` removes
  the question.

## UIA-10 Processes tree mode hides which column orders the rows

- Kind: bug. Severity: low. Size: S. Confidence: high.
- File: `lib/ui/processes_panel.dart:276-279`.
- Lines:

  ```dart
  // The tree is already in order; a header still picks the
  // order of siblings.
  sort: _tree ? null : _sort,
  onSort: (sort) => setState(() => _sort = sort),
  ```

- What is wrong: with the Tree chip on, the table gets `sort: null`, so no
  header shows the chevron or announces "sorted ascending/descending"
  (`sortable_table.dart:887-921`), while clicks still change `_sort` and
  reorder siblings. `TableSort.next(null, column)` also restarts every
  click at the column's first direction, so a header can never be flipped
  in tree mode: clicking CPU twice stays descending.
- Proposed fix: pass `sort: _sort` with `rowOrder: TableRowOrder.asGiven`,
  which exists for exactly this ("a grouped list that sorts within each
  group; the headers still show and change the sort").

## UIA-11 Overview rebuilds every card on each clock tick

- Kind: refactor. Severity: low. Size: M. Confidence: medium (rebuild is
  certain, cost not measured).
- File: `lib/ui/overview_panel.dart:160-183`.
- What is wrong: the inner `ListenableBuilder` listens to
  `monitoring.clock` and calls `_build`, which constructs `_Cards`,
  `_PartTwo`, the LayoutBuilder and every arranged card, once per second
  while the tab shows, only to refresh the freshness words and the stale
  grey. The Processes and Jobs panels solve the same need with a narrow
  clock listener (`processes_panel.dart:161-170,312-321`) and `_ClockGate`
  (`jobs_panel.dart:657-729`), whose comment gives the reason.
- Proposed fix: listen to the clock only in the head notice and in a
  stale-theme wrapper, as Processes does, or promote `_ClockGate` to
  `panel_kit.dart` with `dueAfter` = the next stale instant.

---

## Checked and found sound (no finding)

- Dispose and listeners: every controller, focus node, scroll controller,
  timer and listener I found in the slice has a matching dispose, cancel or
  removeListener (scripted count, then spot reads of `sortable_table`,
  `desktop`-side `server_workspace`, `services_panel`, `remote_editor`,
  `time_display`, `prompt_host`, `disk_explorer`).
- Async gaps: a scripted scan of every `await` followed by `setState`,
  `context`, `Navigator` or `widget.` without a `mounted` check produced
  only false positives (arguments of the awaited call, or ticket helpers).
- State after switching server on desktop (the workspace is not keyed by
  server): Processes, Jobs, Services, System and its sections, Updates,
  Accounts, Certificates, Boots, History, Top lists and the read mixins all
  reset or re-read in `didUpdateWidget`; Access is keyed by server id.
- Icon buttons: a scripted scan found no `IconButton` without a tooltip.
- ARB: a scripted scan found no literal user-visible string in `Text`,
  `label`, `tooltip`, `hintText`, `title` or `semanticLabel` positions.
- Command registry: the only shortcut handlers outside `ui/menus` are list
  keys inside focused widgets (`sortable_table`, `disk_explorer`,
  `workspace_dock` resize edge, `keyboard_map` Escape); all pass on keys
  they do not use, so I found no keyboard trap and no app-level shortcut
  that bypasses `AppCommand`.
- A11Y-07: `alerts.dart:411-422`, `attention.dart:410` and
  `status_card.dart:78` show device-local times; STATUS M6 N67 says times
  this device made stay device times, so not raised.

## Overall assessment

The slice is unusually disciplined: lifecycle, server-switch and
mounted-after-await handling are consistent, strings and tooltips are
complete, and menus do render the registry. The one finding that matters is
the diagnostic bundle, where the export path is weaker than the on-screen
masking for the same data. The reproducible UI defects are dialogs that do
not scroll, which the 200 % text sweep misses because it opens no dialog.
The maintenance cost is in copied panel scaffolding and three very large
files, all with mechanical splits.

## Coverage

- Read fully: `diagnostic_bundle.dart`, `sortable_table.dart`,
  `server_workspace.dart`, `processes_panel.dart`, `jobs_panel.dart`,
  `time_display.dart`, `freshness.dart`, `read_section.dart`,
  `snippets.dart`, `menus/app_commands.dart`, `panel_kit.dart`,
  `state_notice.dart`, `prompts/elevation_dialog.dart`.
- Read in large part: `overview_panel.dart` (1-475), `disk_explorer.dart`
  (60-478), `workspace_dock.dart` (60-358), `server_editing.dart` (60-424),
  `prompts/prompt_host.dart` (60-436), `edit/remote_editor.dart` (95-424),
  `menus/app_menu_host.dart` (100-260), `access/access_panel.dart` (60-200),
  `thresholds_tab.dart`, `alert_rules.dart` (validation and save),
  `drive_health.dart`, `firewall.dart`, `oom_kills.dart`, `mounts.dart`,
  `boots.dart`, `updates.dart` and `services_panel.dart` (state handling).
- Skimmed by pattern only (scripted scans and greps): `desktop_shell.dart`,
  `phone_shell.dart`, `fleet_rows.dart`, `fleet_tree.dart`,
  `fleet_board.dart`, `system_panel.dart`, `settings_page.dart`,
  `alerts.dart`, `attention.dart`, `coverage.dart`, `server_coverage.dart`,
  `doctor.dart`, `footprint_page.dart`, `certificates.dart`,
  `unit_details.dart`, `top_lists.dart`, `history_card.dart`,
  `server_header.dart`, `jobs_view.dart`, `system_view.dart`, `power.dart`.
- Not reached: `sync_sign_in.dart`, `endpoint_confirmation.dart`,
  `threshold_announcer.dart`, `server_detail_page.dart`,
  `fleet_rail.dart`, `accounts.dart` body, `interfaces.dart`,
  `listening_ports.dart`, `sshd_posture.dart`, `gpus.dart`,
  `temperatures.dart`, `disk_activity.dart`, `quick_actions.dart`,
  `hand_off_actions.dart`, `palette.dart`, `appearance_tab.dart`,
  `editor_strings.dart`, `server_editor_strings.dart`, `access/panel_gate.dart`,
  `settings/*` other than the sign-out dialog, `menus/app_menus.dart`, and
  the remaining small files. Overflow at 320 to 360 px was tested only for
  the dialogs above; the panels rely on the existing sweep.
