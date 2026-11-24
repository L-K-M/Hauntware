# Wave 7 rules: Klabautermann review plan

Read WAVE4.md in this directory first; it applies except where this file differs.

- Plan: ../klab-review/PLAN.md. Reports with line references, scenarios and proposed fixes: ../klab-review/r1-engine.md to r10-qa.md. Read every finding your brief names in its report before touching code, and confirm it is still real on current main. A finding that does not hold is DECLINED with file:line evidence, not fixed.
- Owner decisions: DECISIONS.md here (last block). Earlier declined items: declined.md.
- Work in the worktree and on the branch your brief names, cut from the latest origin/main. Other wave-7 agents work in parallel; edit only the files your brief owns. If a fix needs a file another agent owns, DEFER that part and say so.
- Every bug: regression test first, watch it fail, fix, watch it pass. Report the red and green evidence.
- Commit trailers, exactly:
  Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01QL5eJdQfAjRKx33g8tmbGi
  Author and committer `Claude <noreply@anthropic.com>`. No model name anywhere else.
- Protocol changes: bump the protocol version as the existing code does, keep protocol types plain data, and run `dart run tool/protocol_guard/bin/check.dart` from the repo root.
- New user-facing strings go in the ARB files; regenerate l10n the product's usual way; never commit a blank-line-only diff in app_localizations_en.dart.
- Format only files you changed (`dart format <file>`); CI now format-checks packages and the app. Never `pkill -f`. Resolve dependencies one at a time.
- Add one CHANGELOG line per user-visible fix under Unreleased in klabautermann/CHANGELOG.md (append at the end of the fitting list to limit conflicts). Do not edit docs/STATUS.md; put its sentences in your report.
- Validate: `dart analyze --fatal-infos` and the full suite of each pure-Dart package you changed (from klabautermann/); `flutter analyze` and the whole `flutter test` once for the app if you changed it; `scripts/check-workflows.sh` if you touched workflows or scripts. Known local-only failure: klabautermann_host shell_sampler slow-program tests (no systemd here).
- Push and open ready PRs as WAVE4.md says (at most 2, each a coherent group; PR body ends with the two attribution lines). Do not subscribe and do not merge. If push or PR creation is denied, stop and report the exact denial.
- Report to impl-<short>.md here: per finding FIXED (sha, test, red/green), DECLINED or DEFERRED; checks run with real results; STATUS sentences; anything noticed. Remove your worktree. Final reply under 250 words.
