# AGENTS.md: working guide for Klabautermann

Read this first. It captures what isn't obvious from the code: how to get a
toolchain in a fresh environment, how to build/test each piece, and the
conventions this repo family shares.

Klabautermann is an agentless fleet manager for servers and Docker over
SSH, the fourth Hauntware product beside Séance, Planchette and
Poltergeist. The architecture is normative and lives in
[../docs/design/klabautermann/](../docs/design/klabautermann/). Start with
`03-ARCHITECTURE.md`, section 2 (the decision log), and follow the
milestone plan in `04-IMPLEMENTATION.md`, section 13. Current status and
the open manual checks live in [docs/STATUS.md](docs/STATUS.md).

## Repository layout

```
pubspec.yaml              pub WORKSPACE root — members are the pure-Dart packages
packages/
  klabautermann_host/     pure Dart — HWS/1 sampler protocol, collectors,
                          parsers, snapshots (no SSH, no dart:io)
  klabautermann_docker/   pure Dart — Docker Engine HTTP/1.1 client, models,
                          compose (no SSH, no dart:io)
  klabautermann_core/     pure Dart — the D18 engine isolate, its plain-data
                          request/event protocol, orchestration over
                          seance_core
app/
  klabautermann_app/      Flutter client — NOT a workspace member (it needs
                          the Flutter SDK; members must not)
test/integration/         the sshd fixture (Compose files, run.sh) and the
                          contract tests of it and of the CI jobs that run
                          it (03 §11.3, D53)
docs/STATUS.md            what's done / tested / still open
media-sources/            the owner-supplied master icon
```

The layout deliberately mirrors the siblings' shape (`packages/` + `app/`),
so knowledge and tooling transfer both ways. Shared implementations are
never copied into Klabautermann; the app reaches `seance_core` types only
through `klabautermann_core`'s curated barrel (03 §3.2), and only behind
`show` lists.

## Build & test

Requires the Dart SDK (3.12+) for the pure-Dart packages and Flutter 3.47.2
for the app.

```bash
# Pure-Dart packages, always with explicit paths (a bare `dart test` at the
# repo root tries to resolve the Flutter app and fails without Flutter)
dart pub get
dart analyze packages/klabautermann_core
dart test    packages/klabautermann_core
dart test    test/integration
# The sshd fixture and the engine's tests against it (Docker with Compose,
# OpenSSH's client tools, util-linux flock); it tears everything down
# when it exits
test/integration/run.sh

# Flutter app
cd app/klabautermann_app
flutter pub get && flutter analyze && flutter test
```

CI (`.github/workflows/ci.yml` at the repository root) analyzes and tests
the workspace packages and the app on every PR, and its
`klabautermann_client` job builds all five clients with release launch
checks, Linux packaging and the macOS fixtures. No release job ships
them before M4 (decision 16).

On macOS, after `flutter build macos` (or with `FLUTTER_ROOT` pointing at
an SDK with its macOS release engine cached), `scripts/test-macos-keyboard.sh`
and `scripts/test-macos-accessibility.sh` run the native keyboard and
accessibility fixtures modelled on Séance's against the runner's
`KlabautermannFlutterViewController`, copied from Séance and ledgered in
[docs/SHARED.md](docs/SHARED.md). Neither launches the app or touches user
data; `--stock-engine` runs the stock controller and must fail. Rerun them
after every Flutter upgrade: both fixes rely on private engine selectors.

`scripts/bench-frame-timing.sh` builds the app in profile mode for the
Linux desktop and runs spike S5's frame-timing test
(`app/klabautermann_app/integration_test/frame_timing_test.dart`) under
`xvfb-run`; it needs the GTK toolchain the Linux client builds with, and
its software-rendered numbers are provisional (`docs/evidence/s5/`).

## Conventions

