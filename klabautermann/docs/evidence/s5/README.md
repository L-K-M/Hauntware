# Spike S5: engine budgets and UI frame timing replayed on one machine

Part 1 measures the engine side, part 2 (below) the app's frames.

## Part 1: engine budgets

Each `local-phone-*` and `local-ten-hosts-*` file is the output of
`klabautermann_core/tool/engine_budget.dart`, run from
`klabautermann/packages/klabautermann_core`:

| File | Command |
|---|---|
| `local-phone-aot.json` | `engine_budget --scenario phone --seconds 600` |
| `local-ten-hosts-core-2s-aot.json` | `engine_budget --scenario tenHostsCoreAt2s --seconds 120` |
| `local-phone-10000-lines-aot.json` | `engine_budget --scenario phone --seconds 60 --log-rate 10000` |
| `local-phone-jit.json` | `dart run tool/engine_budget.dart --scenario phone --seconds 300 --heap` |

`engine_budget` is `dart compile exe tool/engine_budget.dart`, the
ahead-of-time build a release app's engine runs as. Each run measured
after the default 10 s warm-up. They ran one after another on
2026-10-15 with Dart 3.13.2, the SDK of the installed Flutter, on
linux_x64 in a 4-CPU container (Intel Xeon at 2.10 GHz, kernel 6.18)
that other jobs shared; each file records the load average before and
after.

The runs used the harness as `cb1b7056` added it, before its review
fixes (from `88407c86` on), three of which touch its output. The
follow's stand-in now also holds a batch back while it would be the 21st
within a second (03 §10.1); the 50 ms beat alone let a late batch and
the next go a few milliseconds apart. Over 10 s of 10 ms steps with 2 ms
of jitter it sends 198 or 199 batches where the beat alone sent 200, so
the batch figures below would move by under 1 %. The last step now also
feeds the follow the lines due since the step before, which it left out:
ten lines at 1,000 a second when it runs on time, too few to show here,
and more when a loaded machine delays it. And the `ui` counts now
include samples by server, the servers profiled and the samples with
rates, which these files lack.

**These numbers are provisional.** A shared container is neither 03
§11.4's reference VM nor a phone. Device numbers and the UI frame p99
belong to the manual gate of 06 (part 2 below has provisional UI
numbers), and nothing here sets a budget.

### Method

- **Hosts.** Ten, taking the six platform fixtures of
  `klabautermann_host/test/fixtures` in name order, so `alpine-322`
  (2 CPUs) is host 0 and four platforms appear twice. The fixtures are
  hand-written (see their `SOURCE.md`). Every reply is framed before the
  clock starts, with each counter advanced at a fixed rate to the read's
  time, so the rates are real and the host's side costs nothing.
- **`phone`.** 03 §6.4's Phone column with one server open: `overview`
  every 10 s on nine hosts and `core` every 3 s on host 0, whose reply
  also serves its `overview` row. First reads are spread over each
  interval. **`tenHostsCoreAt2s`** is 04 §13 S5's load: every host reads
  `core` every 2 s.
- **Follow.** The four rows of `debian-12/journal.txt` (460 B a line on
  average; one has a byte-array `MESSAGE`, one a `null` one), cycled at
  1,000 (or 10,000) lines a second, handed over every 10 ms, decoded and
  split, parsed by `parseJournalLine`, resolved by `journalRecordFrom`
  and sent as `LogBatch`es on a 50 ms beat (03 §10.1: at most 20 a
  second). K26's follower does not exist yet; the stand-in holds at most
  one second of records and drops the oldest beyond that, counting them.
- **Engine time.** Wall time of the engine isolate's synchronous work:
  per tick from the reply's bytes to the last `SendPort.send`, split into
  framing (`HwsTickAssembler`), pipeline (parsers, rates, the protocol's
  values) and send (the isolate copy); per second, that plus the
  follow's parsing and batch sends (`busyMsPerSecond`). On an idle core
  it is CPU time. `eventsPerTick` is the engine events a tick produced:
  one sample for each stream its reply serves, so 1.27 for `phone`,
  where a `core` reply also serves its `overview` row, and 2.0 for
  `tenHostsCoreAt2s`.
