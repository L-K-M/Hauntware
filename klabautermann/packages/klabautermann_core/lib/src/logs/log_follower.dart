/// One followed log stream (03 §7.6, §10.1; LOG-02, LOG-22, CN-05): an
/// [OpenLogStream] with `follow: true`, read by `journalctl -f -o json`
/// or `tail -F` on a process of its own. `LogStreamRouter` runs it on its
/// server's link, pauses it when the link goes or the app leaves the
/// foreground, and runs it again on the next link: a journal follow
/// resumes after the newest cursor it received, while a file's `tail -F`
/// starts again with only new lines and says lines may be missing
/// ([LogContinuity.gap]).
///
/// ```text
///   run ─▶ process ─▶ lines ─▶ ring ─▶ LogBatch, at most 20 a second
///    ▲        ├─ link lost ─▶ the router queues it again
///    │        └─ exit, refusal ─▶ last batch, then ended
///    └──── pause: process closed, ring kept
///   end: process closed, ring discarded ─▶ ended
/// ```
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteExit, RemoteProcess, SshLink, SshLinkClosed;

import '../engine/protocol.dart';
import 'journal_record.dart';
import 'log_service.dart';

/// The least time between two [LogBatch]es of one stream, so it sends at
/// most 20 a second (03 §10.1 [E]); a batch takes every line held.
const kLogBatchInterval = Duration(milliseconds: 50);

/// The longest line a follow keeps, in bytes. A journal entry longer than
/// this counts as dropped, since a cut entry is no JSON; a file line
/// keeps its first bytes, which the viewer cuts again at 16 KiB with its
/// marker (03 §10.8). `journalctl -o json` sends a field over 4,096 bytes
/// as null, so an entry stays well below it.
const kFollowLineMaxBytes = 256 * 1024;

/// The most lines a follow holds for its next batch, oldest dropped first
/// and counted in it [E]: 5 seconds of a 1,000 lines/s follow, where a
/// batch takes 50 lines, so only a burst fills it, such as the backlog
/// of a resume after a reconnect.
const kFollowRingLines = 5000;

/// The most bytes of lines a follow holds for its next batch, as
/// received [E]; a window read holds as much (`kLogReadMaxOutputBytes`).
const kFollowRingBytes = 4 * 1024 * 1024;

const _newline = 0x0a;

/// A failed open of a followed file: GNU tail's `cannot open '…' for
/// reading: …` and BusyBox's `can't open '…': …`, in the C locale.
final _openFailed = RegExp("cannot open|can't open");

/// The follow of one [OpenLogStream], owned by `LogStreamRouter` in the
/// engine isolate. It parses a line only when a batch takes it, so a
/// burst the ring drops costs no parsing.
final class LogFollower {
  /// [onLost] hears that the process went without a status on its link,
  /// which the router queues again; [onEnded] that the stream ended, after
  /// its [LogStreamEnded]. [track] takes each process close, which the
  /// router's close waits for. [elapsed] is a monotonic clock, and
  /// [quote] quotes each word for the login shell (03 §8.8).
  LogFollower({
    required this._streamId,
    required this._spec,
    required this._emit,
    required this._onLost,
    required this._onEnded,
    required this._track,
    required this._elapsed,
    required this._quote,
    this._startTimer = Timer.new,
  });

  final String _streamId;
  final LogStreamSpec _spec;
  final void Function(EngineEvent event) _emit;
  final void Function() _onLost;
  final void Function() _onEnded;
  final void Function(Future<void> closing) _track;
  final Duration Function() _elapsed;
  final ShellQuote _quote;
  final Timer Function(Duration duration, void Function() callback) _startTimer;

  /// Lines received and not yet batched, oldest first.
  final _ring = ListQueue<Uint8List>();
  int _ringBytes = 0;

  /// Lines discarded since the last batch.
  int _dropped = 0;
  Duration? _lastBatch;
  Timer? _beat;

  /// The newest valid journal cursor a batch took.
  String? _cursor;

  /// Whether any line arrived since the stream opened.
  bool _received = false;

  /// The live link the process was last lost on, until a line arrives.
  SshLink? _lostOn;

  /// The end the host gave, sent once the ring is out.
  LogStreamEnded? _ending;
  bool _ended = false;
  _Run? _run;

