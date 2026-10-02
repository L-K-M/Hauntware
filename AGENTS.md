# AGENTS.md — working guide for Planchette

Read this first. It captures what isn't obvious from the code: how to get a
toolchain in a fresh environment, how to build/test each piece, and the
conventions this repo family shares.

Planchette is a desktop text editor (macOS, Windows, Linux) and the shared
editor foundation for [Séance](https://github.com/L-K-M/Seance) and
[Poltergeist](https://github.com/L-K-M/Poltergeist). The shared Flutter editor
also supports the hosts' mobile flows. Architecture and file-safety contracts
live in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md); verified results and limits
live in [docs/STATUS.md](docs/STATUS.md).

## Repository layout

```
pubspec.yaml              pub WORKSPACE root — members are the pure-Dart packages
packages/
  planchette_core/        pure Dart syntax, search, metadata, guarded file I/O
  planchette_editor/      Flutter controller and surface; outside the workspace
  ghost_desktop/          Flutter desktop window lifecycle (restore, track,
                          close) shared with Séance and Poltergeist; also
                          outside the workspace
app/
  planchette_app/         Flutter client — NOT a workspace member (it needs
                          the Flutter SDK; members must not).
scripts/                  build.sh, release.sh, package-linux.sh,
                          verify-android-version.sh
```

The layout deliberately mirrors the siblings' proven shape (`packages/` +
`app/`), so knowledge and tooling transfer both ways.

## Build & test

Requires the Dart SDK (3.12+) for the pure-Dart packages and Flutter 3.47.2
for the app and shared editor. Dev containers for this repo family ship **no
Dart or Flutter SDK** — see Poltergeist's AGENTS.md §1 for the exact install
incantations; everything there applies verbatim.

```bash
# Pure-Dart packages — always with explicit paths (a bare `dart test` at the
# repo root tries to resolve the Flutter app and fails
# without Flutter)
dart pub get
dart analyze packages/planchette_core
dart test    packages/planchette_core

# Shared Flutter package and standalone application
(cd packages/planchette_editor && flutter pub get && flutter analyze && flutter test)
(cd app/planchette_app && flutter pub get && flutter analyze && flutter test)

# Desktop app for this host, staged into dist/
scripts/build.sh
scripts/build.sh --install  # build + install the app for this host
```

CI (`.github/workflows/ci.yml`) runs Dart analyze+test on every push/PR on
three OSes, shared-editor/app analysis and tests on Linux, and release builds
on all three desktop platforms. macOS also runs native keyboard and
accessibility fixtures; Linux validates its installable packages.

## Releasing

`scripts/release.sh` (a stub over the shared
[release-tool](https://github.com/L-K-M/release-tool) engine) bumps the
`version:` in every pubspec in lockstep, keeps committed lockfiles and the
README version line in step, commits, and tags `v<version>` — pushing that
tag triggers `.github/workflows/release.yml`, which tests, then builds and
publishes the desktop app as the GitHub Release: Linux `.deb`, AppImage and
bundle for x64, plus macOS and Windows desktop bundles.

```bash
scripts/release.sh 0.2.0          # bump + commit, tag v0.2.0
scripts/release.sh 0.2.0 --push   # …also push branch + tag (CI then publishes)
```

The release script validates versions and keeps package, app and lockfile
versions in step. A release is a separate explicit task.

## Conventions

- The product name is **Planchette** — plain ASCII everywhere a file name or
  bundle identifier appears (Séance's codesign lesson: macOS codesign rejects
  accented file names). Identifiers follow the siblings' scheme: Apple bundle id
  `ch.lkmc.planchetteApp`, Linux binary/package name `planchette`, Linux
  GApplication id `ch.lkmc.planchette`. The packaged build reports X11
  `WM_CLASS` class `Ch.lkmc.planchette`; the case-sensitive class must
  match `StartupWMClass` in `scripts/package-linux.sh`.
- Keep new code matching the surrounding style: small focused files, doc
  comments that explain *why*, `analyze` clean before committing.
- Cross-repo work: change shared editor behavior here, then update both hosts
  to the same reviewed Git revision. Never copy or fork the shared editor.
- The core must not depend on Flutter or SSH; host adapters own remote
  checkout/upload state, localization, menus, windows and notifications.
- Commits include `Co-Authored-By: Codex <noreply@openai.com>` and the current
  `Codex-Session:` link. Do not put a model identifier in commits or code.

## Gotchas inherited from the siblings (they will bite here too)

- **`dart test` / `dart analyze` with no path** at the repo root will fail
  once the Flutter app exists ("requires the Flutter SDK"). Always pass
  explicit package paths.
- The Flutter app must stay **out** of the root `workspace:` list; it
  path-depends on the workspace members instead.
- **`pkill -f <name>` kills your own shell** when the pattern matches the
  bash command line running it. Kill by PID.
- **file_picker ≥11 breaks APK builds** on AGP 9+ unless Kotlin is re-applied
  to that subproject (see Séance's `android/build.gradle.kts` workaround and
  flutter_file_picker#1973).
- macOS: the restricted `keychain-access-groups` entitlement blocks ad-hoc
  signed builds from launching; use the legacy login keychain like Séance
  does.
- Platform folders carry identity, icons, and entitlements — commit them once
  `flutter create` scaffolds the app; `scripts/build.sh` refuses to
  substitute Flutter's stock output.

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
