> Note: this PR continues #78 from the identical head after GitHub stopped firing pull_request CI runs on that PR number (only the review workflow ran on every push; the full triage record below is #78's, unchanged).

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



## Review round 9 triage (this PR)

**Applied:** a controller swap resets the grace/reveal bookkeeping (the old session's `_pastGrace` leaked into the new one, skipping its first anti-flash grace, and stale reveal markers suppressed the first scroll-to-top); the pane key table answers only the listing node itself — a focused descendant (path segment, cancel button) keeps its keys; the pane's single keys are plain presses only (Ctrl+Enter etc. belong to their binders); the path bar reveals its tail on first mount; AT activation opens the row (the cursor-set single click is a sighted-user convention; keyboards have Enter); the unmodified-key skip precedes the duplicate-chord diagnostics; chord dispatch reports run errors through the same channel as `_runCommand`.

**Refuted:** the connecting-spinner exclusion claim — the `ExcludeSemantics` condition keys on `controller.loading && graceVisible`, and `loading` is false during the mid-bind phases the spinner covers (no generation is outstanding until the first navigation issues), so the spinner is never silenced.

**Declined (records stand):** the English whitelist and demo-suite re-raises (rounds 2–8); the Esc-in-copy split (02 §2.8's exact sentence); the assert-only serverId check (an internal invariant — assert is the tool; a release throw would crash on a programming bug the assert already catches in every dev/test run); the engine-less `connectRemote` no-op (the shell wires the affordance only with a session; the guard is the correct behavior, not a swallow); the forward-slash Windows and equality-canonicalization location notes (open item 12 / the path-editor slice own them); the maybePop-veto and double-tap edge cases (MaterialPageRoute never vetoes here and the row dies with its route).


## Review rounds 10–11 triage

**Applied:** modified chords pass through to ancestor handlers (arrows/Home/End were still swallowing Ctrl+arrows after the plain-key contract landed — round 10); the STATUS open items adopt main's sibling numbering (13/14); the descendant-focus guard gates on `hasPrimaryFocus` (round 11 — the `identical(node, focusNode)` check compared the handler node with itself; `onKeyEvent` always passes the owning node, so a focused path-segment button still hit the pane table).

**Refuted:** the `_pendingRemote` clearing claim (`openLocalHome` and `detachRemote` both clear it — the binding-lifetime invariant holds); the ledger-anchor concern (the renumbering adopts main's already-merged numbering; no anchors reference the numbers).

**Declined (records stand):** the failed-bind phase (the phase+error pair is `retry()`'s router — tests pin the reconnect routing; changing the phase to `unbound` would strand retry with a null location); the probe-strings-in-main concern (the dot widget and its strings stay for the launcher slice, recorded in STATUS); the English whitelist and demo-suite re-raises; the scrim keyboard-focus note (the pane node's key table is gated; pointer input is absorbed).

Rounds 9–11 each carried exactly one small genuine fix among the re-raises; everything else is re-litigated with recorded reasons. Steady state per the owner's bar stands.


## Review round 12 triage

**Applied:** the empty-folder label hides while a listing is in flight (the first listing of an empty folder flashed the definitive emptiness claim before arrival — around the anti-flash grace the rest of the file enforces).

**Refuted (third time, same evidence):** the `num.clamp` compile blocker (the suite compiles and passes — Dart's static typing special-cases int receivers/bounds) and the semantics-test "cannot pass" claim (it passes in this suite and CI).

**Declined:** the standing re-raises (demo deletion, English whitelist, constructor-seam sweep, key regeneration — all covered by records above); the cancel-test resolution note (the held completer resolving post-assert is the stale-drop contract being pinned, and the controller cancels by generation, not by completing I/O).

Steady state stands: rounds 9–12 each contributed exactly one small anti-flash/keyboard-hygiene fix among re-packaged refutations and re-litigated declines. Merging on green CI.


## Review round 13 triage

**Applied:** idle Esc falls through to ancestor handlers (the pane swallows it only while it has something to cancel or retry); Backspace ignores key repeats like Enter (holding it must not race up the tree) and drops the dead `plainKey` re-check; a failed bind drops the inert server watch instead of pinning the engine's per-server stream until the next bind.

**Declined (records stand):** the assert-only serverId invariant (round 9), the settings.json single-writer concern (only `AppPreferences` writes it this slice; the probe store's removal is the recorded demo retirement), the standing re-raises (demo deletion, English whitelist), the scrim note (pointer absorbed, keys gated, semantics excluded since round 8).

Round 13 follows the rounds 9–12 pattern: one small genuine keyboard/watch fix among re-packaged declines. Merging on green CI per the declared steady state.


## Review round 14 triage (final review 34748291048)

**Applied (each red-first where observable):** `cancelRecovery` detaches an in-flight connect before dropping the server reference — the held open completing used to bind the cancelled server (red: phase ended `browsing` on the cancelled channel; green: unbound, stale channel closed, disconnect still recorded); a failed bind clears `_connectionStatus` with the watch, so a terminal failure no longer shows the reconnecting banner over its error surface (red→green); the connection-lost scrim's keyboard surface joins the pointer and semantics inertness — owned plain keys no longer act on stale entries under the banner (red→green: Enter used to navigate the dead channel); STATUS fixed where it overstated the sibling models as feeding the pane controller (it implements 02 §2.8 inline; each model's wiring rides its owning slice) and the open items renumber sequentially with cross-references repaired.

**Refuted with evidence:** the double-tap/mis-pop finding — three new observed-behavior tests against the real Navigator (rapid double-tap, mid-exit-animation tap at 100 ms, single tap) show the open fires once and the route beneath survives; the popping route's subtree is not reachable by the second tap, and the proposed `!popped` guard misreads `maybePop`'s boolean (`true` includes a vetoed pop — it is not proof a pop happened); the `openLocalChannel` re-declaration on `AppEngine` (it already inherits it — `AppEngine implements PaneEngineLanes`); the semantics-exclusion and first-mount/controller-swap path-bar re-raises (both landed in round 9 — the `initState` seed and the `didUpdateWidget` reset); the `loading`/`_loadingActive` dedup and the remaining test-hygiene and comment-wording minors (stabilization: no optional cleanup).

**Declined (records stand):** the chord reordering (02 §8.3's table is the binding spec; the never-reserved secondary exists and delivery verification is recorded); the English fallback whitelist (eighth re-raise — the engine-summary precedent); the demo-suite deletion (tenth re-raise — the production code is deleted in this PR); the pane-command session guard (routes swallow chord focus above the shell, toolbar pane-command double-taps are generation-guarded navigations, and no pane command mutates durable state non-idempotently); the post-dispose teardown-report guard (teardown reports are diagnostic and `_report` is side-effect-free after dispose).


## Review round 15 triage (summary 1210, full-PR at f75a219)

**Applied (each red-first):** retry on a severed browsing remote pane re-opens the channel and returns to the user's directory (`connectRemote` gained `initialPath`; red: the dead channel was re-listed and re-failed forever); the three authored English fallback sentences are gone from the controller — non-VFS faults now carry a typed `PaneFaultException` whose machine-sentinel message the view maps to three new ARB sentences (D20; the round's render-path trace confirmed the English reached the error overlay, so the prior engine-summary decline was wrong for app-authored copy — corrected here); the localization contract drops the three exemptions, and a widget regression pins the ARB sentence plus the sentinel never rendering; the error overlay is inert for owned keys and row semantics like connection-lost and post-grace dim (red: Enter navigated under the overlay); plain Backspace falls through on platforms where it is unbound (macOS), matching idle Esc; a dead status lane clears the last status instead of latching the reconnecting banner (red→green); the mid-animation pop probe now asserts the first tap fired (was `lessThan(2)` — vacuous on zero); the rows-without-open-seam negative asserts the row renders; the fake lanes consume local channels once and make scripted failures one-shot; the cancelled-bind regression also asserts no listing was fetched; the shell's one-command-session guard gains the demo suite's double-tap spawn regression; STATUS documents the demo-coverage mapping by successor suite (prompts → prompt_coordinator/engine_session/production wiring; teardown → engine_session + pane controller; probe #55 → probe_coordinator; spawn guard → shell guard; controller-specific races → PaneController bind-attempt/cancel/watch-drop regressions).

**Refuted with evidence:** the `num.clamp` compile blocker (fourth raise) — Dart special-cases `int.clamp(int, int)` to type `int` (verified with a standalone `dart analyze`/`dart run` snippet; the file analyzes clean and the suite compiles and passes); the probe single-writer concern — `ProbeSettingsStore` has zero construction sites in `lib/` (grep), so `settings.json` has exactly one writer (`AppPreferences`); the maybePop-boolean re-raise — rejected as written per the supervisor's note (`true` includes a vetoed pop; the observed-behavior tests already pin the reachable cases); the `bySemanticsLabel`-based exclusion claims — a framework-level probe showed that finder matches widget semantics config, not the live tree, so it cannot observe `ExcludeSemantics`; the widget-state assertion is the correct probe and is pinned.

**Declined (stabilization; records stand):** chord reordering (02 §8.3's table is the binding spec); the settle()-substitution and formatting-only test churn; the abstract-equality/alias/helper API polish on `PaneLocation` (open item 12 owns the type's future); the Dialog-chord EditableText guard and progress-line semantics (no text surfaces exist in this slice; the path-editor slice owns both); the forward-slash Windows path normalization (typed-input normalization is the path editor's seam); the SnackBar for the stale-row tap; the runtime-throw serverId guard (assert + single call site).


## Review round 16 triage (summary 1210's successor, on 4bcde93)

**Applied (red-first where observable):** the intended landing directory now persists across a FAILED reconnect — the `connectingRemote` retry branch passes the pending remote path, cleared only by a successful bind or unbind (red: the second retry landed on the bookmark root; green: on `/srv/www`); a cleanly closed status lane clears the banner like an errored one (`onDone`; red→green); the fault sentinel uses `fault.name` (no enum class-name leak); the UNC self-parent branches return the input verbatim so `\\server\` and `\\server\share\` are strict no-ops (pinned for both roots and the label helper); the fault→ARB mapping is pinned for all three variants through their real failure paths (connectionOpen via a non-VFS open failure, listFolder via a non-VFS listing throw); the accidental expect/finally join in the error-overlay test is fixed. Main (PR92) merged; STATUS reconciled surgically (item 16 keeps the closed record with the pre-#92 diagnosis as superseded history; the ancestor-rename follow-up renumbers with cross-references repaired).

**Refuted:** none this round — the single major and four minors were all genuine or cheap hardening.

**Declined:** nothing further; stabilization holds.


## Recovery audit, superseding earlier readiness claims

Head: `f38c97f` (main `36211a2` merged). #78 and #83 are CLOSED/unmerged predecessors, not separate completions. Their published summaries are GitHub-truncated; two historical 90-minute review cancellations remain gaps, not approval. Original dispositions remain above; corrections below supersede mistaken declines. The mixed-owner r17 test run is excluded.

### Complete edited review 34762960221 on a07601d

- **Apply, landing-path ownership:** a failed A reconnect followed by B listed A's `/srv/www`. Fresh runtime red before the bookmark guard; green afterward. Same-bookmark retry still preserves the intended path.
- **Refute, post-await clear:** actual HEAD calls synchronous `_issueNavigation`, not `await _navigate`. The new held-old-listing/newer-failed-bind/old-completion/retry test passes on unchanged a07601d and on recovery. It asserts actual `/new/path` navigation. No speculative guard added.
- **Apply, retry error assertion:** the recovered reconnect test now asserts `error == null`; it passes before and after the fix.
- **Refute, parent-watch degradation:** losing the parent loses proven rename detection, including rename/recreate. A metadata query on the recreated pathname does not restore that coverage. Keep #92 fail-closed parent/root teardown and #93 native/permission contracts; no core delta against merged main.
- **Defer, fake closeLane helper:** optional helper/API polish during stabilization.
- **Apply, STATUS references:** reconcile against main identities, not the proposed numbers. Linux overflow14, ancestor18, incident19 remain stable; pane location is20.
- **Refute, shutdown drain missing progress:** the complete loop takes fresh `_pendingCloses` batches, awaits them under `_DrainAbandoned`, removes the awaited batch including abandoned entries, and repeats for newly tracked releases. No hot-spin or early-ack defect established. Preserve #88/#90 regression suites.
- **Defer, shutdown timeout rename:** imported configuration/API polish, not this app PR.
- **Defer, lane import-cycle extraction:** Dart supports the cycle; no runtime defect. No speculative seam move.
- **Refute, missing `_DrainAbandoned` throw:** the drain's `onTimeout` throws it and distinguishes it from retirement errors. Comment-only clarification deferred.
- **Decline, delete supervisor close-timeout regression:** preserve independently requested proofs, including serving new opens while a release remains wedged.
- **Refute, supervisor shutdown/native-test concerns:** review itself found their parked-release and probe-cancel assertions correct. Tests remain unchanged and run in the core suite.
- **Refute, architecture overflow15 suggestion:** main's stable overflow ID is14. Architecture remains byte-identical to main.

### Additional required ownership audit

- **Apply:** red-first cancellation test showed an old `cancelRecovery` disconnecting a new bind for the same server. Guard the detached attempt after the await.
- **Apply, correcting old pop declines:** actual PopScope-veto and stale-callback/covering-route tests failed. Guard `route.isCurrent` before maybePop and require `!route.isActive` afterward. `maybePop == true` still is NOT evidence of a pop. Existing single/double-tap cases remain green.
- **Shared successor coverage:** `pane_session_lifetime_test` runs two pending connects through one production session/coordinator, FIFO trust prompts, independent channel release, sibling refresh after detach, exactly-once shutdown, and delayed listing completion across session replacement. Existing prompt-coordinator, trust, probe, keyboard, hidden-row, and diagnostic-localization suites remain. Demo deletion alone is not accepted as coverage.

### Verification and remaining gates

Local: app analyze + 548 tests; core analyze + 749 tests (16 platform/fixture skips); import scan; protocol scan + 51 protocol tests. All exit0. Full bounded output and explicit exits: `tasks/run3-task15-logs/recovery3/{app-analyze,app-tests,core-analyze,core-tests,imports,protocol,protocol-tests}.log[.exit]`. Red/green evidence: `controller-*`, `cancel-replacement-*`, `route-*`, `shared-session-*` in the same directory. The first shared-session harness stalled in real teardown awaiting a fake-zone future; corrected tests await/assert shutdown inside their widget zone.

All five inherited `tasks/run3-task15-captures/*.png` were inspected. They use Ahem glyphs and transparent backgrounds: geometry evidence only, not readable-text, native desktop, or install QA. Those QA gaps remain. No full-M3, native install, listing-I/O cancellation, watch wiring, or restored probe-driver claim.

Exact-head CI/native client gates and the new edited review remain pending. No merge-readiness claim until they complete. Hourly check-in `21cfcd39` remains armed; PR subscription tooling is unavailable.

## Recovery thread dispositions

All 90 actual PR84 threads fetched with pagination; no nested comment page remains. Each row below corresponds to one inspected thread. Historical descriptions above remain history; this audit supersedes incorrect pop and numbering declines.

- [1](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924523) **decline**: Internal invariant; config derives from this bookmark. Keep assert and single call site, not a release crash/silent return.
- [2](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924528) **decline**: No-engine panes deliberately show unavailable; shell registers no connect callback without a session.
- [3](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924533) **apply**: Runtime veto and covering-route tests were red. Guard route.isCurrent before maybePop and route.isActive after it; boolean suggestions are incorrect.
- [4](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924537) **apply**: Existing CommandChordScope skips unmodified activators before duplicate diagnostics.
- [5](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924539) **defer**: Comment/locale/path-contract polish; stabilization. Typed-path normalization remains with path editing.
- [6](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924541) **defer**: Comment/locale/path-contract polish; stabilization. Typed-path normalization remains with path editing.
- [7](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924542) **refute**: loading is false during channel-open phases; existing exclusion cannot hide the connecting spinner.
- [8](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924544) **apply**: Existing path bar initState/didUpdateWidget seed and reset the tail reveal.
- [9](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924547) **refute**: loading is false during channel-open phases; existing exclusion cannot hide the connecting spinner.
- [10](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924549) **apply**: Existing path bar initState/didUpdateWidget seed and reset the tail reveal.
- [11](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924553) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [12](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924556) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [13](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924560) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [14](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924563) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [15](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924564) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [16](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924569) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [17](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924572) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [18](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3997924576) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [19](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102238) **defer**: Equivalent loading predicates; consolidation is optional, not a correctness fix.
- [20](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102282) **decline**: Teardown failures remain diagnostic after disposal; reporting does not mutate pane state.
- [21](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102323) **apply**: Runtime veto and covering-route tests were red. Guard route.isCurrent before maybePop and route.isActive after it; boolean suggestions are incorrect.
- [22](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102396) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [23](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102475) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [24](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102504) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [25](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102526) **defer**: Comment/locale/path-contract polish; stabilization. Typed-path normalization remains with path editing.
- [26](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102548) **apply**: Reconciled by identity, not suggested numbers: main IDs remain cancellation12/raw-name13/overflow14/QuickSelect15/root16/prefs17/ancestor18/incident19; pane-location20.
- [27](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102572) **apply**: Reconciled by identity, not suggested numbers: main IDs remain cancellation12/raw-name13/overflow14/QuickSelect15/root16/prefs17/ancestor18/incident19; pane-location20.
- [28](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998102593) **apply**: Reconciled by identity, not suggested numbers: main IDs remain cancellation12/raw-name13/overflow14/QuickSelect15/root16/prefs17/ancestor18/incident19; pane-location20.
- [29](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350544) **refute**: AppEngine implements PaneEngineLanes; openLocalChannel is inherited and all app tests compile.
- [30](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350561) **refute**: _beginBinding and _releaseBinding cancel/null the prior watch before the new subscribe; rebind test checks ownership.
- [31](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350581) **defer**: Only SingleActivator/CharacterActivator are registered. Unknown activator policy is speculative API hardening.
- [32](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350644) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [33](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350676) **refute**: PaneController.navigate returns void; wrapping in unawaited would not compile.
- [34](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350692) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [35](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350712) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [36](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350723) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [37](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350759) **apply**: STATUS explicitly keeps cancellation12 and unwired models/watch; pane-location20 now qualifies bookmark-sourced raw paths.
- [38](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998350776) **apply**: STATUS explicitly keeps cancellation12 and unwired models/watch; pane-location20 now qualifies bookmark-sourced raw paths.
- [39](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647352) **decline**: Internal invariant; config derives from this bookmark. Keep assert and single call site, not a release crash/silent return.
- [40](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647387) **refute**: Dart specializes int.clamp(int,int) to int. Existing analyzed controller and runtime cursor tests establish compilation and behavior.
- [41](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647430) **refute**: Dart specializes int.clamp(int,int) to int. Existing analyzed controller and runtime cursor tests establish compilation and behavior.
- [42](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647492) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [43](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647538) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [44](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647594) **decline**: Null binding means a retired/no-op callback; no user action requires a new reported fault.
- [45](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647638) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [46](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647694) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [47](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647758) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [48](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647789) **refute**: Existing semantics test executes successfully; widget configuration finders do not prove the live exclusion tree. Overlay tests separately inspect exclusion and keyboard behavior.
- [49](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647838) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [50](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647870) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [51](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647911) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [52](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647935) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [53](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998647971) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [54](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3998648007) **apply**: STATUS explicitly keeps cancellation12 and unwired models/watch; pane-location20 now qualifies bookmark-sourced raw paths.
- [55](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213273) **defer**: Comment/locale/path-contract polish; stabilization. Typed-path normalization remains with path editing.
- [56](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213309) **apply**: Runtime veto and covering-route tests were red. Guard route.isCurrent before maybePop and route.isActive after it; boolean suggestions are incorrect.
- [57](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213354) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [58](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213387) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [59](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213408) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [60](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213443) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [61](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213469) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [62](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213497) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [63](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213532) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [64](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213548) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [65](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213574) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [66](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213618) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [67](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999213645) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [68](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999328852) **decline**: Internal invariant; config derives from this bookmark. Keep assert and single call site, not a release crash/silent return.
- [69](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999328874) **apply**: Existing cancel/status repairs remain; recovery adds red-first replacement-bind cancellation guard and reruns all status regressions.
- [70](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999328898) **apply**: Existing cancel/status repairs remain; recovery adds red-first replacement-bind cancellation guard and reruns all status regressions.
- [71](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999328916) **defer**: Equivalent loading predicates; consolidation is optional, not a correctness fix.
- [72](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999328939) **decline**: D21/02 shortcut table stays primary; never-reserved secondary and Tab remain. No shortcut-policy redesign here.
- [73](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999328957) **decline**: D21/02 shortcut table stays primary; never-reserved secondary and Tab remain. No shortcut-policy redesign here.
- [74](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999328973) **refute**: Pane-local ExcludeSemantics already excludes stale rows. BlockSemantics risks hiding the sibling pane; keep existing boundary.
- [75](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999328992) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [76](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999329005) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [77](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999329020) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [78](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999561756) **refute**: Dart specializes int.clamp(int,int) to int. Existing analyzed controller and runtime cursor tests establish compilation and behavior.
- [79](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999561774) **refute**: Dart specializes int.clamp(int,int) to int. Existing analyzed controller and runtime cursor tests establish compilation and behavior.
- [80](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999561792) **apply**: Existing cancel/status repairs remain; recovery adds red-first replacement-bind cancellation guard and reruns all status regressions.
- [81](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999561810) **defer**: Both sealed subclasses implement equality already. Additional abstract API requirements belong to location composition, item20.
- [82](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999561822) **refute**: A backslash can be POSIX filename data. Last-separator detection would corrupt such paths; existing paneSeparator pins the leading-slash rule.
- [83](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999561856) **defer**: Loading footer already announces the state. Additional progress semantics is optional presentation work.
- [84](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999561872) **defer**: Optional test/helper/formatting hardening; no confirmed behavior defect. Stabilization excludes cosmetic repair rounds.
- [85](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999561898) **defer**: Per-test temp cleanup remains worthwhile test-harness hygiene; no production leak. No unrelated cleanup during stabilization.
- [86](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999561988) **apply**: Reconciled by identity, not suggested numbers: main IDs remain cancellation12/raw-name13/overflow14/QuickSelect15/root16/prefs17/ancestor18/incident19; pane-location20.
- [87](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999745570) **apply**: Existing cancel/status repairs remain; recovery adds red-first replacement-bind cancellation guard and reruns all status regressions.
- [88](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r3999745615) **apply**: Existing UNC self-parent branches return the original spelling; pane_location tests retain strict no-op cases.
- [89](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r4000022613) **apply**: Reconciled by identity, not suggested numbers: main IDs remain cancellation12/raw-name13/overflow14/QuickSelect15/root16/prefs17/ancestor18/incident19; pane-location20.
- [90](https://github.com/L-K-M/Poltergeist/pull/84#discussion_r4000022631) **apply**: Reconciled by identity, not suggested numbers: main IDs remain cancellation12/raw-name13/overflow14/QuickSelect15/root16/prefs17/ancestor18/incident19; pane-location20.