  /// Whether a follow of [spec] runs, rather than ending as invalid at
  /// once (03 §8.8).
  static bool accepts(LogStreamSpec spec) {
    try {
      _command(spec, after: spec.afterCursor, lines: spec.window);
      return true;
    } on HostCommandError {
      return false;
    }
  }

  /// Starts the follow on [link] and returns how this run continues the
  /// stream, for the router's [LogStreamRunning]. The first run reads
  /// [LogStreamSpec.window] earlier records, or resumes after
  /// [LogStreamSpec.afterCursor]. A later one resumes after the newest
  /// journal cursor received, or reads only new records once any arrived
  /// ([LogContinuity.gap]), so none repeats.
  LogContinuity run(SshLink link) {
    assert(_run == null && _ending == null && !_ended, 'not idle');
    final after = _resumeCursor();
    final gap = after == null && _received;
    // Validated by accepts, and every cursor kept passes the validator.
    final argv = _command(_spec, after: after, lines: gap ? 0 : _spec.window);

    late final _Run run;
    run = _Run(
      link,
      Future.sync(
        () => link.start(HostCommands.commandLine(argv, quote: _quote)),
      ),
      (line, cut) {
        if (!identical(_run, run)) return;
        run.received = true;
        _line(line, cut);
      },
    );
    _run = run;
    unawaited(_serve(run));
    if (_ring.isNotEmpty || _dropped > 0) _schedule();
    return gap ? LogContinuity.gap : LogContinuity.complete;
  }

  /// Stops the process without an event, for a link that went or the
  /// background (03 §6.4), and keeps the lines not yet batched for the
  /// next run, sending them now when the rate allows; its timer stops.
  /// Returns false, changing nothing, once the host ended the follow:
  /// it ends as soon as its last batch goes.
  bool pause() {
    if (_ending != null || _ended) return false;
    _stop();
    _beat?.cancel();
    _beat = null;
    _flush();
    return true;
  }

  /// Ends the stream with [status] at once: the process closes and lines
  /// not yet batched go. Does nothing once it ended.
  void end(LogStreamEnded status) {
    if (_ended) return;
    _stop();
    _finish(status);
  }

  // -- commands -------------------------------------------------------

  /// A run's command: after [after], a journal cursor, or else with
  /// [lines] earlier records first. Refused with [HostCommandError]: a
  /// window outside 0 to [kLogWindowMax], a file with a cursor, and what
  /// the validated builders refuse (03 §8.8), a journal `until` among
  /// them.
  static List<String> _command(
    LogStreamSpec spec, {
    required String? after,
    required int lines,
  }) {
    if (spec.window < 0 || spec.window > kLogWindowMax) {
      throw const HostCommandError('window outside 0 to $kLogWindowMax');
    }

    final count = after == null ? lines : null;
    return switch (spec.source) {
      // No --since: up to systemd 253 journalctl seeks it before -n and
      // prints the oldest records in range. The batches apply it instead.
      final JournalLogSource s => HostCommands.journalctl(
        unit: s.unit,
        identifier: s.identifier,
        currentBoot: s.currentBootOnly,
        priority: switch (s.priority) {
          final priority? => '${priority.index}',
          null => null,
        },
        until: s.until,
        cursor: after,
        lines: count,
        order: JournalOrder.follow,
      ),
      KernelLogSource() => HostCommands.journalctl(
        kernel: true,
        cursor: after,
        lines: count,
        order: JournalOrder.follow,
      ),
      FileLogSource(:final path) =>
        after == null
            ? HostCommands.tail(path, lines: lines, follow: true)
            : throw const HostCommandError('a file has no cursor'),
    };
  }

  /// The newest journal cursor received: the newest line still held that
  /// carries a valid one, else the newest a batch took, else the spec's.
  String? _resumeCursor() {
    if (_spec.source is FileLogSource) return null;
    for (var i = _ring.length - 1; i >= 0; i--) {
      final entry = parseJournalLine(_text(_ring.elementAt(i)));
      if (_validCursor(entry?.cursor) case final cursor?) return cursor;
    }
    return _cursor ?? _spec.afterCursor;
  }

  // -- the process ----------------------------------------------------

