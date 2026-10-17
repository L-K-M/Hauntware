/// The engine's bounded log reads (03 §7.6, §10.1): an [OpenLogStream]
/// with `follow: false` reads one window of a server's logs over its link
/// and ends. `LogStreamRouter` decides when each read opens here; a
/// follow is a `LogFollower`'s.
///
/// A read runs one host command at a time through
/// [HostCommands.commandLine]: `journalctl -o json -r -n <window>` for the
/// journal and the kernel log, `dmesg --json --decode` as the kernel log's
/// fallback, `tail -n <window> --` for a file. It sends
/// [LogStreamRunning] as it opens, then the window as one [LogBatch],
/// newest first, then a [LogStreamEnded]:
///
/// ```text
///   open ─▶ running ─▶ batch ─▶ ended (window filled, oldest reached,
///    │         │                       missing, denied, failed)
///    │         └─ kernel log, no journal record ─▶ running (fallback)
///    └─ spec refused ─▶ ended (invalid)
///   closeStream ─▶ ended (closed)        close() ─▶ ended (failed)
///   pause ─▶ no event: the router opens the stream again later
/// ```
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteExit, RemoteProcess, SshLink;

import '../engine/protocol.dart';
import 'journal_record.dart';

/// The largest window a read serves: LOG-01's page (03 §7.6).
const kLogWindowMax = 500;

/// The stdout bytes one host command of a read keeps, well above
/// `SshLink.run`'s 256 KiB default, which cuts a 500-entry window short:
/// a `journalctl -o json` entry with the trusted fields journald adds runs
/// to about 1 to 2 KiB. 4 MiB is 8 KiB for each entry of a full window,
/// and holds the `dmesg --json` of a kernel ring up to about 1.5 MiB (its
/// JSON is about 2.5 times the ring). It is an eighth of the log viewer's
/// 32 MiB byte cap (03 §10.8, §11.4), and a read holds one window's bytes
/// while it parses them.
const kLogReadMaxOutputBytes = 4 * 1024 * 1024;

/// How long one host command of a read may run once its channel is open,
/// `SshLink.run`'s one-shot deadline; the link bounds the open itself.
const kLogReadDeadline = Duration(seconds: 30);

/// The stderr bytes a read keeps for [LogStreamEnded.detail]: the last
/// ones, where a tool prints its error.
const kLogReadStderrBytes = 4096;

/// The bounded log reads of one server's link, owned by the engine
/// isolate.
final class LogService {
  LogService({
    required this._link,
    required this._quote,
    required this._emit,
    this._maxOutputBytes = kLogReadMaxOutputBytes,
    this._deadline = kLogReadDeadline,
    this._startTimer = Timer.new,
  });

  final SshLink _link;

  /// Quotes each word of a command for the login shell (03 §8.8); 03
  /// §6.2 names `seance_core`'s `quoteShellWord`.
  final ShellQuote _quote;

  /// Takes every [LogBatch] and [LogStreamState] a read sends.
  final void Function(EngineEvent event) _emit;
  final int _maxOutputBytes;
  final Duration _deadline;

  /// Starts each command's deadline; a test seam.
  final Timer Function(Duration duration, void Function() callback) _startTimer;

  final _reads = <String, _Read>{};
  final _closing = <Future<void>>{};
  Future<void>? _closeDone;

  /// Whether [open] runs [spec], a window, rather than ending it as
  /// invalid at once (03 §8.8).
  static bool accepts(LogStreamSpec spec) {
    try {
      _primaryCommand(spec);
      return true;
    } on HostCommandError {
      return false;
    }
  }

