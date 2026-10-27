/// What the engine's links carry, read from inside the engine isolate for
/// the soak (03 §11.4, K28b) through the test seams that already exist:
/// [IsolateEngineClient.spawn]'s `entryPoint` and [engineMain]'s `dial`.
/// Each link the engine dials is the real [SshLink], wrapped to count its
/// open channels and the bytes on its process channels; nothing in the
/// engine or in `seance_core` changes, and the engine cannot tell.
///
/// A sampler writes one request line (`hw_t` or `hw_o`) and the next only
/// after the reply has arrived (03 §6.2), so the stdout bytes between two
/// request lines are the first request's reply: the figure 03 §11.4's
/// tick budget names, as S2 and S5 measured it
/// (`klabautermann/docs/evidence/s5/README.md`, "Bytes").
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:klabautermann_core/klabautermann_core.dart'
    show EngineStart, IsolateEngineClient;
import 'package:klabautermann_core/src/engine/engine_isolate.dart'
    show engineMain;
import 'package:seance_core/seance_core.dart';

/// The test isolate's side: the entry point to spawn the engine with, and
/// readings of its links.
final class LinkMeter {
  LinkMeter() {
    _engineSide = _replies.first.then((port) => port as SendPort);
  }

  final _replies = ReceivePort('klabautermann link meter');
  late final Future<SendPort> _engineSide;

  /// The engine's own entry point with every dialed link metered. Pass it
  /// to [IsolateEngineClient.spawn] once.
  void Function(EngineStart start) get entryPoint {
    final port = _replies.sendPort;
    return (start) => _meteredEngine(port, start);
  }

  /// Every link the engine has dialed so far, in dial order, as plain
  /// JSON-encodable data:
  ///
  /// ```text
  /// {dials, links: [{serverId, state, channels: {processes, runs,
  ///   duplexes, fileSystems}, stdoutBytes, stderrBytes, stdinBytes,
  ///   replies: {<collectors>: [bytes, ...]}}]}
  /// ```
  ///
  /// `replies` holds each finished reply's size by the collectors its
  /// request named (`core`, `overview`, `probe`), oldest first; a reply
  /// counts as finished once the next request on its channel is written.
  Future<Map<String, Object?>> read() async {
    final answer = ReceivePort('klabautermann link meter reading');
    try {
      (await _engineSide.timeout(const Duration(seconds: 10)))
          .send(answer.sendPort);
      return await answer.first.timeout(const Duration(seconds: 10))
          as Map<String, Object?>;
    } finally {
      answer.close();
    }
  }

  void close() => _replies.close();
}

/// Runs in the engine isolate: hands [meter] a port for readings, then
/// becomes the engine.
void _meteredEngine(SendPort meter, EngineStart start) {
  final links = <_MeteredLink>[];
  final readings = ReceivePort('klabautermann link meter requests');
  meter.send(readings.sendPort);
  readings.listen((answer) {
    (answer as SendPort).send({
      'dials': links.length,
      'links': [for (final link in links) link.reading()],
    });
  });

  engineMain(
    start,
    dial:
        ({
          required config,
          required credentials,
          required tofu,
          required onHostKey,
          onKeyboardInteractive,
          resolveJumpHost,
        }) async {
          final link = _MeteredLink(
            await SshLink.connect(
              config: config,
              credentials: credentials,
              tofu: tofu,
              onHostKey: onHostKey,
              onKeyboardInteractive: onKeyboardInteractive,
              resolveJumpHost: resolveJumpHost,
            ),
          );
          links.add(link);
          return link;
        },
  );
}

/// [SshLink] with its channels and process bytes counted.
final class _MeteredLink implements SshLink {
  _MeteredLink(this._inner);

  final SshLink _inner;

  /// Open channels by kind: processes until their exit, runs while they
  /// run, forwarding duplexes until done. The SFTP lease is lazy and
  /// internal to the link, so only its requests are counted.
  var _processes = 0, _runs = 0, _duplexes = 0, _fileSystems = 0;

  var _stdoutBytes = 0, _stderrBytes = 0, _stdinBytes = 0;
  final _replies = <String, List<int>>{};

