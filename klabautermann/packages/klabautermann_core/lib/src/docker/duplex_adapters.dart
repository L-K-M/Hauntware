/// The two byte duplexes the Docker client runs over (03 §3.3, §5.9):
/// a `direct-streamlocal` channel for rank 1, and a relay process's stdin
/// and stdout for the relay ranks. Both adapt `seance_core` types to
/// `klabautermann_docker`'s [ByteDuplex], so no SSH type reaches that
/// package.
library;

import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart' show ByteDuplex;
import 'package:seance_core/seance_core.dart'
    as ssh
    show ByteDuplex, RemoteExit, RemoteProcess;

/// The most bytes of a relay's stderr a [ProcessDuplex] keeps, its last
/// ones [E]: enough for the CLI's or socat's closing error line, such as
/// a refused connect or an unknown command.
const kRelayStderrMaxBytes = 4096;

/// An `SshLink.openUnixStream` channel as the Docker client's duplex.
/// Closing the channel's sink sends channel EOF and leaves its read side
/// open (`seance_core`'s `ByteDuplex.sink`), which is the half-close
/// [closeWrite] promises.
final class SshDuplexAdapter implements ByteDuplex {
  SshDuplexAdapter(this._channel);

  final ssh.ByteDuplex _channel;

  @override
  Stream<List<int>> get stream => _channel.stream;

  @override
  StreamSink<List<int>> get sink => _channel.sink;

  @override
  Future<void> closeWrite() => _channel.sink.close();

  @override
  Future<void> close() => _channel.close();

  @override
  Future<void> get done => _channel.done;
}

/// A relay process (`docker system dial-stdio`, `socat`, `nc -U`; 03
/// §5.9) as the Docker client's duplex: its stdout is the daemon's
/// bytes, its stdin the client's. The process's exit is the duplex's
/// close, so its stdout ends with it and [done] completes.
///
/// `seance_core` drains stderr unconditionally so the relay never stalls
/// on it; this keeps only its last [kRelayStderrMaxBytes] bytes, which
/// say why a relay ended early ([diagnostics]).
final class ProcessDuplex implements ByteDuplex {
  ProcessDuplex(this._process) {
    _process.stderr.listen(_keepStderr, onError: (Object _) {});
  }

  final ssh.RemoteProcess _process;
  final _stderrTail = <int>[];

  /// The relay's last stderr bytes, decoded leniently; empty when it
  /// wrote none.
  String get diagnostics => utf8.decode(_stderrTail, allowMalformed: true);

  /// How the relay ended.
  Future<ssh.RemoteExit> get exit => _process.exit;

  @override
  Stream<List<int>> get stream => _process.stdout;

  @override
  StreamSink<List<int>> get sink => _process.stdin;

  /// Stdin EOF: `dial-stdio`, socat and `nc -U` pass it on as a
  /// half-close of the socket and keep relaying the daemon's bytes.
  @override
  Future<void> closeWrite() => _process.stdin.close();

  /// `RemoteProcess.close`: TERM, then a bounded channel close.
  @override
  Future<void> close() => _process.close();

  @override
  Future<void> get done => _process.exit.then((_) {});

  void _keepStderr(List<int> chunk) {
    _stderrTail.addAll(chunk);
    final excess = _stderrTail.length - kRelayStderrMaxBytes;
    if (excess > 0) _stderrTail.removeRange(0, excess);
  }
}
