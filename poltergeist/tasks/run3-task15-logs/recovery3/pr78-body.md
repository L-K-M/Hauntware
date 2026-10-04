Run 3 task 15, attempt 2 — the M3 panes-v1 foundation slice (07 §3.4, lane A), unblocked by #77's `EngineClient.openLocalChannel`.

## What lands

- **Two-pane shell, real panes**: `WorkspaceController` (03 §6 foundation form: pane pair + active pane) drives two `PaneController`s in the M1 adaptive shell with its persisted splitter ratio. The placeholder panes are gone.
- **One VFS, both kinds of pane**: local panes bind through `openLocalChannel` (engine-owned `LocalFileSystem`, D8 — no dart:io in the pane stack); remote panes subscribe to `watchServer` **before** the channel open (03 §5's no-replay rule) and open the pool channel at the bookmark's `remotePath` (`/` = canonical home), on the one production session.
- **02 §2.8's listing machine, transition-for-transition**: optimistic location at issue, monotonic generations (never backward), stale answers dropped — errors included, verbs disabled over cached post-error entries, Esc-cancel restoring the last quiescent snapshot *including its error*. 09 §3 idioms throughout (dispose guards, bind-attempt counters, channel `identical()` rechecks after every await).
- **Honest latency**: 150 ms anti-flash grace over the dim / 2 px progress line / footer loading line / ✕ cancel; connecting state during remote opens; the 02 §2.7 connection-lost banner owning the single dim layer while reconnecting; inline taxonomy errors (ARB sentence per `RemoteFileErrorKind` + the engine's diagnostic + Retry) over the cached listing.
- **Keyboard-first**: arrows/Home/End cursor, Enter opens directories on Windows/Linux (macOS Enter stays the rename key), Backspace up, Tab swaps panes from inside a listing, Esc cancels — all scoped to the pane focus node (§8.2), so no global single-key hazard.
- **D21/D20**: `go.open`, `go.enclosing`, `view.refresh`, `pane.focusLeft`, `pane.focusRight`, `pane.swapFocus` registered, dispatched by `CommandChordScope` (dual macOS/Ctrl chords; unmodified keys excluded by design). All new copy in ARB.
- **Demo retired per plan** ("M3 replaces it"): controller/view/command/ARB/tests/wiring deleted. The interim Connections surface stays (M5 owns removal) and gains **Open in Pane** — the M3–M4 remote entry point, binding the active pane.
- **STATUS**: dated section + open item 12 (the `PaneLocation` type's 02 §2 home is core; core is closed to this slice, recorded).

## Deliberately left to their owning slices (recorded in STATUS)

Launcher/empty states (with the interim-list probe dots and a durable-id probe owner — probes have no driver now, matching shipped release behavior), tabs/pane toggle, path editing + history, view modes + the core §2.3 comparator + per-location prefs, §2.5 selection/type-ahead/filter toggle, row interactions incl. rename, §7.5 watching, §7.2 ScopedPathAccess, menus + keyboard-completeness invariant, scanner readdir depth (D9's constant already set), #77's empty-rootPath guard (core-side), the teardown-order swap (§7.5 slice).

## Validation

- Regressions observed **failing first** (`tasks/run3-task15-logs/regressions-failing-first.log`): 15 controller tests (the state machine), 15 pane-view widget tests (local + remote rendering through the seams, taxonomy + retry, anti-flash timing, Esc with no stale repaint, platform-conditional keys, Tab swap, banner), 7 shell tests (one-engine seam, chord targeting the focused pane, open-in-pane end to end), 2 Connections row tests.
- Full app suite **422 green**, `flutter analyze` clean; core re-verified untouched (analyze clean, 548 tests, +15 Docker-fixture skips). ARB regenerated.
- Rootless widget captures (5 labeled states, not native QA): `tasks/run3-task15-captures/` with PROVENANCE + SHA256SUMS.

No core change, no pin/lock change, no port (PORTS.md unchanged), no milestone-close claim.

## Review round 1 triage

**Applied (behavior fixes, regressions observed failing first):** connections controller now rebuilds on engine-session identity change (startup/s swap keeps live lanes); `verbsEnabled` phase-gated to browsing; grace-timer nulls itself on fire (a dead timer can no longer suppress the loading UI); rebind test asserts the previous server watch is dropped; error test proves the cached listing visible before snapshotting; the Esc test releases the held retry and asserts the stale drop; `openEntry` proves a symlink never navigates; `paneParentPath` keeps UNC share roots (and bare drives get their platform separator) their own parent; size formatting renormalizes after rounding (999999 B → "1 MB", never "1000 KB"); yesterday boundary uses calendar-day arithmetic (DST-safe); Shift+Tab keeps reverse traversal; Esc over an inline error retries; `_openBookmarkInActivePane` re-resolves the pane after the store await; the initial-focus callback no longer steals focus when focus sits elsewhere; `serverConfigForBookmark` fails fast on a missing identity (the old non-null contract, restored); `activePane` is a read-only getter with a membership assert; the chord layer asserts duplicate activators at registration; per-test temp support dirs; platform override set before the tree builds; engine fixture deduped; row-extent math single-sourced; path bar/footer heights follow text scale; `paneNoEngine` reworded in user terms.

**Refuted with evidence:**
- *Demo-test deletion findings (×4)*: the production code under test is deleted in this same PR per the plan's own instruction (07 §3.3's bullet record: "M3 replaces it"; app.dart's comment: "until M3 deletes this surface wholesale"). The durable subsystems keep their suites: the prompt coordinator (prompt_coordinator_test), the engine session/teardown (engine_session_test, production_engine_wiring_test), the probe coordinator (probe_coordinator_test). The deleted scenarios tested deleted code (the demo session's double-tap guard, its transcript replay buffer, its probe driving); the successor controller's lifecycle races are covered by pane_controller_test's generation/bind-attempt suite.
- *Disabled-chord doc wording*: the suggested doc line ("never falls through to inner scopes") inverted Flutter's focus precedence — a nearer scope always wins over the command layer. The applied doc + test pin the real guarantee: a registered chord (enabled or not) is owned relative to scopes farther from focus.

**Declined with reasons:**
- *ARB DateTime placeholders for paneDateToday/Yesterday*: only the relative branches would move — the absolute branch composes `yMd().add_jm()` at the call site, so this splits the date pipeline mid-slice; D20 is English-only at v1. Deferred to the localization pass (recorded in STATUS).
- *Grace-timer widget test*: the exact interleave (timer fires while loading is false, a new load starts before any build observes it) is unconstructible from the test surface — it needs a mutation between the fake-async timer flush and the frame build, a microtask seam that does not exist. Fix applied, verified by inspection; the normal grace paths stay pinned by the anti-flash tests.
- *DST boundary test*: this container's zone is fixed UTC (no tz switching); the applied calendar-day fix is correct by construction.
- *`./engine-session` in production_engine_wiring_test*: pre-existing pattern outside this PR's diff (the new suite uses a temp dir); left for its owning cleanup.
- *Lenient fake empty listings*: every listing in these suites is scripted explicitly; the empty default is the fake's documented shape.

**Test-only cleanups:** the fake's dead knobs (localOpenFailure/localChannels/remoteChannels/watches) were removed; `disconnects` stays (the new cancelRecovery-after-dispose test asserts it).


## Review round 2 triage

**Applied (behavior, failing-first where observable):** the banner's cancel is now sibling-aware — verified in the core manager that `disconnectServer` removes the per-serverId pool reference and closes that id's browse channels, so two panes on one server route cancel through a new `detachRemote` (own channel closed, pool left to the sibling; alone, the reference still drops and recovery stops) — with the two-pane test; a navigation landing under a stale scroll offset reveals the new listing's top (cancel-restores keep the place: the restored entries instance is unchanged); `verbsEnabled` requires a non-null location (the post-first-cancel state is pinned); arrow-up from no cursor selects the last row; Enter ignores key repeats; a backslash in a POSIX name never flips `paneParentPath`'s separator (UNC share roots and bare drive roots are their own parents); genuinely future mtimes render absolute; size/date columns scale with text and ellipsize; both scrims absorb (not ignore) interactions; rows expose `Semantics.selected`; the footer's loading label handles drive roots; the review connect binds the engine id structurally to the bookmark; `watchServer` docs reconcile the seeded-current/no-replay wording; tests pin the never-rejecting open contract, the enabled-chord happy path, the local-open root requests (`~`), the failed-navigation optimistic location, the new-server watch after rebind, degenerate path inputs, and the harness passes the shared navigator key everywhere; `paneLoadingFolder` carries a translator note (Esc stays literal); the Ctrl+Alt+arrows OS-reservation is documented at both activators; the item-11 closure pointer names its own section.

**Refuted with evidence:** the demo-suite deletion re-raises (rounds 1 decline stands — the production code under test is deleted with the surface per plan; the durable subsystems keep their suites); `holdRemoteOpen` "dead" (pane_view_test's connecting-state test sets it — the reviewer grepped one file).

**Declined with reasons:** the "Esc" placeholder extraction (02 §2.8 mandates the exact copy "Loading /var/www — Esc cancels" — translator note added instead); the ARB-side date formatting re-raise (round 1 defer stands — the absolute branch composes intl at the call site; the localization pass owns the pipeline); the controller's three fallback summaries as contract violations (they follow the M2 engine-summary precedent — `ServerStatus.detail` ships engine-authored English rendered verbatim by the Connections surface; the localization pass owns diagnostic summaries; the allowlist entry records the decision); `openLocalHome` onError wrapper (the never-rejects test pins the contract — a wrapper would be dead code); reporting the bookmark-not-found open branch (the row dies with its bookmark; a fault report would be noise — the list refreshes).


## Review round 3 triage

**Applied:** path-bar segments render root-first (they were reversed below the root — the click targets were right, the labels were not; an order assertion now pins it); `navigate()` derives the location kind from the binding, not the cancelled location (a remote pane after a cancelled first listing stayed remote — regression pinned); `paneLastSegment` tolerates augmented drive roots (`C:` → parent `C:\` longer than input) and trailing-separator roots; the reveal reset records the location only when the listing instance arrives (an optimistic issue/accept split across rebuilds no longer skips it); Tab ignores key repeats; the memoized pane listenable refreshes on controller swap — the late-session test caught the swap leaving panes deaf, fixed in the same round; rows own a per-row Material so ink feedback paints above the row color; size renormalization compares numerically; the banner column stretches its scrim; `_focusPane` is null-safe with a promoted local and no `!` on sibling nodes; `_cancelPaneRecovery` reports faults per the shell's idiom; `connectRemote` guards before recording the pending bookmark; `setCursorIndex` checks disposed; the workspace asserts distinct panes; the chord doc names the shift-only exclusion; the focus-claim guard drops the unreachable `!right.hasFocus` operand; empty-state punctuation matches its siblings; the late-session test moves the shared navigator key ahead of the first pump (a genuine in-place-update contract now).

**Refuted with evidence:**
- *"`EdgeInsetsDirectional.symmetric` does not exist and will not compile"* — it exists; `flutter analyze` is clean and CI compiled and ran the suite plus all five client builds on this code.
- *"Scrim can collapse to zero width"* — the banner sits inside `Positioned.fill`, which tightens both axes; a Column relays tight cross constraints, so the `Expanded` scrim fills regardless (the stretch is applied anyway as a structural belt-and-braces).
- *Demo-suite deletion re-raises (×3)* — rounds 1–2 declines stand (production code deleted with the surface per plan).
- *"Pane controllers are never disposed in pane_view_test tearDown"* — `WorkspaceController.dispose()` disposes both panes (see its implementation); the tearDown disposes the workspace.

**Declined with reasons:**
- *openLocalHome catchError re-raise* — the never-rejects test pins the contract (round 2); a wrapper would be dead code.
- *FakeAppBrowseChannel implicit-empty re-raise* — round 2 decline stands (documented fake shape; the new `localChannelRoots` assertion covers the home-anchor drift the reviewer names).
- *pane_controller_test manual dispose → addTearDown* — style with no behavioral effect today (fresh fakes per test; the controller owns no timers); the slice that adds timers owns its tearDown.
- *NumberFormat/locale for sizes* — v1 is English-only (D20); the numeric-rounding part is applied so the later locale formatter cannot break the loop; the localization pass owns presentation.


## Review round 4 triage

**Applied:** the remote-unbind paths (`cancelRecovery`, `detachRemote`, and the shell's sibling routing) key on the pending binding instead of the location — the post-first-cancel state and an in-flight connect can both stop recovery and unbind (regressions pinned; local no-op kept); the fake's disconnect fans out the disconnected state the engine emits, and the banner-cancel tap is covered end to end; focus nodes are session-independent (created in initState, kept across session rebinds — pane focus/activation survives the swap); the disabled-chord test's detector uses CallbackShortcuts (the bare Shortcuts mapping could never invoke its intent — the assertion was vacuous); the grace-timer self-null that regressed out of round 2's restructuring is restored; chord keys are pane-scoped (`pane.left.progress` etc.); all scaled dimensions go through `TextScaler.scale` directly (non-linear scalers); `go.open` guards a negative cursor; the unmodified-key skip covers `CharacterActivator`; the review connect derives `serverId` from the hoisted config (single source); `paneParentPath` collapses doubled separators in the parent; the connections callbacks are named; the banner cancel button follows the errorContainer pairing; `_Centered` uses theme typography; the harness's crossed `onCancelRecovery` wiring is fixed; the stale `demo.example.com` host renamed; the Ctrl+Alt delivery risk carries a rebinding TODO; STATUS labels the probe-dots gap as the deliberate temporary 07 §3.4 deviation (release-scoped no-regression, debug builds lose the dots until the launcher slice).

**Refuted:** none this round beyond the standing re-raises.

**Declined (re-litigated, rounds 1–3 records stand):** demo-suite deletion (×3 this round); `openLocalHome` catchError (×3 — the never-rejects test pins the contract); the English fallback-summary allowlist (×3 — the engine-summary precedent); the implicit-empty fake (×3 — documented shape); splitting the Esc hint out of `paneLoadingFolder` (×2 — 02 §2.8 mandates the exact copy; the translator note covers it).


## Review round 5 triage

**Applied:** the past-grace dim is inert for keyboard too (Esc/Tab stay live; Enter/Backspace/arrows/Home/End no longer act on stale entries — the primary-modality hole in round 3's pointer inertness); the connecting spinner joins the anti-flash grace (the grace now arms for mid-bind phases, which carry no outstanding generation — the reviewer's own precondition, verified and made it work); open-in-pane pops the Connections route so the opened pane is revealed; a bare UNC server is its own parent (`\` would be the current drive's root — a drive jump, not a no-op); one shared `paneSeparator` helper replaces the duplicated heuristic (leading-slash rule, so a backslash inside a POSIX name cannot flip it); duplicate chords `debugPrint` in release (assert stays debug-only by design); the watch's `onError` rechecks the bind attempt; `detachRemote` drops its dead post-release check; the error overlay caps its diagnostic at four lines; the connection-lost banner is a semantics live region; the stale-row open reports a `StateError` instead of dead-tapping; the review-connect comment records why the shared server id is safe post-review (D18: a reviewed endpoint blocks every pane on it — nothing live to sever); `serverConfigForBookmark` documents that its timestamps mirror the bookmark's edit times (intentional, so all callers derive one stable config).

**Declined:** the Ctrl+Alt secondary-default chord (02 §8.3's table is the binding spec — "menus and tests derive from it"; adding non-table chords is a plan change for the menu/shortcut-audit slice, tracked with the existing TODO plus Tab as the always-working fallback); the `onCancelRecovery` outer-pop re-raise (the route-pop now lives in the row action itself); the bare-drive parent no-op (`C:` in Windows semantics is the drive-relative *current directory*, not the root — augmenting to `C:\` is the correct canonicalization, and locations never carry bare drives since they come from engine-canonicalized listings).

**Closed the cycle:** the `openLocalHome` catchError re-raise (rounds 2–5) — the never-rejects contract is now documented at the unawaited call site per the reviewer's own alternative branch ("If it provably never throws, add a short comment documenting that contract").

**Refuted:** the `ensureSemantics` blocker — `find.bySemanticsLabel` enables semantics itself (it asserts the handle is created); the test passes against the real aggregated tree.


## Review round 6 triage

**Applied:** the bare-UNC guard moved before `lastSlash` (it was provably unreachable where it sat — `\\server`'s second backslash is at index 1, so `lastSlash` was never 0 — and the function still jumped to the current drive's root); `pane.focusLeft/Right` gain never-reserved `Ctrl+PageUp/PageDown` secondary defaults (resolves this PR's own rebinding TODO; the 02 §8.3 chords stay primary); the keyboard inertness gate uses the shared `_graceBusy` so the mid-bind phases count; the path bar reveals its tail on every location change (the deepest segment was invisible on overflowed paths — the bar's whole job per 02 §2.1); open-in-pane pops the Connections route *before* invoking the open (a synchronous dialog push would otherwise become maybePop's target, per the D18 review the doc itself names); Enter/Tab repeats are consumed by their owner instead of leaking to other handlers (Shift+Tab still traverses — 02 §8.2); row semantics no longer announce the name twice; the error overlay scrolls at large text scales and is a live region; the ARB relative-time placeholders document their locale-aware formatting contract; the disabled-chord test also proves the disabled command never ran; `unawaited` on the shared-channel detach.

**Refuted with evidence:**
- *The `num.clamp` compile blocker* — Dart's static typing special-cases `clamp` when receiver and bounds are all `int` (it types as `int`); the file analyzes clean, compiles, and runs on all five CI platforms.
- *"left/right PaneControllers are never disposed in pane_view_test tearDown"* — `WorkspaceController.dispose()` disposes both panes (its own implementation); the extra `addTearDown(engineless.dispose)` calls are double-dispose-safe because `PaneController.dispose` is idempotence-guarded.
- *Esc-during-connect override* — `cancelNavigation` guards on an outstanding generation (`_loadingActive()`), so Esc in the connect window is a no-op (loading is false before the first navigation issues), never an override; the failed-bind phase is not "stuck" — the view keys its surfaces on `error != null` and `retry()` routes on the connectingRemote+error state by design (pinned by the connect-failure regression).

**Declined (re-litigated, rounds 2–5 records stand):** the English fallback-summary whitelist (the engine-message precedent — `ServerStatus.detail` ships engine-authored English rendered verbatim by shipped surfaces); splitting the Esc hint out of `paneLoadingFolder` (02 §8.8 specifies this exact copy); the fake's implicit-empty listings; the demo-suite deletion.

**Declined (new, minor):** surfacing the stale-bookmark tap to the user (the report lands in the app error log; the row vanishes on the list's next load — a toast needs snack-messenger plumbing this slice's rows don't own); the forward-slash Windows-root separator mixing (typed-input normalization is the path-editor slice's seam — locations come canonicalized from the engine).


## Review round 7 triage

**Applied:** the busy-past-grace key gate consumes only the pane's own keys (arrows/Home/End/Enter/Backspace); unowned keys fall through to ancestors so app-wide chords stay live during slow listings; row semantics expose the tap action (`excludeSemantics` had stripped it — rows were audible but unactivatable); the stale listing leaves the semantics tree while the connection-lost banner owns the pane (`ExcludeSemantics` at the stack site, safer than `BlockSemantics` which would block the sibling pane painted earlier); open-in-pane awaits `maybePop` before the open (the pop is deferred past `willPop`, so a synchronous review push would have become its target); `dispose` reuses the single release path (dead duplicate deleted); the Esc test's released retry answers with a distinct entry so the stale-drop assertion discriminates.

**Refuted with evidence:**
- *The `CharacterActivator.alt` compile blocker* — `CharacterActivator` in this Flutter declares `alt` (framework source, `packages/flutter/lib/src/widgets/shortcuts.dart` — `final bool alt;`); the file analyzes clean and compiled on all five platforms.
- *The demo-survivor / main.dart-signature concerns* — no reference to any `SftpDemo*` symbol survives (the app compiles; its 452-test suite passes); `PoltergeistApp` no longer declares the removed parameters; `ProbeSettingsStore` is intentionally unconstructed (no probe driver this slice — recorded in STATUS), and only `AppPreferences` writes `settings.json` now, so the single-writer invariant holds with one writer.

**Declined (re-litigated, rounds 2–6 records stand):** the English fallback-summary whitelist (fifth re-raise; the engine-summary precedent — `ServerStatus.detail` ships engine-authored English rendered verbatim by shipped surfaces).

**Declined (new, minor):** Esc-during-bind cancel (02 §2.8 scopes this slice's Esc tier to navigation; a bind-hang escape hatch is a deliberate slice decision recorded for the follow-up); the watch `onDone` reset (the lanes interface documents non-terminating streams while the engine holds the id — a removed id's stream completion resets with the next bind, and this slice never removes bookmarks); `paneSeparator` bare-drive classification (canonical paths always carry separators; typed-input normalization is the path-editor slice's seam, recorded).


## Review round 8 triage + steady state

**Applied:** the review connect asserts `reviewConfig.id == serverId` (the invariant now fails loudly on drift instead of silently splitting engine state); the stale listing also leaves the semantics tree while the post-grace loading dim is active (AT activation bypasses hit testing — `AbsorbPointer` alone leaked, the same hole round 7's banner fix closed); the wiring tests scratch into a system temp directory instead of the checkout.

**Refuted with evidence:**
- *Both "compile blocker" claims (re-raises of round 6/7 refutations)* — `num.clamp(int, int)` types as `int` (Dart's special-cased static rule); `CharacterActivator.alt` exists in this repo's pinned Flutter 3.47.2 (`packages/flutter/lib/src/widgets/shortcuts.dart`: `final bool alt;` — quoted in round 7). The code analyzes clean, compiles, and its 452-test suite passes; CI built all five client platforms on these exact lines.
- *The semantics test "cannot pass"* — it passes in the same run (the finder drives the semantics pipeline in the test binding).
- *The `_statusWatch` leak* — `_bind`'s `_beginBinding` cancels and nulls the previous watch before every connect callback runs; the reassignment the reviewer flags replaces an already-cancelled subscription (the rebind regression asserts the drop).

**Declined (re-litigated, records stand):** the demo-suite deletion (ninth re-raise — the production code under test is deleted in this PR); the English fallback whitelist (sixth); the Esc-in-copy split (02 §2.8 specifies the exact sentence); `detachRemote`'s reset block (a different lifecycle point than `_beginBinding` by design); the sort comparator's `toLowerCase` (the placeholder comparator is replaced by the §2.3 core port in its slice).

**Steady state declared per 09 §7 and the owner's bar:** rounds 7–8 contain no confirmed correctness, security, or contract finding — only re-packaged refutations (compile claims disproven against the running toolchain), re-litigated declines (records above), and minor hardening (all applied). The PR is merge-ready.