  /// Opens [streamId] on [spec], a window. Before it returns it sends
  /// [LogStreamRunning], or [LogStreamEnded] with
  /// [LogStreamEndReason.invalid] when the spec is refused before anything
  /// runs, so the engine answers each open before its next request. The
  /// engine rejects a reused id; an id open here is a programming error,
  /// as are a follow and an open after [close].
  void open(String streamId, LogStreamSpec spec) {
    if (_closeDone != null) throw StateError('the log service is closed');
    if (spec.follow) {
      throw ArgumentError.value(spec, 'spec', 'a follow is not a window');
    }
    if (_reads.containsKey(streamId)) {
      throw StateError('log stream $streamId is open');
    }

    final List<String> argv;
    try {
      argv = _primaryCommand(spec);
    } on HostCommandError {
      _emit(
        LogStreamState(
          streamId,
          const LogStreamEnded(LogStreamEndReason.invalid),
        ),
      );
      return;
    }

    final read = _Read(streamId, spec);
    _reads[streamId] = read;
    _emit(LogStreamState(streamId, const LogStreamRunning()));
    unawaited(_serve(read, argv));
  }

  /// [CloseStream]: stops [streamId]'s read and closes its process; its
  /// last event is [LogStreamEnded] with [LogStreamEndReason.closed].
  /// Does nothing when the stream is not open.
  void closeStream(String streamId) {
    final read = _reads[streamId];
    if (read == null) return;
    _end(read, const LogStreamEnded(LogStreamEndReason.closed));
  }

  /// Stops [streamId]'s read and closes its process without an event, for
  /// a read the engine opens again later (03 §6.4's background pause). It
  /// has sent no batch, since a window sends its one batch as it ends.
  /// Does nothing when the stream is not open.
  void pause(String streamId) {
    final read = _reads[streamId];
    if (read == null) return;
    _end(read, null);
  }

  /// Stops the service, for a link that closed or a server the engine
  /// forgets: each open read ends with [LogStreamEndReason.failed], as one
  /// whose link closed under it does. Completes once every process the
  /// service started has closed.
  Future<void> close() => _closeDone ??= _close();

  Future<void> _close() async {
    for (final read in _reads.values.toList()) {
      _end(read, const LogStreamEnded(LogStreamEndReason.failed));
    }
    while (_closing.isNotEmpty) {
      await Future.wait(_closing.toList());
    }
  }

  // -- reads ----------------------------------------------------------

  /// The first command [spec] runs. Refused with [HostCommandError]: a
  /// window outside 1 to [kLogWindowMax], a file with a cursor, and what
  /// the validated builders refuse (03 §8.8).
  static List<String> _primaryCommand(LogStreamSpec spec) {
    if (spec.window < 1 || spec.window > kLogWindowMax) {
      throw const HostCommandError('window outside 1 to $kLogWindowMax');
    }

    final cursor = spec.afterCursor;
    return switch (spec.source) {
      // journalctl refuses --since with a cursor; _journalWindow applies
      // it instead (03 §10.1).
      final JournalLogSource s => HostCommands.journalctl(
        unit: s.unit,
        identifier: s.identifier,
        currentBoot: s.currentBootOnly,
        priority: switch (s.priority) {
          final priority? => '${priority.index}',
          null => null,
        },
        since: cursor == null ? s.since : null,
        until: s.until,
        cursor: cursor,
        lines: spec.window,
        order: JournalOrder.newestFirst,
      ),
      KernelLogSource() => HostCommands.journalctl(
        kernel: true,
        cursor: cursor,
        lines: spec.window,
        order: JournalOrder.newestFirst,
      ),
      FileLogSource(:final path) =>
        cursor == null
            ? HostCommands.tail(path, lines: spec.window)
            : throw const HostCommandError('a file has no cursor'),
    };
  }

