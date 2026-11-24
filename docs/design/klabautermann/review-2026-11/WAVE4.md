# Wave 4 rules (post-#709), supersede AGENT-RULES.md where they differ

All take-over PRs are merged. Open PRs now: #751 (seance/sqlite3-3x: sync server, Dockerfile, CI build steps) and #752 (seance_core remote_process.dart). Avoid those files.

- Work in your named worktree on your named branch from latest origin/main.
- Read AGENTS.md (root + product) and the review reports named in your task (in this directory) for each item's details; verify each item is still open on current main before working on it (several may already be done). Skip done ones and say so.
- Bugs: regression test, observe failing, fix, observe passing. Dedup: move to the shared package, delete copies, keep behavior; tests move with code.
- Commit trailers (exactly):
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01QL5eJdQfAjRKx33g8tmbGi
  Author and committer `Claude <noreply@anthropic.com>`. No model names anywhere else.
- Validate: analyze + tests for every touched package/app (explicit paths, sequential pub resolution), `dart run tool/import_guard/bin/check.dart` and `dart test tool/import_guard/test` from repo root when imports/packages change (resolve all packages first), `scripts/check-workflows.sh` after committing, l10n contract tests when ARB files change.
- Then push `git push -u origin <branch>` and open a ready PR:
  gh api repos/L-K-M/Hauntware/pulls -f base=main -f head=<branch> -f title='<imperative title>' -F body=@<file> --jq .number
  Body: what and why per item, item IDs, validation, anything unverified; end with

  🤖 Generated with [Claude Code](https://claude.com/claude-code)

  https://claude.ai/code/session_01QL5eJdQfAjRKx33g8tmbGi
- Large scope: prefer one PR per coherent group; if the work is large, split into at most 2 PRs (second branch name = <branch>-2) rather than one huge diff (the reviewer times out on big diffs).
- Write a report to impl-<short>.md in this directory (item, status DONE/SKIPPED-already-done/DEFERRED with reason, commits) and remove your worktree at the end.
- Final reply under 250 words: PR number(s), head sha(s), items done/skipped/deferred, checks run, anything unverified.
