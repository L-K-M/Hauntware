# Klabautermann: fix and refactor plan

Reviewed at main `9e2080d44` (after #801), 2026-11-17. Ten independent
reviewers read the product by slice; their reports sit beside this file
(`r1-engine.md` to `r10-qa.md`) and hold the line references, scenarios
and proposed fixes for every ID below.

## How far to trust this

- 133 findings: 10 high, 51 medium, 72 low.
- Marked **[C]**: I confirmed it in the code myself. **[R]**: the reviewer
  reproduced it by running code or a script. Unmarked: traced by reading
  only. Every bug fix starts with a failing regression test, which is the
  real verification.
- No reviewer read its whole slice line by line. Not reached: most of
  `protocol.dart` class by class, half of `ssh_config_settings.dart`,
  `cron/expression.dart`, most of `docker_plans.dart`, about 25 small
  controllers, most of `settings_page.dart`, `fleet_rows.dart`,
  `desktop_shell.dart`, `sync_sign_in.dart`, `runner_vm.sh`, and STATUS
  lines 126 to 2782. Each report ends with its own coverage list.
- Found sound: shell quoting and validators (no injection path), the
  confirmation flow and read-only gating, package boundaries and `show`
  lists, the protocol guard, dispose and `mounted` handling in the UI, ARB
  coverage, and the 16 PRs merged with review waived (no weakened tests).

## Phase 1: the engine must not die or hang (first, one PR chain)

The largest theme. Three reviewers independently found that any
unexpected error in an unawaited future ends the engine isolate, and the
app never restarts it.

| Step | Items | Size |
|---|---|---|
| 1.1 Last-resort boundary: `runZonedGuarded` in `engineMain`, report a fatal event the client surfaces after the handshake | ENG-4 **[C]**, ENG-6 | M |
| 1.2 Plan runs: catch-all in `OperationRunner.run` so it always ends with one `ActionFinished`; error handler on the unawaited run | ENG-1 **[C]**, OPS-2 | M |
| 1.3 Admin password with CR/LF: validate before the engine, catch `ArgumentError` in `AdminModeController._check` | OPS-2 | S |
| 1.4 Docker router: catch non-Docker errors in `_run`/`_read`, `inFlight--` in `finally`; clamp the registry rate-limit window; guard `ascii.decode` in stack sources | DKR-1 **[C]** | M |
| 1.5 Sync chain links and scheduler request futures get an error path | ENG-5, SMP-09 | S |
| 1.6 History queue catches every error per write, not only file errors | SMP-04 | S |
| 1.7 Requests never left pending: `RequestRejected` carries the request id; one rejection no longer fails all pending opens | CTL-05, CTL-10 | M (protocol bump) |
| 1.8 Vault recovery no longer blocks the serial request queue behind a sync round | ENG-3 | M |
| 1.9 The app sends `Shutdown` on quit, so history flushes and shells write their closing audit record | CTL-02 **[C]** | S |

## Phase 2: wrong data and safety (parallel PRs, no shared files)

| PR | Items | Size |
|---|---|---|
| 2.1 Startup order: build every controller before the first `await` after the engine spawn (or replay the catalog), with a contract test. Synced read-only switches and protected marks are not enforced until the first sync round today | CTL-01 **[C]** structure, **[R]** lost event | M |
| 2.2 Re-import that changes an endpoint drops the old link; `DockerController` handles `EndpointChanged` | ENG-2 **[C]**, CTL-03 | M |
| 2.3 Edit pipeline: verify owner and group after `cp --attributes-only`, fall back to `stat` and `chown`; read the ops directory as UTF-8 | OPS-1 **[C]** script, **[R]** effect; OPS-6 | S |
| 2.4 Secrets: diagnostic bundle masks process command lines and crontab text; one-off container commands are masked in preview, audit and export; masker learns JSON and colon forms, token-only URL userinfo and `Authorization:` anywhere; volume and log driver options masked | UIA-01 **[R]**, OPS-3, SMP-02, DKR-9 | M |
| 2.5 Endpoint confirmation compares jump hosts with what you were shown before pinning them | ENG-7 | M |
| 2.6 Sign-out: delete vault entries before `servers.json`; do not copy removed servers' safety marks into `settings.json` | SMP-03, CTL-04 | S |
| 2.7 Operations: "Access denied" maps to admin-required only for systemctl and polkit; the power step's outcome stops being guessed from the transport | OPS-4, OPS-5 | S |
| 2.8 Host parsers: a dead mount no longer blanks the filesystem panel; sources with spaces parse from the right; forged `==> pid/cmdline <==` headers rejected; unit names accept `\`; cron section survives an unreadable `/etc/crontab` | HST-1 **[R]**, HST-5 **[R]**, HST-2 **[R]**, HST-3, HST-4 | M |
| 2.9 Docker client: `close()` covers a connection still opening and the watcher cancels the body; backpressure before a listener attaches; update cache keyed by image id; initial shell size on API 1.41 | DKR-2 **[R]**, DKR-3 **[R]**, DKR-4, DKR-5 | M |
| 2.10 History: no double count after a same-minute restart; fix the test that passes by timing | SMP-05 | S |

## Phase 3: the app freezes on hostile or large logs

| PR | Items | Size |
|---|---|---|
| 3.1 Linear-time `_levelWord` and `_urlTail`; cap the line length the highlighters read | SMP-01 **[R]** (0.9 to 13 s per row), UIB-2 **[R]** (2.5 s per row) | S |
| 3.2 Regex search off the UI isolate, in chunks, with cancel | UIB-1 **[R]** (15.7 s) | M |
| 3.3 Merged stack logs insert out-of-order batches without rebuilding; follow containers by service after a redeploy | UIB-3, UIB-9 | M |

## Phase 4: UI defects

- Dialogs scroll: admin password (clips the field on 320x568 with the
  keyboard up), thresholds, sign-out. UIA-02 **[R]**, UIA-04. S.
- Jobs tab no longer reads "Stale" for good under Cellular saver.
  UIA-03. S.
- Output sheets show refused, failed and loading states instead of a
  blank box. UIB-5. S.
- Finished power waits clear; alert notifications are withdrawn when the
  run ends. QA-08, CTL-06, CTL-09. S.
- Alert rule minutes bounded; thresholds refuse an inverted band.
  UIA-07, HST-10. S.
- Low items to batch: UIA-10, UIA-11, UIB-8, UIB-12, CTL-11, CTL-13,
  HST-6 to HST-9, HST-11, SMP-06 to SMP-08, SMP-10, OPS-8, OPS-9,
  DKR-7, DKR-8, ENG-8.

## Phase 5: refactoring (after phases 1 to 3, two chains that share no files)

Engine chain, in order:
1. Extract the five near-identical admin read handlers and ten read
   handlers into one helper (they have already drifted). ENG-9, ARC-05.
2. Split `engineMain` (one function, lines 227 to 2611) into a state
   class plus fleet, sync, actions and reads; remove the
   `case EngineRequest()` catch-all so the compiler checks
   exhaustiveness. ENG-11, ARC-05.
3. Split `protocol.dart` (7,959 lines): payload families into
   `engine/protocol/*.dart` first, then `part` files for the 75 requests
   and 68 events. Public API unchanged. ENG-10, ARC-06.
4. `docker_router.dart`: one in-flight bookkeeping and one backoff.
   DKR-11.
5. `docker_plans.dart` calls klabautermann_docker's eight mutation
   endpoints instead of rebuilding paths; delete unused `async*`
   endpoints. ARC-09, DKR-6.
6. `commands.dart` and `sampling_scheduler.dart` splits. ARC-13, SMP-14.

App chain, in order:
1. `panel_kit.dart`: one notice widget (three copies today), shared
   header-over-table layout and `_wideWidth` (declared in nine panels).
   UIA-05, UIA-06, ARC-04.
2. One Docker list scaffold; networks and volumes panels are about 450
   identical lines each. UIB-6, ARC-04.
3. `DockerController`: one `_ViewWatch` replaces five copied watch
   blocks, then split the file. CTL-07, ARC-03.
4. One request-correlation helper instead of six hand-rolled copies
   beside `EngineReads`; the "newest read wins" mixin used in its 14
   hand-written places. ARC-07, CTL-12, UIA-09.
5. Split `monitoring_controller`, `overview_panel`, `containers_panel`,
   `jobs_panel`, `processes_panel`, `log_view`. CTL-08, UIA-08, UIB-7.
6. Remove dead code: unreachable inspector shell, engine-restart
   scaffolding, test-only `retractServerPrefs`, 15 barrel names with no
   user, dead helpers. UIB-10, CTL-14, SMP-12, ARC-02, OPS-10.

Suite-level (touches the other apps, separate PRs):
- `editor_strings.dart` (927 lines) is identical in Klabautermann,
  Poltergeist and Planchette. ARC-08.
- Candidates for shared packages: `PersistedSetting`, serial write tail
  (four copies), shell-quote scanner (three copies), ssh_config
  resolver. ARC-14, ARC-15, SMP-13.

## Phase 6: tests, CI, docs

- CI: `--enforce-lockfile` on every Klabautermann resolve; pin the
  pure-Dart job to Flutter 3.47.2's Dart instead of `sdk: stable`;
  install and assert the real-shell matrix (mksh, BusyBox ash, getfacl,
  crontab, openssl) so a missing shell fails instead of skipping.
  QA-04, QA-05.
- Tests: make `shell_sampler_test` accept a host with systemctl but no
  running systemd; remove wall-clock assertions; fill the gaps named in
  ENG-14, OPS-11, DKR-12, UIB-13, ARC-17; align the app's analysis
  options with the packages' async and cast lints. QA-02 **[R]**, QA-09,
  QA-10.
- Native: port Séance's quit-confirmation handling into the copied
  settings-window runners (a quit question can open behind the Settings
  window) and update `SHARED.md`. ARC-01, QA-07.
- Docs: INSTALL.md says the app never updates itself, but it checks
  releases and installs APKs on Android; AGENTS.md still states
  pull-only (D14) as live; CHANGELOG claims anacron jobs that no UI
  shows; STATUS lists pin publication as waiting. QA-01, QA-03, SMP-11,
  ARC-02, QA-06, ENG-12, ARC-10, ARC-11, QA-11, QA-12.

## Decisions (owner, 2026-11-24)

1. Quit while locked: stays as built (the guard answers quit). UIB-4 is
   declined.
2. Anacron jobs (JOB-04) and sockets (SVC-10): build the screens.
3. Engine death: the app restarts the engine and says so.

## Suggested order

Phase 1 as one chain (steps touch `engine_isolate.dart`). Phases 2, 3
and 4 in parallel, one PR per row. Phase 5 only after phase 1 merges,
because the engine split rewrites the same file. Phase 6 any time; the
CI rows first, since they protect everything else.