  Future<void> _serve(_Read read, List<String> argv) async {
    final spec = read.spec;
    // journalctl -r prints newest first, tail oldest first: a cut keeps
    // the newest bytes.
    final keep = spec.source is FileLogSource ? _Keep.last : _Keep.first;
    final out = await _output(read, argv, keep);
    if (out == null) return;

    switch (spec.source) {
      case JournalLogSource(:final since):
        final after = spec.afterCursor == null ? null : since;
        _deliver(read, out, _journalWindow(out, spec.window, since: after));
      case FileLogSource():
        _deliver(read, out, _fileWindow(out, spec.window));
      case KernelLogSource():
        final journal = _journalWindow(out, spec.window);
        // Without an exit code journalctl did not run to its end: a cut,
        // a signal or a lost link, which _failure reads.
        if (spec.afterCursor != null ||
            out.exit?.exitCode == null ||
            journal.records.isNotEmpty) {
          return _deliver(read, out, journal);
        }
        await _fallBack(read);
    }
  }

  /// Reads the kernel log from `dmesg` (LOG-03) after `journalctl -k -b`
  /// exited without a kernel record, whatever its exit code. That is
  /// what an account outside `systemd-journal`, `adm` and `wheel` sees,
  /// since kernel entries are never its own (`kPanelNeeds`, K04), and what
  /// a host without journalctl or without kernel entries in its journal
  /// gives. Never after a cursor, where an empty older page is the oldest
  /// record and `dmesg` has no cursor, nor after a cut, signal, timeout or
  /// lost link.
  Future<void> _fallBack(_Read read) async {
    // An ended read sends nothing more. _serve calls this as soon as
    // _output returns, without yielding, so this states the invariant
    // here rather than guarding a path that runs today.
    if (read.ended) return;
    _emit(
      LogStreamState(
        read.streamId,
        const LogStreamRunning(reader: LogReader.fallback),
      ),
    );
    // dmesg prints its whole ring oldest first.
    final out = await _output(read, HostCommands.dmesgJson(), _Keep.last);
    if (out == null) return;
    _deliver(read, out, _dmesgWindow(out, read.spec.window));
  }

  /// Runs [argv] for [read] and returns its output; null once [read] has
  /// ended, as failed when the command did not finish.
  Future<_Output?> _output(_Read read, List<String> argv, _Keep keep) async {
    final ran = await _run(read, argv, keep);
    if (read.ended) return null;

    switch (ran) {
      case final _Output out:
        return out;
      case _Unfinished(:final stderr):
        _end(
          read,
          LogStreamEnded(
            LogStreamEndReason.failed,
            detail: logEndDetail(stderr),
          ),
        );
        return null;
    }
  }

  /// Sends [window], read by [out], then the read's end.
  void _deliver(_Read read, _Output out, _Window window) {
    if (window.records.isNotEmpty || window.dropped > 0) {
      _emit(
        LogBatch(
          streamId: read.streamId,
          records: window.records,
          dropped: window.dropped,
        ),
      );
    }
    _end(read, _failure(out) ?? LogStreamEnded(window.end));
  }

  /// Ends [read] with [status], its last event, or with none when null
  /// ([pause]), and stops its command.
  void _end(_Read read, LogStreamEnded? status) {
    if (read.ended) return;
    read.ended = true;
    _reads.remove(read.streamId);
    final run = read.run;
    if (run != null) _settle(run, const _Unfinished());
    if (status != null) _emit(LogStreamState(read.streamId, status));
  }

  // -- host commands --------------------------------------------------

  /// Runs [argv] for [read], keeping [keep] of its stdout within the cap.
  /// A cut that keeps the first bytes stops reading at once.
  Future<_Ran> _run(_Read read, List<String> argv, _Keep keep) async {
    final run = _Run(
      _Bytes(_maxOutputBytes, keep),
      Future.sync(
        () => _link.start(HostCommands.commandLine(argv, quote: _quote)),
      ),
    );
    read.run = run;

    final RemoteProcess process;
    try {
      process = await run.started;
    } on Object {
      // The channel was refused, or the link closed.
      _settle(run, const _Unfinished());
      return run.result.future;
    }
    // Ended while the channel opened: _settle closes the late process.
    if (run.settled) return run.result.future;

    run.deadline = _startTimer(
      _deadline,
      () => _settle(run, _Unfinished(run.stderr.text)),
    );
    run.stdoutSub = process.stdout.listen(
      (bytes) {
        run.stdout.add(bytes);
        if (keep == _Keep.first && run.stdout.cut) {
          _settle(run, _Output(run.stdout.take(), cut: true));
        }
      },
      onError: (Object _) => _done(run.stdoutDone),
      onDone: () => _done(run.stdoutDone),
      cancelOnError: true,
    );
    run.stderrSub = process.stderr.listen(
      run.stderr.add,
      onError: (Object _) => _done(run.stderrDone),
      onDone: () => _done(run.stderrDone),
      cancelOnError: true,
    );
    unawaited(_awaitExit(run, process));
    return run.result.future;
  }

