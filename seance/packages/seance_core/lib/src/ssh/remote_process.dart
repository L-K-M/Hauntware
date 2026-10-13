import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'byte_duplex.dart';
import 'channel_budget.dart';
import 'remote_command.dart';
import 'sequential_cleanup.dart';

/// PTY dimensions for [SshLink.start].
///
/// The link does not know the terminal's size; the caller that does supplies
/// it. `term` follows the shell's own advertised type when omitted.
final class PtyRequest {
  const PtyRequest({required this.cols, required this.rows, this.term});

  final int cols;
  final int rows;
  final String? term;
}

/// How a remote process ended: an exit status, an exit signal, or neither
/// when the channel dropped before the server reported either.
final class RemoteExit {
  const RemoteExit({this.exitCode, this.exitSignal});

  final int? exitCode;
  final String? exitSignal;

  @override
  String toString() =>
      'RemoteExit(exitCode: $exitCode, exitSignal: $exitSignal)';
}

/// Signals [RemoteProcess.signal] can send, mapped to the SSH wire names.
enum RemoteSignal { hup, int_, quit, kill, term, usr1, usr2 }

/// A running remote process on its own session channel.
///
/// [stdout] is backpressured like a [ByteDuplex]: bytes buffer while no
/// listener is attached and the channel pauses past the bound, so the remote
/// process stalls rather than the buffer growing without limit. [stderr] is
/// drained unconditionally so the remote process never stalls on an unread
/// diagnostic stream. Closing [stdin] sends channel EOF.
abstract interface class RemoteProcess {
  /// Inbound stdout; replayed for a listener that attaches late.
  Stream<List<int>> get stdout;

  /// Inbound stderr, always drained.
  Stream<List<int>> get stderr;

  /// The process's stdin; [StreamSink.close] sends channel EOF.
  StreamSink<List<int>> get stdin;

  /// How the process ended; completes when the channel closes.
  Future<RemoteExit> get exit;

  /// Fire-and-forget signal; a dead channel swallows it.
  void signal(RemoteSignal signal);

  /// Signals TERM, closes the channel, and waits out a bounded close.
  Future<void> close();
}

/// A `List<int>` sink over dartssh2's `Uint8List` stdin channel.
final class _BytesToListSink implements StreamSink<List<int>> {
  _BytesToListSink(this._inner);

  final StreamSink<Uint8List> _inner;