- **Process CPU.** `utime + stime` of the whole process from
  `/proc/self/stat`, which also counts the receiving isolate, the timers
  and the VM's own threads (and, under JIT, the compiler).
- **Memory.** The resident set at the window's start, every tenth and
  its end. `--heap` also reads the isolate group's live heap after a
  forced full collection at the same marks but the end; only JIT has
  the VM service for it. Both include the harness's framed replies
  (`replayReplyBytes`) and its timing lists, which grow by two numbers
  per batch (40 a second).
- **Bytes.** `replyBytes` is what the host sends per tick, the figure 03
  §11.4's tick and 10-host budgets name, at the fixtures' sizes.

### What it shows

- **Phone, AOT, 600 s.** 740 ticks (1.23 a second), none skipped. Engine
  time per tick: 0.21 ms at the median, 1.10 ms at p99, 4.99 ms at most;
  at the median the pipeline took 0.14 ms, framing 0.04 ms and the send
  0.02 ms. The follow delivered 1,000.0 lines a second in 20.0 batches a
  second (50 records at the median, 113 at most), dropped none, and its
  parsing cost 10.7 ms a second. The engine was busy 12.2 ms a second
  (1.2 % of one core); the process used 22.8 ms of CPU a second.
  Replies were 433 to 469 B (`overview`) and 816 to 826 B (`core`),
  682 B/s for the ten hosts: the hand-written fixtures' sizes, not real
  hosts' (S2 measured a 1,227 B `overview` reply; K15, K28).
- **Memory.** The AOT phone run's resident set rose from 20.2 to 22.6 MB
  over 600 s. Under JIT the live heap after a full collection stayed
  between 23.04 and 23.30 MB for 300 s, against about 0.1 MB that the
  timing lists add in that time, so what the engine keeps does not grow
  with the lines and samples it passes on. The AOT rise is most likely
  the VM keeping pages, which the AOT runtime cannot show directly.
- **Ten hosts at 2 s, AOT, 120 s.** 600 ticks (5 a second): 0.24 ms at
  the median and 1.54 ms at p99, with the engine busy 13.9 ms a second
  including the follow. One tick took 63 ms in framing, against a
  framing p99 of 0.31 ms: most likely the loaded machine preempting the
  isolate or a collection. `core` replies ran from 601 to 1,225 B,
  4.7 KB/s in all.
- **10,000 lines a second, AOT, 60 s.** All 10,000 lines a second
  arrived in 20 batches a second (500 records at the median), none
  dropped, at 80 ms of parsing and 84 ms of engine time a second (8.4 %
  of one core); the resident set stayed between 54.3 and 55.0 MB. On
  this machine the follow has about ten times the headroom 03 §11.4's
  1,000 lines a second asks for.
- **JIT.** `dart run` took 0.75 ms per tick at the median and 2.89 ms at
  p99, three times the AOT figures, and was busy 18.0 ms a second. Its
  39 ms maximum may come from a forced collection, a compilation or the
  loaded machine; the run cannot tell which. Its resident set (367 to
  402 MB) is the JIT VM's.

### Not covered in part 1

- **SSH.** No dartssh2 decryption, MAC or window handling, which run in
  the engine isolate too (D18). Part 2's replay engine has none either;
  the integration tests reach it.
- **Slow collectors.** `procs` (up to 500 rows every 5 s while visible,
  03 §6.4), `fs`, `units`, `timers` and `cron` are not replayed; real
  captures (K28) size them.
- **Bigger hosts.** `core` replies here come from 2 to 16 CPUs. Per-core
  and per-disk rows grow the replies and the pipeline's work.
- **The UI side.** The receiving isolate only counts messages; what the
  app does with them is part 2's frame timing.
- **Cadences.** The phone schedule is this harness's reading of 03 §6.4;
  K22's scheduler decides the real one.

## Part 2: UI frame timing under Xvfb

`local-frame-timing-xvfb.json` is the report of
`klabautermann/scripts/bench-frame-timing.sh`, run from `klabautermann/`
with `LIBGL_ALWAYS_SOFTWARE=1` and `KLABAUTERMANN_EVIDENCE_DIR` set. It
was built from `54fc3d46`, with a clean working tree: the harness after
its review fixes, merged with `main` at `3fff564e`, and with the replay
engine answering log streams as K25b's router does. Later commits change
only this README and the report. The test started at 14:03 UTC on
2026-10-16, with Flutter 3.47.2, in the same kind of shared 4-CPU
container. Other jobs kept the 1-minute load average at 9.6 when the
test started and 9.3 when it ended; it read 12.1 when the app's build
started.

