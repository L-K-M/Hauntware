/// One HWS/1 sampler over an [SshLink] (03 §6.2, D47, D52).
///
/// A session starts `sh -s` with [kSamplerStartCommand], writes the
/// constant program with a fresh nonce, and accepts requests once the
/// program prints READY. At most one request is outstanding; a request
/// that would overlap is skipped, and a skipped tick is counted. A failed
/// start, a missed deadline, output the program cannot produce, or the
/// process ending closes the process and restarts the sampler after a
/// backoff delay:
///
/// ```text
///   idle ─start()─▶ starting ─READY─▶ ready ◀─────────────┐
///                      │                │                 │
///                      └──── fault ─────┴─▶ backoff ─▶ starting
///   any ─close() or link closed─▶ stopped
/// ```
///
/// The request number (`hw_t <seq>`) restarts with each process; the
/// engine's `Sample.seq` is a separate counter the engine owns (D44).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show RemoteProcess, SshLink, SshLinkClosed;

import 'sampler_timing.dart';

/// The stderr bytes a session keeps for diagnostics: the most recent
/// ones, across restarts.
const kSamplerStderrRingBytes = 4096;

/// Where a sampler session is.
sealed class SamplerState {
  const SamplerState();
}

/// Constructed; [SamplerSession.start] has not run.
final class SamplerIdle extends SamplerState {
  const SamplerIdle();
}

/// The channel is opening, or the program has not printed READY yet.
final class SamplerStarting extends SamplerState {
  const SamplerStarting();
}

/// READY arrived with this client's collector-set version; requests are
/// accepted.
final class SamplerReady extends SamplerState {
  const SamplerReady();
}

/// The last process failed with [cause]; the next starts at [until].
final class SamplerBackoff extends SamplerState {
  const SamplerBackoff(this.until, this.cause, this.detail);

  /// When the next start begins.
  final DateTime until;

  /// Why the last process was given up.
  final SamplerFault cause;

  /// What was seen, for diagnostics; never shown as text.
  final String detail;
}

/// Terminal: the session no longer starts processes.
final class SamplerStopped extends SamplerState {
  const SamplerStopped(this.reason);

  /// Why the session stopped.
  final SamplerStopReason reason;
}

/// Why a sampler process was given up and restarted.
enum SamplerFault {
  /// [SshLink.start] failed: the channel was refused or did not open
  /// within the link's bound.
  startFailed,

  /// No READY within [SamplerDeadlines.ready].
  readyDeadline,

  /// More output than the reader skips before READY, or a malformed
  /// READY ([HwsSessionFault.noReady]).
  noReady,

  /// READY carried another collector-set version
  /// ([HwsSessionFault.versionMismatch]).
  versionMismatch,

  /// A request had no reply within its deadline.
  requestDeadline,

  /// Output the constant program cannot produce: a marker out of order,
  /// too many sections, or a reply to a request that was not sent.
  protocolViolation,

  /// The process ended, or its stdout or stdin failed.
  exited,
}

/// Why a session stopped.
enum SamplerStopReason {
  /// [SamplerSession.close] ran.
  closed,

  /// The link closed; a new link needs a new session.
  linkClosed,
}

/// What a request produced.
sealed class SamplerOutcome {
  const SamplerOutcome();
}

/// The complete reply.
final class SamplerReplied extends SamplerOutcome {
  const SamplerReplied(this.reply);

  /// The assembled reply, with the request's sequence number.
  final HwsTick reply;
}

/// The request was written but its data is gone; the client shows a gap
/// (03 §6.2).
final class SamplerGap extends SamplerOutcome {
  const SamplerGap(this.seq, this.reason);

  /// The request's sequence number in its process.
  final int seq;

  /// Why the data is missing.
  final SamplerGapReason reason;
}

/// Why a written request produced no data.
enum SamplerGapReason {
  /// A framing error lost the reply; the sampler keeps running.
  lost,

  /// The deadline passed; the sampler restarts.
  deadline,

  /// The process failed for another reason before replying.
  sessionEnded,

  /// The session closed while the request was outstanding.
  closed,
}

/// The request was not written.
final class SamplerSkipped extends SamplerOutcome {
  const SamplerSkipped(this.reason);

  /// Why it was not written.
  final SamplerSkipReason reason;
}

/// Why a request was not written.
enum SamplerSkipReason {
  /// Another request is outstanding (03 §6.2); a tick skipped this way
  /// is counted in [SamplerSession.skippedTicks].
  busy,