  Future<void> _awaitExit(_Run run, RemoteProcess process) async {
    RemoteExit exit;
    try {
      exit = await process.exit;
    } on Object {
      exit = const RemoteExit();
    }
    await Future.wait([run.stdoutDone.future, run.stderrDone.future]);
    if (run.settled) return;

    // A link that closes ends the process without a status, which
    // _failure reads as failed.
    _settle(
      run,
      _Output(
        run.stdout.take(),
        cut: run.stdout.cut,
        exit: exit,
        stderr: run.stderr.text,
      ),
    );
  }

  /// Settles [run] with [ran] once: its timer and listeners stop and its
  /// process closes (TERM, then the channel, bounded), also one whose
  /// channel opens late. [close] waits for every such close.
  void _settle(_Run run, _Ran ran) {
    if (run.settled) return;
    run.deadline?.cancel();
    unawaited(run.stdoutSub?.cancel());
    unawaited(run.stderrSub?.cancel());
    // A cancelled listener reports no end; _awaitExit must not wait on it.
    _done(run.stdoutDone);
    _done(run.stderrDone);

    // A start that failed leaves nothing to close.
    final closing = run.started
        .then((process) => process.close())
        .then((_) {}, onError: (Object _) {});
    _closing.add(closing);
    unawaited(closing.whenComplete(() => _closing.remove(closing)));
    run.result.complete(ran);
  }

  static void _done(Completer<void> completer) {
    if (!completer.isCompleted) completer.complete();
  }
}

// -- windows ------------------------------------------------------------

typedef _Window = ({
  List<LogRecord> records,
  int dropped,
  LogStreamEndReason end,
});

/// journalctl's line for an empty result, which some versions print in
/// JSON mode too; never a record.
const _noEntries = '-- No entries --';

const _newline = 0x0a;

/// A `journalctl -o json -r` window: newest first, as printed. A cut
/// keeps the complete lines, so the last record's cursor reads on. A
/// line that is not a JSON object counts as dropped, as does an entry
/// longer than the cap, which leaves no complete line. A full window
/// without a record fails: it has no cursor to read on from, and
/// journalctl prints an entry's keys in hash order, so a cut entry's
/// cursor may lie past the cap. [since] is the time range's start the
/// engine applies after a cursor: the window ends at the first record
/// older than it.
_Window _journalWindow(_Output out, int window, {DateTime? since}) {
  final bytes = out.stdout;
  final end = out.cut ? bytes.lastIndexOf(_newline) + 1 : bytes.length;
  final text = utf8.decode(
    Uint8List.sublistView(bytes, 0, end),
    allowMalformed: true,
  );

  final records = <LogRecord>[];
  var dropped = out.cut && end == 0 ? 1 : 0;
  var oldest = false;
  for (final line in text.split('\n')) {
    if (line.isEmpty || line == _noEntries) continue;
    // A host that prints more than it was asked for is cut off here.
    if (records.length + dropped == window) break;
    final entry = parseJournalLine(line);
    if (entry == null) {
      dropped++;
      continue;
    }
    final at = entry.timestampUtc;
    if (since != null && at != null && at.isBefore(since)) {
      oldest = true;
      break;
    }
    records.add(journalRecordFrom(entry));
  }

  final full = !oldest && (out.cut || records.length + dropped >= window);
  return (
    records: records,
    dropped: dropped,
    end: switch (full) {
      false => LogStreamEndReason.oldestReached,
      true when records.isEmpty => LogStreamEndReason.failed,
      true => LogStreamEndReason.windowFilled,
    },
  );
}