  Future<void> _serve(_Run run) async {
    final RemoteProcess process;
    try {
      process = await run.started;
    } on Object {
      // The channel was refused, or the link closed.
      if (identical(_run, run)) _lost(run);
      return;
    }
    // Stopped while the channel opened: _stop closes the late process.
    if (!identical(_run, run)) return;

    run.stdoutSub = process.stdout.listen(
      run.lines.add,
      onError: (Object _) => _complete(run.stdoutDone),
      onDone: () => _complete(run.stdoutDone),
      cancelOnError: true,
    );
    run.stderrSub = process.stderr.listen(
      (chunk) => _stderr(run, chunk),
      onError: (Object _) => _complete(run.stderrDone),
      onDone: () => _complete(run.stderrDone),
      cancelOnError: true,
    );

    RemoteExit exit;
    try {
      exit = await process.exit;
    } on Object {
      exit = const RemoteExit();
    }
    await Future.wait([run.stdoutDone.future, run.stderrDone.future]);
    if (!identical(_run, run)) return;

    // A lost link or channel ends the process without a status. Its cut
    // last line goes uncounted: the next run sends it again, or says
    // lines may be missing.
    if (exit.exitCode == null && exit.exitSignal == null) return _lost(run);
    run.lines.close();
    // A follow runs until it is closed, so even exit 0 is a failure.
    final stderr = run.stderr;
    _endAfterRing(
      logExitEnd(exit, stderr) ??
          LogStreamEnded(
            LogStreamEndReason.failed,
            detail: logEndDetail(stderr),
          ),
    );
  }

  /// [run]'s process went without a status, or its channel did not open.
  /// On a closed link the follow waits for the next one. On a live link
  /// the router runs it again, since the link may only now be closing,
  /// and it ends as failed when lost there twice without a line between.
  void _lost(_Run run) {
    final link = run.link;
    final stderr = run.stderr;
    _stop();
    if (link.state is! SshLinkClosed) {
      if (identical(_lostOn, link)) {
        return _endAfterRing(
          LogStreamEnded(
            LogStreamEndReason.failed,
            detail: logEndDetail(stderr),
          ),
        );
      }
      _lostOn = link;
    }
    _onLost();
  }

  /// Keeps [chunk] of [run]'s stderr. `tail -F` retries a file it cannot
  /// open instead of exiting, so a file follow whose run has delivered no
  /// line ends when the open names a refusal, a resumed run included;
  /// after one, a rotation can take the file away for a moment. Only the
  /// open counts: a rotation of a file that is still empty prints `has
  /// become inaccessible: No such file or directory` while tail waits for
  /// the new file.
  void _stderr(_Run run, List<int> chunk) {
    run.addStderr(chunk);
    if (_spec.source is! FileLogSource || run.received) return;

    final stderr = run.stderr;
    final opens = stderr.split('\n').where(_openFailed.hasMatch).join('\n');
    if (logRefusal(opens) case final reason?) {
      _endAfterRing(LogStreamEnded(reason, detail: logEndDetail(stderr)));
    }
  }

  void _stop() {
    final run = _run;
    if (run == null) return;

    _run = null;
    run.stop();
    // TERM, then the channel, bounded; also a channel that opens late.
    _track(
      run.started
          .then((process) => process.close())
          .then((_) {}, onError: (Object _) {}),
    );
  }

  // -- the ring and the rate ------------------------------------------

  void _line(Uint8List line, bool cut) {
    _received = true;
    _lostOn = null;
    if (cut && _spec.source is! FileLogSource) {
      _dropped++;
    } else {
      _ring.add(line);
      _ringBytes += line.length;
      while (_ring.length > kFollowRingLines || _ringBytes > kFollowRingBytes) {
        _ringBytes -= _ring.removeFirst().length;
        _dropped++;
      }
    }
    _schedule();
  }

  /// Arms the beat for the next batch: at once after a quiet spell, else
  /// [kLogBatchInterval] after the last.
  void _schedule() {
    if (_beat != null || _ended) return;
    final last = _lastBatch;
    final wait = last == null
        ? Duration.zero
        : kLogBatchInterval - (_elapsed() - last);
    _beat = _startTimer(wait.isNegative ? Duration.zero : wait, _onBeat);
  }

  void _onBeat() {
    _beat = null;
    // A timer may fire a little early.
    if (!_flush()) return _schedule();
    if (_ending case final status?) _finish(status);
  }