  /// The sampler is starting or waiting out a restart delay.
  notReady,

  /// The session stopped.
  stopped,
}

/// One sampler (fast or slow) on one link, owned by the engine isolate.
final class SamplerSession {
  SamplerSession({
    required this._link,
    required this.kind,
    required this._quote,
    this._deadlines = const SamplerDeadlines(),
    Duration Function(int failures)? restartDelay,
  }) : _restartDelay = restartDelay ?? _defaultRestartDelay;

  /// Which program this session runs.
  final SamplerKind kind;

  final SshLink _link;

  /// Quotes `hw_o` arguments after their validators (03 §8.8); 03 §6.2
  /// names `seance_core`'s `quoteShellWord`.
  final ShellQuote _quote;
  final SamplerDeadlines _deadlines;

  final Duration Function(int failures) _restartDelay;

  final _states = StreamController<SamplerState>.broadcast();
  final _stderr = _ByteRing(kSamplerStderrRingBytes);
  final _closing = <Future<void>>{};

  SamplerState _state = const SamplerIdle();
  _Attempt? _attempt;
  _Pending? _pending;
  Timer? _backoffTimer;

  /// Restarts since the last reply; drives [_restartDelay].
  int _failures = 0;
  int _restarts = 0;
  int _skipped = 0;
  bool _stopped = false;
  Future<void>? _closeDone;

  /// The current state; [states] reports each change.
  SamplerState get state => _state;

  /// The running sampler shell's PID and its parent's from the `SELF`
  /// marker (E07), protected targets (03 §8.6), or null before READY and
  /// after the process ended. The parent is 0 outside its PID namespace.
  ({int pid, int parentPid})? get self => _self;
  ({int pid, int parentPid})? _self;

  /// Every state change after the call that subscribes.
  Stream<SamplerState> get states => _states.stream;

  /// Processes given up and restarted (or about to restart) so far.
  int get restarts => _restarts;

  /// Ticks skipped because another request was outstanding (03 §6.2).
  /// A skipped on-demand read is user-started, not cadence overload, and
  /// is not counted.
  int get skippedTicks => _skipped;

  /// The most recent stderr of the sampler processes, with control
  /// characters other than newline and tab removed; for diagnostics.
  String get stderrTail =>
      stripControlChars(utf8.decode(_stderr.bytes, allowMalformed: true));

  /// Starts the first process. Does nothing after the first call.
  void start() {
    if (_state is! SamplerIdle || _stopped) return;
    _launch();
  }

  /// Requests a tick of [collectors] (`hw_t`), which must all run on this
  /// session's [kind]; otherwise, or when the encoder refuses the request,
  /// the future fails with [HwsRequestError] and nothing is written.
  Future<SamplerOutcome> tick(List<Collector> collectors) {
    for (final c in collectors) {
      if (c.sampler != kind) return _wrongSampler(c);
    }
    return _request(
      _RequestKind.tick,
      collectors,
      (seq) => encodeTickRequest(seq, collectors),
    );
  }

  /// Requests an on-demand read (`hw_o`) of [collector] with [args],
  /// which pass the collector's validators and then the injected quoting
  /// (03 §8.8); the future fails with [HwsRequestError] when they do not.
  Future<SamplerOutcome> onDemand(Collector collector, List<String> args) {
    if (collector.sampler != kind) return _wrongSampler(collector);
    return _request(_RequestKind.onDemand, [
      collector,
    ], (seq) => encodeOnDemandRequest(seq, collector, args, quote: _quote));
  }

  /// Stops the session: an outstanding request ends as a gap, the process
  /// is closed (`RemoteProcess.close`, bounded) and no other starts.
  /// Completes once every process this session started has closed.
  Future<void> close() => _closeDone ??= _close();

  Future<void> _close() async {
    _stop(SamplerStopReason.closed);
    while (_closing.isNotEmpty) {
      await Future.wait(_closing.toList());
    }
    await _states.close();
  }

  // -- lifecycle ------------------------------------------------------

  void _launch() {
    if (_link.state is SshLinkClosed) {
      _stop(SamplerStopReason.linkClosed);
      return;
    }
    final attempt = _Attempt(
      generateNonce(_nonceSource),
      Future.sync(() => _link.start(kSamplerStartCommand)),
    );
    _attempt = attempt;
    _setState(const SamplerStarting());
    unawaited(_attach(attempt));
  }