- The product name is **Klabautermann**, plain ASCII everywhere a file
  name or bundle identifier appears (Séance's codesign lesson). Identities
  are fixed (03 D38, 04 §12.3): Android application id and Linux/Flatpak id
  `ch.lkmc.klabautermann`, Apple bundle id `ch.lkmc.klabautermannApp`,
  Linux binary `klabautermann` reporting WM_CLASS `Ch.lkmc.klabautermann`,
  Windows `klabautermann.exe` with `CompanyName` `ch.lkmc`, keystore and
  settings keys under the `klabautermann.` prefix.
- All SSH, sampling, parsing, Docker, sync and rule evaluation run in one
  engine isolate (D18); the UI sends plain-data requests over it. Engine
  protocol types carry no function-typed fields and no `seance_core` or
  dartssh2 types. The protocol guard enforces this once the engine
  directory is registered in `tool/guards.yaml`.
- Pull-only from the start (D14): nothing the app sends may push or write
  catalog records; a widget test guards it.
- Committed `ci-release.jks` and `key.properties` are a deliberately
  public debug-grade CI identity (the same tradeoff the siblings made):
  upgrade continuity, not publisher authenticity.
- Commits and docs carry no model identifiers.

## Gotchas inherited from the siblings (they will bite here too)

- **`dart test` / `dart analyze` with no path** at the workspace root will
  fail once the Flutter app exists ("requires the Flutter SDK"). Always
  pass explicit package paths.
- The Flutter app must stay **out** of the root `workspace:` list; it
  path-depends on the workspace members instead.
- **`dart test` reads `dart_test.yaml` from the directory it runs in.**
  CI and `scripts/test.sh` run the suites from `klabautermann/`, so a tag
  or timeout a package declares must also be in `klabautermann/dart_test.yaml`.
- **`pkill -f <name>` kills your own shell** when the pattern matches the
  bash command line running it. Kill by PID.
- **file_picker ≥11 breaks APK builds** on AGP 9+ unless Kotlin is
  re-applied to that subproject (see Séance's `android/build.gradle.kts`
  workaround and flutter_file_picker#1973).
- macOS: the restricted `keychain-access-groups` entitlement blocks ad-hoc
  signed builds from launching; use the legacy login keychain like Séance
  does. Release entitlements stay deliberately empty.
- Platform folders carry identity, icons, and entitlements; commit them
  once `flutter create` scaffolds the app.
- **The desktop settings window is a second engine** (Séance's lesson,
  D32): `main` gives it the settings window's app before `settings.json`
  opens and the engine isolate starts, and it reaches the app only over
  `klabautermann/settings_link` through `ghost_desktop`'s link engine. A
  new setting is a `SettingsLinkMethod` and a snapshot key in
  `lib/services/settings_window/`, never a controller or store in the
  window's isolate. The runners (copied from Séance, docs/SHARED.md) hide
  the window on close and never destroy it while the app runs: on Linux,
  disposing a second engine terminates the EGL display both share.
- **The macOS main window starts hidden** (03 §10.2): its runner keeps it
  invisible until `restoreMainWindow` (`lib/services/window_state.dart`)
  has placed it, and the integrated titlebar goes in before that. Anything
  that throws or hangs in `main` before the restore leaves the app
  without a window on macOS. Both run only in the app's engine, after the
  settings-window branch.
- **Menus are a rendering of the command registry** (03 §10.2,
  `lib/ui/menus/`): a new menu item or app shortcut is an `AppCommand`
  with a menu placement, never a native item. `PlatformMenuBar` replaces
  the storyboard's menu on macOS, so `MainMenu.xib` items do nothing.
  Register only commands with a real action; a toggle needs the
  `klabautermann/menu_checks` peer (Poltergeist's `MenuChecks.swift`).

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Writing the code is not finishing the task. A task is finished when
  its changes are merged to main through a PR that passed CI and review,
  or when the user explicitly accepts a different end state.
- Start every task on current code. Fetch first, then cut the task
  branch from origin/main — never from a stale local branch or an old
  checkout. To continue existing work, rebase or merge the latest
  origin/main into it before editing. Never overwrite existing work to
  update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch cut from the latest origin/main and open a PR
   against main before reporting the task as done.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Reviewer context limits

The automated PR reviewer does not see the user's original prompt or
conversation. It may suggest changes that go against or beyond what the
user asked for. Do not implement such suggestions. Note each conflict and
report it to the user at the end of the thread.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Ending a task

- A task ends with its changes merged to main — not with code written,
  and not with a PR merely opened. An open PR is work in progress:
  monitor CI on the latest commit, address review findings per the
  stopping rules, and merge once the criteria are met.
- Never finish with uncommitted changes or unpushed commits in the
  worktree. Commit, push, and open or update the PR first.
- If a step is impossible (missing push access, CI failure, reviewer
  outage), report the exact blocker instead. Never present unreviewed or
  unmerged work as finished.
- Before finishing, confirm: the requested behavior is implemented
  without unrelated changes; relevant checks pass on the latest code;
  important review findings are addressed or rejected with reasons;
  deferred suggestions, remaining risks, and validation gaps are
  disclosed.
- The final response states where the work stands: branch, PR, CI
  status, review rounds completed, and whether it is merged.

<!-- shared-rules:end -->