  /// Sends what the ring holds as one [LogBatch], unless the last went
  /// less than [kLogBatchInterval] ago; true when it sent it or nothing
  /// was waiting.
  bool _flush() {
    if (_ring.isEmpty && _dropped == 0) return true;
    final now = _elapsed();
    final last = _lastBatch;
    if (last != null && now - last < kLogBatchInterval) return false;

    final since = switch (_spec.source) {
      JournalLogSource(:final since) => since,
      _ => null,
    };
    final records = <LogRecord>[];
    var dropped = _dropped;
    for (final line in _ring) {
      final text = _text(line);
      if (_spec.source is FileLogSource) {
        records.add(
          FileRecord(
            text.endsWith('\r') ? text.substring(0, text.length - 1) : text,
          ),
        );
        continue;
      }
      if (text.trim().isEmpty) continue;

      final entry = parseJournalLine(text);
      if (entry == null) {
        dropped++;
        continue;
      }
      _cursor = _validCursor(entry.cursor) ?? _cursor;
      final at = entry.timestampUtc;
      // Outside the time range, as a window after a cursor ends there.
      if (since != null && at != null && at.isBefore(since)) continue;
      records.add(journalRecordFrom(entry));
    }
    _ring.clear();
    _ringBytes = 0;
    _dropped = 0;

    if (records.isEmpty && dropped == 0) return true;
    _emit(LogBatch(streamId: _streamId, records: records, dropped: dropped));
    _lastBatch = now;
    return true;
  }

  /// Ends the stream for [status], the host's end, once the lines held
  /// went out as the rate allows.
  void _endAfterRing(LogStreamEnded status) {
    _stop();
    if (_ring.isEmpty && _dropped == 0) return _finish(status);
    _ending = status;
    _schedule();
  }

  void _finish(LogStreamEnded status) {
    _ended = true;
    _ending = null;
    _beat?.cancel();
    _beat = null;
    _ring.clear();
    _ringBytes = 0;
    _emit(LogStreamState(_streamId, status));
    _onEnded();
  }

  static String _text(Uint8List line) =>
      utf8.decode(line, allowMalformed: true);

  /// [cursor] when [ArgValidators.journalCursor] accepts it, so a resume
  /// command never fails on what a host printed.
  static String? _validCursor(String? cursor) =>
      cursor != null && ArgValidators.journalCursor(cursor) == null
      ? cursor
      : null;

  static void _complete(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }
}

/// One process of a follow, from [SshLink.start] to its close.
final class _Run {
  _Run(this.link, this.started, void Function(Uint8List, bool) onLine)
    : lines = _Lines(onLine);

  final SshLink link;
  final Future<RemoteProcess> started;
  final _Lines lines;
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;

  /// Whether this process delivered a line.
  bool received = false;

  /// The last [kLogReadStderrBytes] of stderr.
  final _stderr = <int>[];

  String get stderr => utf8.decode(_stderr, allowMalformed: true);

  void addStderr(List<int> chunk) {
    _stderr.addAll(chunk);
    final over = _stderr.length - kLogReadStderrBytes;
    if (over > 0) _stderr.removeRange(0, over);
  }

  /// Stops listening; a cancelled listener reports no end, so the dones
  /// complete here.
  void stop() {
    unawaited(stdoutSub?.cancel());
    unawaited(stderrSub?.cancel());
    LogFollower._complete(stdoutDone);
    LogFollower._complete(stderrDone);
  }
}

/// Splits a follow's stdout into lines without their line break, each
/// cut to [kFollowLineMaxBytes], so a line in progress holds at most that.
final class _Lines {
  _Lines(this._onLine);

  final void Function(Uint8List line, bool cut) _onLine;
  final _line = BytesBuilder(copy: false);
  bool _cut = false;

  void add(List<int> chunk) {
    var start = 0;
    while (true) {
      final end = chunk.indexOf(_newline, start);
      _keep(chunk, start, end < 0 ? chunk.length : end);
      if (end < 0) return;
      _send();
      start = end + 1;
    }
  }

  /// Sends a last line that has no line break.
  void close() {
    if (_line.isNotEmpty || _cut) _send();
  }

  void _keep(List<int> chunk, int start, int end) {
    final room = kFollowLineMaxBytes - _line.length;
    if (end - start > room) {
      _cut = true;
      end = start + room;
    }
    if (end > start) _line.add(chunk.sublist(start, end));
  }

  void _send() {
    final cut = _cut;
    _cut = false;
    _onLine(_line.takeBytes(), cut);
  }
}
