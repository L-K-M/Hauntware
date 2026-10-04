# AGENTS.md

Hauntware contains Planchette, Séance and Poltergeist with one version and
release cadence. Product-specific architecture and native setup remain in
each subtree's `AGENTS.md`; shared library implementations are never copied.

## Layout and toolchains

- `planchette/`: pure-Dart core, shared Flutter editor/UI/desktop packages,
  three-platform editor application.
- `seance/`: pure-Dart protocol/core/server, five-platform SSH application,
  vendored xterm and PTY implementations.
- `poltergeist/`: pure-Dart transfer/sync packages, five-platform application,
  live benchmark/tooling and immutable historical M0 evidence.
- Root `pubspec.yaml`: suite version and release-tool dependencies, not a
  Flutter workspace. Each product keeps its own pure-Dart workspace.

Use Flutter 3.47.2 and its bundled Dart (SDK constraint 3.12+), Python 3,
SQLite for server tests, and each target's native build tools. Shared packages
use relative paths. Do not resolve dependencies concurrently or use Flutter's
unsupported `--directory` option.

## Commands

```bash
scripts/test.sh dart
scripts/test.sh flutter
scripts/build.sh --check
scripts/build.sh planchette
dart run tool/release_version/bin/release_version.dart check
python3 scripts/check-history.py
scripts/check-workflows.sh
```

Use explicit package paths for direct Dart analysis/tests; a recursive bare
command can discover Flutter packages. Resolve project workspaces before apps
and run each standalone Flutter/tool command in its own directory.

## Boundaries and preserved state

UI uses host services; shared document/UI packages remain host-neutral.
Poltergeist consumes the shared SSH/protocol implementation through its core
barrel. Preserve application IDs, keychain names, wire formats and user data.
Native platform folders carry reviewed identities and compatibility fixes.

All owned package/app versions follow the root suite version. Vendored
`third_party/` versions/licenses and `poltergeist/docs/evidence/m0/` plus
`M0-DARTSSH2-REPORT.md` retain their original identities. The legacy
`poltergeist/tool/bench` forwarding package is live tooling, not frozen data.

`docs/history/source-refs.json` records original source refs and tag bytes.
Pre-import commits use original root paths; later commits use product prefixes.
History-only parents preserve rejected code without enabling it. Do not
squash the initial migration PR: original source ancestry must reach main.

## Releases and review

Only root `scripts/release.sh` cuts suite releases through `lkm-release`.
Child release scripts forward to root. One tag builds all 13 clients and the
sync server; publication follows every gate and artifact/checksum validation.
A release is a separate explicit task. Do not cut tags during migration.

CI preserves native macOS fixtures, required real Linux PTY verification,
Poltergeist SSH/server integration, import/protocol/license/local-dependency
guards and historical benchmark validation. Keep main CI runs uncancelled.

The first migration PR introduces the canonical review workflow, so its base
cannot run that workflow. Obtain an independent local review and disclose the
automation gap. Later PRs use GLM. Follow the shared stopping rules below;
review severity labels require primary evidence, not automatic acceptance.

Native macOS data/keychain, mixed-monitor and real-device flows remain manual
checks where the product notes say so. Automated compilation is not a device
smoke test. Retain original repositories and data; sandbox rollback requires
deliberate reconciliation of support trees and matching vault/key backups.

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