  Future<void> _attach(_Attempt attempt) async {
    final RemoteProcess process;
    try {
      process = await attempt.started;
    } on Object catch (e) {
      _fault(attempt, SamplerFault.startFailed, '$e');
      return;
    }
    // A session that stopped meanwhile closes the late process through
    // [_end], which also waits on [_Attempt.started].
    if (attempt.ended) return;

    attempt.process = process;
    final stdin = attempt.stdin = process.stdin;
    // A write to a process that has gone fails `done`; the fault comes
    // from the exit or stdout handlers below.
    unawaited(stdin.done.then((_) {}, onError: (Object _) {}));
    attempt.stdoutSub = process.stdout.listen(
      (bytes) => _onStdout(attempt, bytes),
      onError: (Object e) => _fault(attempt, SamplerFault.exited, 'stdout: $e'),
      onDone: () => _fault(attempt, SamplerFault.exited, 'stdout closed'),
    );
    attempt.stderrSub = process.stderr.listen(
      _stderr.add,
      onError: (Object _) {},
    );
    unawaited(
      process.exit.then(
        (exit) => _fault(attempt, SamplerFault.exited, '$exit'),
        onError: (Object e) => _fault(attempt, SamplerFault.exited, '$e'),
      ),
    );
    attempt.readyTimer = Timer(
      _deadlines.ready,
      () => _fault(
        attempt,
        SamplerFault.readyDeadline,
        'no READY within ${_deadlines.ready}',
      ),
    );
    _write(attempt, buildSamplerProgram(kind: kind, nonce: attempt.nonce));
  }

  void _onStdout(_Attempt attempt, List<int> bytes) {
    if (attempt.ended) return;
    for (final event in attempt.assembler.push(bytes)) {
      _onEvent(attempt, event);
      if (attempt.ended) return;
    }
  }

  void _onEvent(_Attempt attempt, HwsTickEvent event) {
    switch (event) {
      case HwsSessionReady(:final pid, :final parentPid):
        attempt.readyTimer?.cancel();
        attempt.ready = true;
        _self = (pid: pid, parentPid: parentPid);
        _setState(const SamplerReady());

      case HwsTick(:final seq):
        final pending = _takePending(attempt, seq);
        if (pending == null) {
          _fault(attempt, SamplerFault.protocolViolation, 'reply $seq');
          return;
        }
        _failures = 0;
        pending.complete(SamplerReplied(event));

      case HwsTickLost(:final seq):
        final pending = _takePending(attempt, seq);
        if (pending == null) {
          _fault(attempt, SamplerFault.protocolViolation, 'lost $seq');
          return;
        }
        // The program answered, so the process is alive; only the data
        // is gone.
        _failures = 0;
        pending.complete(SamplerGap(seq, SamplerGapReason.lost));

      case HwsSessionFailed(:final fault, :final detail):
        final cause = switch (fault) {
          HwsSessionFault.noReady => SamplerFault.noReady,
          HwsSessionFault.versionMismatch => SamplerFault.versionMismatch,
          HwsSessionFault.outOfOrder ||
          HwsSessionFault.tooManySections => SamplerFault.protocolViolation,
        };
        _fault(attempt, cause, detail);
    }
  }

  /// Gives up [attempt] for [cause] and schedules the next start, unless
  /// the attempt is already over or the link has closed.
  void _fault(_Attempt attempt, SamplerFault cause, String detail) {
    if (attempt.ended || !identical(_attempt, attempt)) return;
    _end(
      attempt,
      cause == SamplerFault.requestDeadline
          ? SamplerGapReason.deadline
          : SamplerGapReason.sessionEnded,
    );
    _attempt = null;
    if (_link.state is SshLinkClosed) {
      _stop(SamplerStopReason.linkClosed);
      return;
    }
    final delay = _restartDelay(_failures++);
    _restarts++;
    _setState(SamplerBackoff(DateTime.now().add(delay), cause, detail));
    _backoffTimer = Timer(delay, () {
      _backoffTimer = null;
      if (!_stopped) _launch();
    });
  }

  void _stop(SamplerStopReason reason) {
    if (_stopped) return;
    _stopped = true;
    _backoffTimer?.cancel();
    _backoffTimer = null;
    final attempt = _attempt;
    _attempt = null;
    if (attempt != null && !attempt.ended) {
      _end(attempt, SamplerGapReason.closed);
    }
    _setState(SamplerStopped(reason));
  }

