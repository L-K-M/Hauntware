@AGENTS.md

# CLAUDE.md

Start with **[AGENTS.md](AGENTS.md)**, the full working guide (toolchain,
layout, conventions, inherited gotchas). The design plan is normative and
lives in [../docs/design/klabautermann/](../docs/design/klabautermann/);
read `03-ARCHITECTURE.md`, section 2 (the decision log) before writing app
code. Current status is in **[docs/STATUS.md](docs/STATUS.md)**.

Quick reminders:
- Analyze/test the pure-Dart packages with explicit paths, never bare at
  the workspace root: `dart test packages/klabautermann_core`.
- The app is `app/klabautermann_app` (Flutter); it is not a workspace
  member and reaches `seance_core` types only through the
  `klabautermann_core` barrel.

## Pull request babysitting

When you push a branch and open a pull request in this repo (or the user points
you at one), subscribe to it with `subscribe_pr_activity` immediately — don't
wait to be asked. Also arm an hourly `send_later` self check-in (webhooks don't
deliver CI successes, new pushes, or merge-conflict transitions). Then handle
review feedback under this policy:

### Respond to every round on its merits
- Triage each comment into exactly one of: **apply** (real bug or improvement),
  **decline with recorded reasons** (commit message and chat), or **refute with
  evidence** (official docs, actual CI runs, the code itself) when a claim is
  factually wrong.
- Verify factual claims against primary sources before acting on them. Never
  apply a change just to appease a reviewer.
- Never flip-flop: if an earlier round declined something for stated reasons,
  don't apply it later unless genuinely new evidence appears. Keep a running
  list of what was declined and why.
- Post a PR comment only when an incorrect claim would otherwise mislead a
  merge decision (e.g. "this won't compile"); otherwise let commit messages and
  chat summaries carry the record.

### Declare steady-state and stop when any of these hold
- Two consecutive rounds yield no valid, actionable findings (only nits,
  restatements, or self-answered "✅ fine" items),
- the reviewer re-raises items already declined with reasons, or contradicts
  its own earlier feedback,
- everything remaining is out of scope for the PR (pre-existing behavior,
  product decisions) — collect those as follow-up suggestions instead.

At steady-state: post a short scorecard in chat (what was real, what was
refuted, what's deferred), state that the PR is merge-ready, call
`unsubscribe_pr_activity`, and delete any pending self check-in triggers for
that PR. Ignore further automated review rounds after that point.

**Exceptions:** comments from human reviewers are never subject to the
steady-state cutoff — always address them. And always unsubscribe when the PR
is merged or closed, or the user says stop.

The number of tokens used to edit files is best minimized, all else being equal. Therefore, when it will not affect the end result, try to surgically edit a file rather than rewrite the entire thing.