  Map<String, Object?> reading() => {
    'serverId': config.id,
    'state': '${state.runtimeType}',
    'channels': {
      'processes': _processes,
      'runs': _runs,
      'duplexes': _duplexes,
      'fileSystems': _fileSystems,
    },
    'stdoutBytes': _stdoutBytes,
    'stderrBytes': _stderrBytes,
    'stdinBytes': _stdinBytes,
    'replies': {
      for (final MapEntry(:key, :value) in _replies.entries) key: [...value],
    },
  };

  @override
  ServerConfig get config => _inner.config;

  @override
  SshLinkState get state => _inner.state;

  @override
  Stream<SshLinkState> get states => _inner.states;

  @override
  SshLinkSeen get seen => _inner.seen;

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    _runs++;
    try {
      return await _inner.run(
        command,
        timeout: timeout,
        maxOutputBytes: maxOutputBytes,
        stdin: stdin,
      );
    } finally {
      _runs--;
    }
  }

  @override
  Future<RemoteProcess> start(String command, {PtyRequest? pty}) async {
    final process = _MeteredProcess(
      await _inner.start(command, pty: pty),
      this,
    );
    _processes++;
    unawaited(
      process._inner.exit.then(
        (_) => _processes--,
        onError: (Object _) => _processes--,
      ),
    );
    return process;
  }

  @override
  Future<ByteDuplex> openUnixStream(String socketPath) =>
      _track(_inner.openUnixStream(socketPath));

  @override
  Future<ByteDuplex> openTcpStream(String host, int port) =>
      _track(_inner.openTcpStream(host, port));

  Future<ByteDuplex> _track(Future<ByteDuplex> opening) async {
    final duplex = await opening;
    _duplexes++;
    unawaited(
      duplex.done.then((_) => _duplexes--, onError: (Object _) => _duplexes--),
    );
    return duplex;
  }

  @override
  Future<RemoteFileSystem> openFileSystem() {
    _fileSystems++;
    return _inner.openFileSystem();
  }

  @override
  Future<void> close() => _inner.close();
}

/// [RemoteProcess] whose stdin and output bytes [link] counts, splitting
/// stdout into replies at each request line written to stdin.
final class _MeteredProcess implements RemoteProcess {
  _MeteredProcess(this._inner, this._link);

  final RemoteProcess _inner;
  final _MeteredLink _link;

  /// The collectors the request being answered named, and its reply's
  /// bytes so far; null before the first request (the program's READY).
  String? _answering;
  var _replyBytes = 0;

  @override
  late final Stream<List<int>> stdout = _inner.stdout.map((chunk) {
    _link._stdoutBytes += chunk.length;
    if (_answering != null) _replyBytes += chunk.length;
    return chunk;
  });

  @override
  late final Stream<List<int>> stderr = _inner.stderr.map((chunk) {
    _link._stderrBytes += chunk.length;
    return chunk;
  });

  @override
  late final StreamSink<List<int>> stdin = _CountingSink(_inner.stdin, _wrote);

  void _wrote(List<int> bytes) {
    _link._stdinBytes += bytes.length;
    // `hw_t <seq> <collector>...` or `hw_o <seq> <collector> <arg>...`
    // (03 §6.2), always written whole; the program text is not a request.
    if (bytes.length < 5 || bytes[0] != 0x68 || bytes[1] != 0x77) return;
    final line = latin1.decode(bytes).trimRight();
    final words = line.split(' ');
    if (words.length < 3 || (words[0] != 'hw_t' && words[0] != 'hw_o')) {
      return;
    }

    final previous = _answering;
    if (previous != null) {
      (_link._replies[previous] ??= []).add(_replyBytes);
    }
    _answering = words[0] == 'hw_o' ? words[2] : words.skip(2).join(' ');
    _replyBytes = 0;
  }

  @override
  Future<RemoteExit> get exit => _inner.exit;

  @override
  void signal(RemoteSignal signal) => _inner.signal(signal);

  @override
  Future<void> close() => _inner.close();
}

/// [StreamSink] that reports each chunk to [_onAdd] before passing it on.
final class _CountingSink implements StreamSink<List<int>> {
  _CountingSink(this._inner, this._onAdd);

  final StreamSink<List<int>> _inner;
  final void Function(List<int> bytes) _onAdd;

  @override
  void add(List<int> data) {
    _onAdd(data);
    _inner.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(
    stream.map((data) {
      _onAdd(data);
      return data;
    }),
  );

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;
}
