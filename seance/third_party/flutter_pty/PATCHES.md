# Séance's flutter_pty fork — divergences from upstream 0.4.2

This package is a vendored copy of [flutter_pty] 0.4.2 (MIT, see LICENSE),
as resolved by pub.dev — archive sha256
`c2f3b3160b519ac820fa3f6ef175361f2dfc52c557465643589542e9f229ad66`.
Upstream has no lifecycle API: once `pty_create` returned, the master fd,
both worker threads and the handle stayed allocated until process exit —
measured at +2 fds and ~16 MB of thread stacks per session in the app.
Séance needs `Pty.close()` for the local shell's tab teardown.

## Changes

All edits are marked `// Séance:` at the site.

- `src/flutter_pty.h`, `src/flutter_pty_unix.c`, `src/flutter_pty_win.c`:
  new `pty_close(PtyHandle *)` / `Pty.close()`. Unix: writes a byte to a
  per-handle self-pipe so the reader — which `poll()`s on the master and
  the pipe together — exits on its own and is joined before the master
  closes. That replaces `pthread_cancel`, which Bionic does not provide
  (Android NDK compile failure), and keeps the ordering safe: closing
  first could let a recycled fd number feed a stale read. Then the
  master closes (the kernel hangs up the child's session — SIGHUP to the
  foreground process group), both pipe ends close, the mutex is
  destroyed, the handle is freed, and the waitpid thread is joined on a
  detached reaper so the calling isolate never blocks on a still-running
  child. Windows mirrors it: `ClosePseudoConsole` is the hangup, both
  pipe ends close, worker threads are reaped on a helper thread.
- `src/flutter_pty_unix.c`, `src/flutter_pty_win.c`: worker-thread
  `*Options` blocks are freed by the thread that owns them; worker
  threads/handles are stored on the handle so they can be reaped. On unix
  the reader now exits its loop on the stop byte, an `EIO`/`EOF` from a
  dead master, or any `POLLERR`/`POLLNVAL` — the tail `free` covers every
  remaining exit path since no cancellation path exists.
- `src/forkpty.c`: the parent's copy of the slave fd is closed when the
  caller doesn't ask for it — upstream leaked one fd per spawn. Every
  error path now releases what it holds: `grantpt`/`unlockpt`/
  `ptsname_r`/slave-`open`/`fork` failures close the master (and the
  slave when already opened) instead of leaking both fds; `ptsname` was
  swapped for the thread-safe `ptsname_r`; and the child closes its
  inherited copy of the master before exec.
- `src/flutter_pty_unix.c`: a failed `execvp` in the child now `_exit(127)`s
  instead of falling through and running a second copy of the host
  process.
- `src/flutter_pty_unix.c`: the waitpid worker retries `EINTR` and only
  posts a real status — upstream reported whatever garbage `waitpid`
  left in `status` on error, which could fake a clean exit and suppress
  kill escalation. Thread-start failures (malloc/`pthread_create`) now
  kill and reap the child, close the master and pipe ends, free the
  handle, and return NULL instead of handing back a live-but-broken
  handle. The stop-byte write retries `EINTR` in `pty_close` *and* in
  the thread-start failure teardown — a lost wake would leave the join
  blocked on a reader still parked in `poll()` (proven by fault
  injection: an interrupted write without the retry hangs `pty_create`
  for good). Every synchronous reap likewise retries `EINTR` via a
  `reap_child` helper, or an interrupted `waitpid` would leave the
  killed child a zombie. `pty_error`
  returns the recorded message instead of NULL (upstream never wired the
  return), and the `winsize` passed to `pty_forkpty` is fully
  initialized so garbage `ws_xpixel`/`ws_ypixel` can't reach `TIOCSWINSZ`.
- `lib/flutter_pty.dart`: `Pty.close()`, `isClosed`, post-close guards on
  `write`/`resize`/`ackRead`, and `pid` captured at spawn so it stays
  valid after the native handle is released (`kill` still works).
- `lib/flutter_pty.dart`: `Pty.start`'s borrowed buffers — the argv and
  envp pointer arrays, every Utf8 string, and the `PtyOptions` block —
  now live in an `Arena` released when `pty_create` returns, on success
  and failure alike. Upstream freed only `options` and leaked the rest;
  that is the *Dart-side* heap (FFI allocator), a separate layer from the
  C heap inside the library. Ownership verified before freeing: on unix
  the child execs fork-copies, on Windows `build_command`/
  `build_environment`/`build_working_directory` copy into wide strings
  and `CreateProcessW` consumes them synchronously — nothing retains an
  `options->` pointer past `pty_create`. A throwing constructor now also
  closes both `ReceivePort`s (field initializers create them before the
  body can fail) and releases a partially-created native handle — a
  failed spawn used to leak the ports for the isolate's lifetime.
- `lib/flutter_pty.dart`, `src/flutter_pty_unix.c`, `src/flutter_pty_win.c`:
  `output` ends after the reader thread's last chunk, marked by a null
  message the reader posts as it exits. Upstream closed the output port
  as soon as the exit status arrived on the other port, dropping output
  the reader had not posted yet: sometimes a short-lived child's only
  line, always the output of a job that outlives the child. The Windows
  reader blocks until `ClosePseudoConsole`, so there `output` now ends at
  `close()` rather than at exit.
- `lib/src/flutter_pty_bindings_generated.dart`: `pty_close` entry added
  by hand, matching the shape `dart run ffigen --config ffigen.yaml`
  produces for the new header declaration.

## Deliberately not changed

- `ackRead` mode teardown: an ack-mode reader can park on the shared
  mutex where `poll()` never runs, so `pty_close` under `ackRead` hangs
  up but does not join/free. Séance never enables `ackRead`; doing the
  right thing there needs a different protocol upstream.
- The Windows backend is otherwise upstream-verbatim — including defects
  a review would call out: `CreateProcessW`'s `processInfo.hThread` and
  `startupInfo.lpAttributeList` leak per spawn (their frees are
  commented out upstream), every `pty_create` error path leaks the pipe
  handles/hPty it already created, and a hardcoded `Sleep(1000)` stalls
  spawn. Known residual: the Windows reader parks in `ReadFile` on the
  ConPTY output pipe — it relies on `ClosePseudoConsole` tearing down
  the conhost side to unblock, and thread reaping happens on a helper
  so a slow unblock never stalls the caller, but a truly stuck read
  would leave that thread outstanding. None of it is runtime-verified;
  the app refuses local shells on Windows, so these stay upstream bugs
  to fix there, not Séance patches.
- `waitpid` failure posts nothing to the exit port (upstream behaviour
  kept): a missing exit notification means "not proven dead", and
  callers must keep kill escalation armed — Séance's adapter does.
- Deliberately detached/`nohup` background jobs surviving a closed pty is
  standard terminal semantics, not a bug.

[flutter_pty]: https://github.com/TerminalStudio/flutter_pty