/// A `dmesg --json --decode` window: dmesg prints its whole ring oldest
/// first, so the window is the newest [window] records, reversed. A cut
/// whose kept tail holds no whole record counts the newest as dropped.
_Window _dmesgWindow(_Output out, int window) {
  var text = utf8.decode(out.stdout, allowMalformed: true);
  if (out.cut) {
    // The kept tail starts inside the document. util-linux escapes every
    // control character in a JSON string, so no line break falls inside
    // one: from the first, the parser, which skips a `}` outside a
    // record, reads each record that follows whole.
    text = '[${text.substring(text.indexOf('\n') + 1)}';
  }
  final all = parseDmesgJson(text).value;
  final newest = all.length > window ? all.sublist(all.length - window) : all;

  return (
    records: [
      for (final r in newest.reversed)
        KernelRecord(
          message: r.message,
          sinceBoot: r.sinceBoot,
          priority: switch (r.level) {
            final level? => LogPriority.values[level],
            null => null,
          },
        ),
    ],
    dropped: out.cut && all.isEmpty ? 1 : 0,
    end: out.cut || all.length > window
        ? LogStreamEndReason.windowFilled
        : LogStreamEndReason.oldestReached,
  );
}

/// A `tail -n` window: the file's last lines, reversed, each without its
/// line break. A cut kept the newest bytes, so its first line, which
/// starts before them, goes; when that leaves no line, the newest line
/// was longer than the cap and counts as dropped.
_Window _fileWindow(_Output out, int window) {
  final bytes = out.stdout;
  var start = 0;
  if (out.cut) {
    final first = bytes.indexOf(_newline);
    start = first < 0 ? bytes.length : first + 1;
  }
  final lines = utf8
      .decode(Uint8List.sublistView(bytes, start), allowMalformed: true)
      .split('\n');
  // The final line break, or the empty output.
  if (lines.last.isEmpty) lines.removeLast();
  final newest = lines.length > window
      ? lines.sublist(lines.length - window)
      : lines;

  return (
    records: [
      for (final line in newest.reversed)
        FileRecord(
          line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
        ),
    ],
    dropped: out.cut && newest.isEmpty ? 1 : 0,
    end: out.cut || lines.length >= window
        ? LogStreamEndReason.windowFilled
        : LogStreamEndReason.oldestReached,
  );
}

// -- outcomes -----------------------------------------------------------

/// stderr naming a refusal: errno's EACCES and EPERM texts in the C
/// locale the command runs in, and journalctl's notice.
final _deniedText = RegExp(
  'Permission denied|Operation not permitted|insufficient permissions',
);

/// stderr naming an absent file (ENOENT), or a tool that lacks an option
/// the read needs: `dmesg --json` arrived with util-linux 2.38, and
/// BusyBox has none.
final _missingText = RegExp(
  'No such file or directory|unrecognized option|invalid option|'
  'unknown option',
);

/// The end [out]'s exit asks for; null when the window is read: the
/// command exited 0, or the read closed it at the cap.
LogStreamEnded? _failure(_Output out) => switch (out.exit) {
  final exit? => logExitEnd(exit, out.stderr),
  null => null,
};

/// The end a log command's [exit] asks for, with its [stderr] as the
/// detail; null when it exited 0. Shared with `LogFollower`.
LogStreamEnded? logExitEnd(RemoteExit exit, String stderr) {
  if (exit.exitCode == 0) return null;

  final reason = switch (exit.exitCode) {
    // A signal or a lost link stopped the command before its end, so
    // stderr naming a refusal does not explain the end.
    null => LogStreamEndReason.failed,
    // The shell's `exec` found no such command, or could not run it.
    127 => LogStreamEndReason.missing,
    126 => LogStreamEndReason.denied,
    _ => logRefusal(stderr) ?? LogStreamEndReason.failed,
  };
  return LogStreamEnded(reason, detail: logEndDetail(stderr));
}

