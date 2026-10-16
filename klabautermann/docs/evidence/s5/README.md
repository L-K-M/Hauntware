# Spike S5, part 1: engine budgets replayed on one machine

Each JSON file is the output of `klabautermann_core/tool/engine_budget.dart`,
run from `klabautermann/packages/klabautermann_core`:

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
fixes (from `88407c86` on), two of which touch its output. The follow's stand-in now also holds a batch back while it
would be the 21st within a second (03 §10.1); the 50 ms beat alone let
a late batch and the next go a few milliseconds apart. Over 10 s of
10 ms steps with 2 ms of jitter it sends 198 or 199 batches where the
beat alone sent 200, so the batch figures below would move by under
1 %. And the `ui` counts now include samples by server, the servers
profiled and the samples with rates, which these files lack.

**These numbers are provisional.** A shared container is neither 03
§11.4's reference VM nor a phone. Device numbers and the UI frame p99
belong to spike S5 part 2 (K29b) and the manual gate of 06, and nothing
here sets a budget.

## Method

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

## What it shows

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

## Not covered here

- **SSH.** No dartssh2 decryption, MAC or window handling, which run in
  the engine isolate too (D18). K29b's replay and the integration tests
  reach it.
- **Slow collectors.** `procs` (up to 500 rows every 5 s while visible,
  03 §6.4), `fs`, `units`, `timers` and `cron` are not replayed; real
  captures (K28) size them.
- **Bigger hosts.** `core` replies here come from 2 to 16 CPUs. Per-core
  and per-disk rows grow the replies and the pipeline's work.
- **The UI side.** The receiving isolate only counts messages; what the
  app does with them is K29b's frame timing.
- **Cadences.** The phone schedule is this harness's reading of 03 §6.4;
  K22's scheduler decides the real one.