  /// Ends [attempt]: its outstanding request becomes a gap for [reason],
  /// its timers and listeners stop, and its process is closed (TERM, then
  /// the channel, bounded), also when [SshLink.start] completes late.
  void _end(_Attempt attempt, SamplerGapReason reason) {
    attempt.ended = true;
    _self = null;
    attempt.readyTimer?.cancel();
    unawaited(attempt.stdoutSub?.cancel());
    unawaited(attempt.stderrSub?.cancel());
    // The close starts before the request's gap is reported. A failed
    // start or close leaves nothing to wait for.
    final process = attempt.process;
    final closing =
        (process != null
                ? Future.sync(process.close)
                : attempt.started.then((late) => late.close()))
            .then((_) {}, onError: (Object _) {});
    _closing.add(closing);
    unawaited(closing.whenComplete(() => _closing.remove(closing)));

    final pending = _pending;
    if (pending != null && identical(pending.attempt, attempt)) {
      _pending = null;
      pending.complete(SamplerGap(pending.seq, reason));
    }
  }

  // -- requests -------------------------------------------------------

  Future<SamplerOutcome> _request(
    _RequestKind requestKind,
    List<Collector> collectors,
    String Function(int seq) encode,
  ) {
    final attempt = _attempt;
    final String line;
    try {
      // Encoded before the state checks, so a refused request fails the
      // same way whatever the sampler is doing.
      line = encode((attempt?.seq ?? 0) + 1);
    } on HwsRequestError catch (e, s) {
      return Future.error(e, s);
    }
    if (_stopped) return _skip(SamplerSkipReason.stopped);
    if (attempt == null || !attempt.ready || attempt.ended) {
      return _skip(SamplerSkipReason.notReady);
    }
    if (_pending != null) {
      if (requestKind == _RequestKind.tick) _skipped++;
      return _skip(SamplerSkipReason.busy);
    }

    final seq = ++attempt.seq;
    final deadline = _deadlines.forRequest(kind, collectors);
    final pending = _Pending(
      attempt,
      seq,
      Timer(
        deadline,
        () => _fault(
          attempt,
          SamplerFault.requestDeadline,
          'no reply to $seq within $deadline',
        ),
      ),
    );
    _pending = pending;
    _write(attempt, line);
    return pending.completer.future;
  }

  _Pending? _takePending(_Attempt attempt, int seq) {
    final pending = _pending;
    if (!identical(pending?.attempt, attempt) || pending?.seq != seq) {
      return null;
    }
    _pending = null;
    return pending;
  }

  void _write(_Attempt attempt, String text) {
    try {
      attempt.stdin!.add(utf8.encode(text));
    } on Object catch (e) {
      _fault(attempt, SamplerFault.exited, 'stdin: $e');
    }
  }

  Future<SamplerOutcome> _wrongSampler(Collector c) => Future.error(
    HwsRequestError('runs on the ${c.sampler.name} sampler', collector: c),
  );

  static Future<SamplerOutcome> _skip(SamplerSkipReason reason) =>
      Future.value(SamplerSkipped(reason));

  void _setState(SamplerState next) {
    _state = next;
    if (!_states.isClosed) _states.add(next);
  }

  /// 128 bits of nonce per process (03 §6.2).
  static final _nonceSource = Random.secure();
  static final _jitter = Random();

  static Duration _defaultRestartDelay(int failures) =>
      samplerRestartDelay(failures, _jitter);
}

enum _RequestKind { tick, onDemand }

/// One process of a session, from [SshLink.start] to its close.
final class _Attempt {
  _Attempt(this.nonce, this.started)
    : assembler = HwsTickAssembler(nonce: nonce);

  final String nonce;
  final Future<RemoteProcess> started;
  final HwsTickAssembler assembler;
  RemoteProcess? process;
  StreamSink<List<int>>? stdin;
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
  Timer? readyTimer;
  bool ready = false;
  bool ended = false;

  /// The last request number written to this process.
  int seq = 0;
}

/// The one outstanding request.
final class _Pending {
  _Pending(this.attempt, this.seq, this._deadline);

  final _Attempt attempt;
  final int seq;
  final Timer _deadline;
  final completer = Completer<SamplerOutcome>();

  void complete(SamplerOutcome outcome) {
    _deadline.cancel();
    completer.complete(outcome);
  }
}

/// The last [capacity] bytes added.
final class _ByteRing {
  _ByteRing(this.capacity);

  final int capacity;
  final List<int> bytes = [];

  void add(List<int> chunk) {
    final keep = min(chunk.length, capacity);
    bytes.addAll(chunk.sublist(chunk.length - keep));
    if (bytes.length > capacity) bytes.removeRange(0, bytes.length - capacity);
  }
}
