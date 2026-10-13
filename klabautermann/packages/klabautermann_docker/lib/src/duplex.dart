import 'dart:async';

/// Minimal byte-duplex seam this package consumes (03 §3.3).
///
/// `klabautermann_core` adapts `seance_core`'s `ByteDuplex` (opened by
/// `SshLink.openUnixStream` over `direct-streamlocal`, 03 §5.4) to this
/// interface, so no SSH type ever reaches this package.
abstract interface class ByteDuplex {
  /// Bytes received from the peer. Single-subscription; the client listens
  /// once when the duplex opens (listen-before-write, 03 §5.4).
  Stream<List<int>> get stream;

  /// Sink for bytes to send to the peer.
  StreamSink<List<int>> get sink;

  /// Sends EOF to the peer while the read side stays open. 03 §5.7: stdin
  /// EOF on a hijacked exec stream is a channel half-close.
  Future<void> closeWrite();

  /// Closes both directions. Bounded; never hangs.
  Future<void> close();

  /// Completes once the duplex is fully closed, from either side.
  Future<void> get done;
}

/// Opens one byte duplex toward the engine socket (03 §3.3). The endpoint
/// (socket path, relay rank of 03 §5.9) is bound by the caller; each
/// invocation must open a fresh duplex.
typedef DuplexOpener = Future<ByteDuplex> Function();

/// A hijacked connection handed to the caller (03 §5.5 and §5.7): the raw
/// duplex plus any response bytes already buffered past the headers.
///
/// The positional arguments carry the lifecycle of the underlying duplex
/// in order: [done], the half-close [closeWrite] action and the terminal
/// [close] action.
final class HijackedDuplex {
  HijackedDuplex(
    this._done,
    this._closeWrite,
    this._close, {
    required this.stream,
    required this.sink,
  });

  /// Remaining inbound bytes: the buffered remainder first, then live data.
  final Stream<List<int>> stream;

  /// Raw bytes to the daemon (for example exec stdin).
  final StreamSink<List<int>> sink;

  final Future<void> _done;
  final Future<void> Function() _closeWrite;
  final Future<void> Function() _close;

  /// Completes when the underlying duplex closes.
  Future<void> get done => _done;

  /// Half-close: stdin EOF while stdout/stderr keep flowing.
  Future<void> closeWrite() => _closeWrite();

  /// Closes the duplex. After this the stream ends and writes fail.
  Future<void> close() => _close();
}
