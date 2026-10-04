Widget-render captures (rootless container — native capture unavailable;
RepaintBoundary rasterization harness `test/ui/panes/scratch_capture_test.dart`,
uncommitted scratch), 1180x760 logical px, DPR 1.0, fixed clock 2026-09-15,
identical scripted engine lanes and theme. Labeled captures, NOT native QA.

Head: poltergeist/m3-panes-v1-foundation (pre-push working tree; the
before state is origin/main b317253's placeholder panes — no captures
exist for it because the placeholder surface shipped none).

- local-both-panes.png — both panes browsing the local home through
  openLocalChannel: path bar with clickable segments (left pane focused,
  accent-colored), directory-first rows with kind glyph, size, mtime,
  cursor row highlighted in the focused pane, pane footers with counts.
- remote-connecting.png — left pane local; right pane connecting to
  web.example.com (spinner + "Connecting to…" before the channel opens).
- remote-connected.png — right pane browsing /srv/home through the
  remote browse channel (server glyph in the path bar).
- remote-error.png — the notFound taxonomy sentence + engine diagnostic
  + Retry over the cached listing (right pane).
- remote-connection-lost.png — the 02 §2.7 banner over the dimmed cached
  listing with the Cancel affordance.

Checksums: SHA256SUMS.txt (relative to this directory).
