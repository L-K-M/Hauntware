Widget-render captures (rootless container — native capture unavailable;
matchesGoldenFile harness), 1180x760 logical px, DPR 1.0, identical
scripted connect facts (demo.example.com:22, agent auth) and theme.

- before.png: origin/main 9c33204 — the demo listing view after a
  successful connect, no probe wiring.
- after.png: this PR head — same flow; the live probe status dot renders
  beside the app bar title (green, the fake engine's online snapshot).
