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
  new `pty_close(PtyHandle *)` / `Pty.close()`. Unix: cancels and joins
  the reader thread (its `read()` is a cancellation point — closing the
  fd first would let a recycled fd number feed a stale read), closes the
  master (the kernel hangs up the child's session — SIGHUP to the
  foreground process group), destroys the mutex, frees the handle, and
  joins the waitpid thread on a detached reaper so the calling isolate
  never blocks on a still-running child. Windows mirrors it:
  `ClosePseudoConsole` is the hangup, both pipe ends close, worker
  threads are reaped on a helper thread.
- `src/flutter_pty_unix.c`, `src/flutter_pty_win.c`: worker-thread
  `*Options` blocks are freed by the thread that owns them; worker
  threads/handles are stored on the handle so they can be reaped. On unix
  the reader frees through `pthread_cleanup_push(free, …)` — a tail `free`
  would be bypassed by `pthread_cancel` unwinding, which is exactly the
  path `pty_close` takes.
- `src/forkpty.c`: the parent's copy of the slave fd is closed when the
  caller doesn't ask for it — upstream leaked one fd per spawn.
- `src/flutter_pty_unix.c`: a failed `execvp` in the child now `_exit(127)`s
  instead of falling through and running a second copy of the host
  process.
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
- `lib/src/flutter_pty_bindings_generated.dart`: `pty_close` entry added
  by hand, matching the shape `dart run ffigen --config ffigen.yaml`
  produces for the new header declaration.

## Deliberately not changed

- `ackRead` mode teardown: an ack-mode reader can park on the shared
  mutex outside any cancellation point, so `pty_close` under `ackRead`
  hangs up but does not join/free. Séance never enables `ackRead`; doing
  the right thing there needs a different protocol upstream.
- The Windows child-process attributes/thread-handle bookkeeping is
  unchanged beyond what `pty_close` needs; the app refuses local shells
  on Windows regardless.
- `waitpid` failure posts nothing to the exit port (upstream behaviour
  kept): a missing exit notification means "not proven dead", and
  callers must keep kill escalation armed — Séance's adapter does.
- Deliberately detached/`nohup` background jobs surviving a closed pty is
  standard terminal semantics, not a bug.

[flutter_pty]: https://github.com/TerminalStudio/flutter_pty