  @override
  void add(List<int> data) =>
      _inner.add(data is Uint8List ? data : Uint8List.fromList(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(
    stream.map((data) => data is Uint8List ? data : Uint8List.fromList(data)),
  );

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}

/// dartssh2 exec channel wrapped as a [RemoteProcess]. Not barrel-exported:
/// the public surface stays free of dartssh2 types.
final class SshRemoteProcess implements RemoteProcess {
  SshRemoteProcess(
    this._session,
    this._grant, {
    this.onClosed,
    void Function()? onData,
  }) {
    _stdout = InboundReplay(
      _session.stdout,
      maxBufferedBytes: _processBufferLimit,
      onData: onData,
    );
    // No bound: stderr is drained unconditionally so the remote process
    // cannot stall on an unread diagnostic stream.
    _stderr = InboundReplay(_session.stderr, onData: onData);
    _exit = _session.done
        .then(
          (_) => RemoteExit(
            exitCode: _session.exitCode,
            exitSignal: _session.exitSignal?.signalName,
          ),
        )
        .whenComplete(() {
          _grant.release();
          onClosed?.call();
        });
  }

  final SSHSession _session;
  final ChannelGrant _grant;

  /// Runs when the channel ends in either direction, however it ended.
  final void Function()? onClosed;

  final _cleanup = SingleFlightCleanup();
  late final InboundReplay _stdout;
  late final InboundReplay _stderr;
  late final Future<RemoteExit> _exit;

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  StreamSink<List<int>> get stdin => _BytesToListSink(_session.stdin);

  @override
  Future<RemoteExit> get exit => _exit;

  @override
  void signal(RemoteSignal signal) {
    try {
      _session.kill(signal._sshSignal);
    } catch (_) {
      // Fire-and-forget: signalling a channel that already closed is a no-op.
    }
  }

  @override
  Future<void> close() => _cleanup.run(
    () => runSequentialCleanup([
      () => signal(RemoteSignal.term),
      _session.close,
      _stdout.cancel,
      _stderr.cancel,
      // dartssh2 sends CHANNEL_CLOSE only once the peer answers its EOF, so a
      // peer that never replies would leave `exit` pending forever. Destroying
      // after the polite close hangs up locally and completes `exit`, which is
      // what a bounded close has to guarantee.
      () => _session.channel.destroy(),
      _grant.release,
    ], actionTimeout: _closeBound),
  );
}

/// Pre-listen bound per process stream (see [InboundReplay]).
const _processBufferLimit = 4 * 1024 * 1024;
const _closeBound = Duration(seconds: 5);

extension on RemoteSignal {
  SSHSignal get _sshSignal => switch (this) {
    RemoteSignal.hup => SSHSignal.HUP,
    RemoteSignal.int_ => SSHSignal.INT,
    RemoteSignal.quit => SSHSignal.QUIT,
    RemoteSignal.kill => SSHSignal.KILL,
    RemoteSignal.term => SSHSignal.TERM,
    RemoteSignal.usr1 => SSHSignal.USR1,
    RemoteSignal.usr2 => SSHSignal.USR2,
  };
}

/// The capture engine shared by `SshSession.runCommand` and `SshLink.run`:
/// same channel lifecycle, same caps, same deadline, same error surface.
/// Not barrel-exported: it speaks dartssh2 channels.
///
/// Owners supply [isDisconnected]/[disconnectedMessage] because the two call
/// sites word the dead-link error differently ('session' vs 'link'); every
/// other byte of behavior is identical.
final class ExecCore {
  const ExecCore({
    required this.isDisconnected,
    required this.disconnectedMessage,
  });

  /// Dead-transport probe checked before opening and after a mid-run failure.
  final bool Function() isDisconnected;

  /// The wording of the [RemoteCommandException] a dead transport produces.
  final String disconnectedMessage;

  /// Opens a fresh non-PTY channel through [open], captures both output
  /// streams bounded at [maxOutputBytes], and waits one deadline across
  /// stream completion and `channel.done`.
  ///
  /// [openTimeout] bounds the channel open itself when the caller's open can
  /// stall behind a queue or an uncooperative peer; [stdin] bytes, when
  /// given, are written and sealed with EOF before output is awaited.
  Future<RemoteCommandResult> run(
    String command, {
    required Future<SSHSession> Function() open,
    Duration? openTimeout,
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    final effectiveTimeout = timeout ?? const Duration(seconds: 30);
    if (isDisconnected()) {
      throw RemoteCommandException(disconnectedMessage);
    }
    final SSHSession channel;
    try {
      final pending = open();
      channel = await (openTimeout == null
          ? pending
          : pending.timeout(openTimeout));
    } on ChannelOpenException {
      rethrow;
    } catch (e) {
      if (isDisconnected()) {
        throw RemoteCommandException(disconnectedMessage);
      }
      throw RemoteCommandException('Could not open a command channel: $e');
    }

    if (stdin != null) {
      channel.write(Uint8List.fromList(stdin));
      unawaited(channel.stdin.close());
    }

    final stdout = BytesBuilder(copy: false);
    final stderr = BytesBuilder(copy: false);
    var truncated = false;
    final stdoutDone = Completer<void>();
    final stderrDone = Completer<void>();

    void collect(Uint8List data, BytesBuilder into) {
      final remaining = maxOutputBytes - into.length;
      if (data.length <= remaining) {
        into.add(data);
      } else {
        if (remaining > 0) {
          into.add(Uint8List.sublistView(data, 0, remaining));
        }
        truncated = true;
      }
    }

    final subscriptions = <StreamSubscription<Uint8List>>[
      channel.stdout.listen(
        (data) => collect(data, stdout),
        onDone: stdoutDone.complete,
        onError: stdoutDone.completeError,
        cancelOnError: true,
      ),
      channel.stderr.listen(
        (data) => collect(data, stderr),
        onDone: stderrDone.complete,
        onError: stderrDone.completeError,
        cancelOnError: true,
      ),
    ];

    Future<void> abort() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      channel.done.ignore();
      channel.close();
    }

    // One deadline across both waits: two independent effectiveTimeout
    // windows could otherwise hold the caller for twice the configured time.
    // A stopwatch keeps the arithmetic monotonic where DateTime would
    // inherit wall-clock adjustments.
    final stopwatch = Stopwatch()..start();
    try {
      // Both stream completions are awaited together: awaiting them one after
      // the other would leave the second without an error handler until the
      // first finished.
      await Future.wait([
        stdoutDone.future,
        stderrDone.future,
      ], eagerError: true).timeout(effectiveTimeout);
      final remaining = effectiveTimeout - stopwatch.elapsed;
      await channel.done.timeout(
        remaining.isNegative ? Duration.zero : remaining,
      );
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      return RemoteCommandResult(
        stdout: utf8.decode(stdout.takeBytes(), allowMalformed: true),
        stderr: utf8.decode(stderr.takeBytes(), allowMalformed: true),
        exitCode: channel.exitCode,
        truncated: truncated,
      );
    } on TimeoutException {
      await abort();
      throw RemoteCommandException(
        'The command did not finish within ${effectiveTimeout.inSeconds}s.',
      );
    } catch (e) {
      await abort();
      if (isDisconnected()) {
        throw RemoteCommandException(disconnectedMessage);
      }
      throw RemoteCommandException('The command channel failed: $e', cause: e);
    }
  }
}