/// The refusal a log command's [stderr] names, [LogStreamEndReason.denied]
/// or [LogStreamEndReason.missing]; null when it names none.
LogStreamEndReason? logRefusal(String stderr) {
  if (_deniedText.hasMatch(stderr)) return LogStreamEndReason.denied;
  if (_missingText.hasMatch(stderr)) return LogStreamEndReason.missing;
  return null;
}

/// [stderr] as [LogStreamEnded.detail]: control characters stripped,
/// null when nothing is left.
String? logEndDetail(String stderr) {
  final text = stripControlChars(stderr).trim();
  return text.isEmpty ? null : text;
}

/// How one host command of a read ended.
sealed class _Ran {
  const _Ran();
}

/// The command exited, or the read closed it at the cap.
final class _Output extends _Ran {
  const _Output(this.stdout, {required this.cut, this.exit, this.stderr = ''});

  final Uint8List stdout;

  /// Whether output past the cap arrived and was not kept.
  final bool cut;

  /// How the command exited; null when the read closed it at the cap.
  final RemoteExit? exit;
  final String stderr;
}

/// The command ended without its output: past its deadline, with its
/// channel refused or its link closed, or its read ended first.
final class _Unfinished extends _Ran {
  const _Unfinished([this.stderr = '']);

  final String stderr;
}

// -- state --------------------------------------------------------------

/// One open read.
final class _Read {
  _Read(this.streamId, this.spec);

  final String streamId;
  final LogStreamSpec spec;

  /// The command running, or the last one.
  _Run? run;
  bool ended = false;
}

/// One host command of a read, from [SshLink.start] to its close.
final class _Run {
  _Run(this.stdout, this.started);

  final _Bytes stdout;
  final Future<RemoteProcess> started;
  final stderr = _Bytes(kLogReadStderrBytes, _Keep.last);
  final stdoutDone = Completer<void>();
  final stderrDone = Completer<void>();
  final result = Completer<_Ran>();
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
  Timer? deadline;

  bool get settled => result.isCompleted;
}

/// Which bytes of a stream a [_Bytes] keeps.
enum _Keep { first, last }

/// At most [capacity] bytes of a stream: its first or its last.
final class _Bytes {
  _Bytes(this.capacity, this.keep);

  final int capacity;
  final _Keep keep;
  final _chunks = ListQueue<List<int>>();
  int _length = 0;
  bool _dropped = false;

  /// Whether bytes past [capacity] arrived.
  bool get cut => _dropped || _length > capacity;

  void add(List<int> chunk) {
    switch (keep) {
      case _Keep.first:
        final room = capacity - _length;
        if (chunk.length > room) {
          _dropped = true;
          chunk = chunk.sublist(0, room);
        }
        if (chunk.isEmpty) return;
      case _Keep.last:
        // Whole chunks go while the rest still fills the capacity; take()
        // trims the oldest one left.
        while (_chunks.isNotEmpty &&
            _length + chunk.length - _chunks.first.length >= capacity) {
          _length -= _chunks.removeFirst().length;
          _dropped = true;
        }
    }
    _chunks.add(chunk);
    _length += chunk.length;
  }

  /// The bytes kept.
  Uint8List take() {
    final builder = BytesBuilder(copy: false);
    for (final chunk in _chunks) {
      builder.add(chunk);
    }
    final bytes = builder.takeBytes();
    return bytes.length <= capacity
        ? bytes
        : Uint8List.sublistView(bytes, bytes.length - capacity);
  }

  String get text => utf8.decode(take(), allowMalformed: true);
}
