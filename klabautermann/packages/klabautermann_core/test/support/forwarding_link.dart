// An SshLink double for the Docker ladder: streamlocal opens reach fake
// daemons or are refused as sshd refuses them, the exec probe answers
// as scripted (or in a real local `sh`), and relay starts reach a fake
// daemon through a process's stdin and stdout.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_docker/klabautermann_docker.dart'
    as docker
    show ByteDuplex;
import 'package:klabautermann_docker/testing.dart';
import 'package:seance_core/seance_core.dart';

import 'scripted_link.dart';

/// A daemon behind a socket that answers each request head (bodies are
/// not read) with [respond]'s raw response, or as [handle] does, keeping
/// the connection alive.
abstract base class FakeDaemon {
  /// The request lines received, across connections.
  final requests = <String>[];

  /// How many connections were opened; [closed] of them have ended.
  int connections = 0;
  int closed = 0;

  /// The raw HTTP response to [requestLine].
  String respond(String requestLine);

  /// Answers [requestLine] on [connection]'s server end; a daemon that
  /// streams or holds an answer overrides it.
  void handle(String requestLine, FakeDuplexPair connection) =>
      connection.server.sink.add(utf8.encode(respond(requestLine)));

  /// The client end of a fresh connection. The daemon closes its end
  /// once the client's EOF arrives.
  FakeDuplexPair connect() {
    final pair = FakeDuplexPair();
    connections++;
    var pending = '';
    pair.server.stream.listen(
      (chunk) {
        pending += latin1.decode(chunk);
        for (
          var at = pending.indexOf('\r\n\r\n');
          at >= 0;
          at = pending.indexOf('\r\n\r\n')
        ) {
          final line = pending.substring(0, pending.indexOf('\r\n'));
          requests.add(line);
          pending = pending.substring(at + 4);
          handle(line, pair);
        }
      },
      onDone: () {
        closed++;
        unawaited(pair.server.close());
      },
    );
    return pair;
  }
}

/// A daemon that answers every request with `200 OK` and an empty body,
/// as `/_ping` does.
final class PingDaemon extends FakeDaemon {
  @override
  String respond(String requestLine) => _ok;

  static const _ok =
      'HTTP/1.1 200 OK\r\nApi-Version: 1.52\r\nContent-Length: 0\r\n\r\n';
}

/// How [ForwardingLink.run] answers the exec probe.
enum ProbeShell {
  /// From [ForwardingLink.probeAnswers], by the path the command ends
  /// with.
  scripted,

  /// By running the command in the local `sh`, as sshd hands it to the
  /// login shell, in [ForwardingLink.workingDirectory].
  local,
}

/// Serves the calls the Docker ladder and its duplexes make.
final class ForwardingLink extends TestLinkBase {
  ForwardingLink({this.probeShell = ProbeShell.scripted});

  final ProbeShell probeShell;

  /// Socket paths a daemon answers on. Every other path is refused with
  /// `forwardDisabled`, as OpenSSH answers every failed streamlocal open
  /// alike (03 §5.3).
  final daemons = <String, FakeDaemon>{};

  /// The daemon every relay start reaches.
  FakeDaemon relayDaemon = PingDaemon();

  /// The exec probe's stdout per socket path ([ProbeShell.scripted]).
  final probeAnswers = <String, String>{};

  /// The exit status the scripted probe reports.
  int probeExitCode = 0;

  /// Programs whose relay exits with an error once a request arrives, as
  /// a CLI that cannot reach the daemon does; matched as a quoted word of
  /// the command line.
  final failingRelays = <String>{};

  /// Errors the next runs throw, in order.
  final runFailures = <Object>[];

  /// Errors the next streamlocal opens throw before any daemon lookup.
  final openFailures = <Object>[];

  /// The working directory of [ProbeShell.local] runs.
  String? workingDirectory;

  final opens = <String>[];
  final commands = <String>[];
  final started = <String>[];
  final relays = <RelayProcess>[];

  @override
  Future<ByteDuplex> openUnixStream(String socketPath) async {
    opens.add(socketPath);
    if (openFailures.isNotEmpty) throw openFailures.removeAt(0);
    final daemon = daemons[socketPath];
    if (daemon == null) {
      throw const ChannelOpenException(
        ChannelRefusal.forwardDisabled,
        'The server refused forwarding: open failed',
      );
    }
    return _ChannelEnd(daemon.connect().client);
  }

  @override
  Future<RemoteCommandResult> run(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
    List<int>? stdin,
  }) async {
    commands.add(command);
    if (runFailures.isNotEmpty) throw runFailures.removeAt(0);
    if (probeShell == ProbeShell.local) {
      final r = await Process.run('sh', [
        '-c',
        command,
      ], workingDirectory: workingDirectory);
      return RemoteCommandResult(
        stdout: r.stdout as String,
        stderr: r.stderr as String,
        exitCode: r.exitCode,
      );
    }

    for (final MapEntry(key: path, value: stdout) in probeAnswers.entries) {
      if (command.endsWith(' ${quoteShellWord(path)}')) {
        return RemoteCommandResult(stdout: stdout, exitCode: probeExitCode);
      }
    }
    throw StateError('no scripted probe answer for $command');
  }

  @override
  Future<RemoteProcess> start(String command, {PtyRequest? pty}) async {
    started.add(command);
    final failing = failingRelays.any(
      (program) => command.contains(" '$program' "),
    );
    final pair = failing ? FakeDuplexPair() : relayDaemon.connect();
    final relay = RelayProcess(pair.client);
    relays.add(relay);
    // It fails once the request arrives, so the client sees the exit
    // rather than a refused write.
    if (failing) {
      pair.server.stream.listen(
        (_) => unawaited(relay.fail(utf8.encode('Cannot connect\n'))),
      );
    }
    return relay;
  }
}

/// A forwarding channel over a fake duplex end, with `seance_core`'s
/// half-close: closing the sink sends EOF and keeps reading.
final class _ChannelEnd implements ByteDuplex {
  _ChannelEnd(this._end);

  final docker.ByteDuplex _end;

  @override
  Stream<List<int>> get stream => _end.stream;

  @override
  StreamSink<List<int>> get sink => _end.sink;

  @override
  Future<void> get done => _end.done;

  @override
  Future<void> close() => _end.close();
}

/// A relay process whose stdin and stdout are a fake duplex end: it
/// exits with 0 when the connection closes, or as [fail] says.
final class RelayProcess implements RemoteProcess {
  RelayProcess(this._end) {
    unawaited(_end.done.then((_) => _finish(const RemoteExit(exitCode: 0))));
  }

  final docker.ByteDuplex _end;
  final _stderr = StreamController<List<int>>();
  final _exit = Completer<RemoteExit>();
  int closeCalls = 0;

  /// Writes [stderr] and exits with [exitCode], as a relay that cannot
  /// reach the daemon does.
  Future<void> fail(List<int> stderr, {int exitCode = 1}) async {
    _stderr.add(stderr);
    _finish(RemoteExit(exitCode: exitCode));
    await _end.close();
  }

  void _finish(RemoteExit exit) {
    if (_exit.isCompleted) return;
    unawaited(_stderr.close());
    _exit.complete(exit);
  }

  @override
  Stream<List<int>> get stdout => _end.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  StreamSink<List<int>> get stdin => _end.sink;

  @override
  Future<RemoteExit> get exit => _exit.future;

  @override
  void signal(RemoteSignal signal) {}

  @override
  Future<void> close() async {
    closeCalls++;
    _finish(const RemoteExit(exitSignal: 'TERM'));
    await _end.close();
  }
}