**These are not device numbers.** Xvfb has no GPU: Mesa's llvmpipe
rasterizes in software on the CPUs that the app, the replay engine and
the other jobs share. 03 §11.4's frame p99 stays a device measurement
with manual sign-off (06). CI's `klabautermann_frame_timing` job runs
the same script on main pushes and dispatch and uploads its report; it
gates nothing.

### Method

- **The app.** `app/klabautermann_app/integration_test/frame_timing_test.dart`
  builds `main.dart`'s controllers over `IsolateEngineClient.spawn` with
  the replay engine as its entry point and pumps the real
  `KlabautermannApp` in profile mode in the Linux runner's 1280 by 720
  window, the desktop shell.
- **The replay engine** (`package:klabautermann_core/replay.dart`, 03
  §11.4) builds on part 1's replay: the same ten servers, each reading
  `core` every 2 s with the first reads spread over the 2 s, through the
  frame reader and each server's sample pipeline; the Desktop periods
  for what a view subscribes (the Overview adds `fs`, `identity` and
  `failedUnits`); and a journal follow at 1,000 lines a second through
  `FollowReplay`. Every server is linked and online; there is no SSH.
- **Surfaces**, 20 s each, in order: the fleet list with nothing
  selected; `debian-12-1`'s Overview; its Logs panel, opened by tapping
  its tab, whose follow runs while it shows. The rail stays on screen,
  so the later surfaces carry the fleet's updates too.
- **Frames.** `watchPerformance` collects the `FrameTiming`s and
  `FrameTimingSummarizer` reduces them: build (UI thread) and raster
  times as average, p90, p99 and worst, the frames over its 16 ms
  budget (`missed_frame_*_budget_count`) and the collections, without
  the per-frame lists. Under `benchmarkLive` the test's pumps draw
  nothing, but the live test binding asks for a frame after each one it
  draws, so the app redraws as fast as the display allows (10 to 16
  frames a second in this run) and frames that changed nothing count
  too.
  `load` is what reached the app per second in each window; the run
  fails when no sample arrived in a window, or fewer than 500 log
  records a second in the Logs window, never on a slow frame.

### What it shows

- **The load reached the app as planned:** 5.0 samples a second on every
  surface, and 1,004.1 log records in 19.6 batches a second while the
  Logs panel showed.
- **Build**, the Dart side a device's CPU also runs: the fleet list took
  0.94 ms on average and 9.67 ms at p99, with 2 of 327 frames over
  16 ms; the Overview 3.15 ms and 43.6 ms, with 18 of 249 over; the Logs
  panel with the follow 27.0 ms and 88.2 ms, with 131 of 199 over, and
  232 young-generation collections in 20 s against 16 and 10 on the
  other surfaces. On this loaded machine the follow is the cost to watch;
  whether the Logs panel's build holds 16 ms at 1,000 lines a second is
  for the device sign-off (06) to show.
- **Raster:** 56 to 79 ms on average and 103 to 146 ms at p99 on every
  surface, every frame over 16 ms. That is llvmpipe on a shared CPU and
  says nothing about a phone's GPU.

### Not covered in part 2

- **Devices.** The low-end Android phone and the older iPhone of 06 stay
  manual, and this test cannot run on them yet: it reads the fixtures
  from the checkout through `dart:io` (`KLABAUTERMANN_REPLAY_FIXTURES`),
  so it runs only on a desktop target. A device run needs them bundled
  first, as assets or generated Dart.
- **The phone layout.** The window is a desktop one; the phone shell (03
  §10.5) is not measured.
- **The real engine.** The replay engine stands in for it: no links, no
  K22 scheduler (it keeps its own cadences and spread), no log service
  (it answers log streams as K25b's router does and follows them itself
  until K26), and its CPU time competes with the app's on the same
  machine.
- **Other panels and input.** Only these three surfaces, and the test
  scrolls nothing.
