/// In-memory test doubles for the [ByteDuplex] seam and the recorded
/// API corpus. Separate from the barrel so consumers never ship test
/// helpers; used by this package's own tests and by
/// `klabautermann_core`'s fakes (03 §11.1 fake-transport layer).
library;

import 'dart:async';

import 'klabautermann_docker.dart' show ByteDuplex;

export 'src/testing/recorded_daemon.dart'
    show RecordedChunking, RecordedCorpus, RecordedDaemon, RecordedExchange;

/// An in-memory pair of connected [ByteDuplex] ends: [client] is given
/// to the code under test, [server] is scripted by the test. Bytes
/// written to one end appear on the other's stream. [ByteDuplex.close]
/// kills both directions; [ByteDuplex.closeWrite] half-closes only the
/// writer's direction.
final class FakeDuplexPair {
  FakeDuplexPair() {
    client = _FakeDuplexEnd(_clientToServer, _serverToClient);
    server = _FakeDuplexEnd(_serverToClient, _clientToServer);
    (client as _FakeDuplexEnd)._peer = server as _FakeDuplexEnd;
    (server as _FakeDuplexEnd)._peer = client as _FakeDuplexEnd;
  }

  final StreamController<List<int>> _clientToServer =
      StreamController<List<int>>();
  final StreamController<List<int>> _serverToClient =
      StreamController<List<int>>();

  late final ByteDuplex client;
  late final ByteDuplex server;

  /// True while the client's subscription on its inbound stream is
  /// paused (the backpressure signal of 03 §5.5).
  bool get clientReadPaused => _serverToClient.isPaused;

  /// True while the server-end subscription is paused.
  bool get serverReadPaused => _clientToServer.isPaused;
}

final class _FakeDuplexEnd implements ByteDuplex {
  _FakeDuplexEnd(this._out, this._inbound);

  /// Feeds the peer's stream; also this end's sink.
  final StreamController<List<int>> _out;

  /// What the peer writes; this end's stream.
  final StreamController<List<int>> _inbound;

  _FakeDuplexEnd? _peer;
  bool _closed = false;
  final Completer<void> _done = Completer<void>();

  @override
  Stream<List<int>> get stream => _inbound.stream;

  @override
  StreamSink<List<int>> get sink => _out;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> closeWrite() {
    final f = _out.close();
    _maybeDone();
    return f;
  }

  @override
  Future<void> close() {
    if (_closed) return _done.future;
    _closed = true;
    unawaited(_out.close());
    unawaited(_inbound.close());
    _peer?._peerClosed();
    _done.complete();
    return _done.future;
  }

  /// The peer fully closed: both directions die, writes start failing.
  void _peerClosed() {
    if (_closed) return;
    _closed = true;
    unawaited(_out.close());
    unawaited(_inbound.close());
    _done.complete();
  }

  /// Both directions half-closed means the duplex is done.
  void _maybeDone() {
    if (_out.isClosed && _inbound.isClosed && !_done.isCompleted) {
      _done.complete();
      _peer?._maybeDone();
    }
  }
}
