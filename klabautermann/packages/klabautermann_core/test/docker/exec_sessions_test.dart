// Container shells (03 §7.13, CTX-07) over a fake daemon that speaks the
// exec endpoints: the create and start bodies, the hijacked stream both
// ways, resize order, the exit code, refusals, and the slot given back.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/docker_router.dart'
    show DockerChannelUnavailable, DockerEndpointUnavailable;
import 'package:klabautermann_core/src/docker/docker_watch.dart'
    show DockerStreamLease;
import 'package:klabautermann_core/src/docker/exec_sessions.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:klabautermann_docker/testing.dart';
import 'package:test/test.dart';

/// A daemon for the exec endpoints. Each `start` keeps its connection as
/// the shell: what the client writes after it is the shell's input.
final class _ExecDaemon {
  final requests = <String>[];
  final bodies = <String, Map<String, Object?>>{};
  final resizes = <String>[];
  final shells = <String, FakeDuplexPair>{};
  final stdin = <String, BytesBuilder>{};
  final stdinClosed = <String>{};
  final exitCodes = <String, int>{};
  var _nextExec = 0;

  FakeDuplexPair connect() {
    final pair = FakeDuplexPair();
    final pending = <int>[];
    String? hijacked;
    pair.server.stream.listen(
      (chunk) {
        if (hijacked != null) {
          stdin[hijacked]!.add(chunk);
          return;
        }
        pending.addAll(chunk);
        while (true) {
          final text = latin1.decode(pending);
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) return;
          final head = text.substring(0, end).split('\r\n');
          final length =
              int.tryParse(
                head
                    .firstWhere(
                      (l) => l.toLowerCase().startsWith('content-length:'),
                      orElse: () => 'content-length: 0',
                    )
                    .split(':')[1]
                    .trim(),
              ) ??
              0;
          if (pending.length < end + 4 + length) return;
          final body = utf8.decode(pending.sublist(end + 4, end + 4 + length));
          pending.removeRange(0, end + 4 + length);
          hijacked = _handle(head.first, body, pair);
          if (hijacked != null) {
            stdin[hijacked!] = BytesBuilder()..add(pending);
            pending.clear();
            return;
          }
        }
      },
      onDone: () {
        if (hijacked != null) stdinClosed.add(hijacked!);
      },
    );
    return pair;
  }

  /// Answers one request; returns the exec id when it hijacked.
  String? _handle(String line, String body, FakeDuplexPair pair) {
    requests.add(line);
    final target = line.split(' ')[1];
    final path = Uri.parse(target).path;
    final segments = path.split('/');
    void json(String status, Object value) {
      final bytes = utf8.encode(jsonEncode(value));
      pair.server.sink
        ..add(
          latin1.encode(
            'HTTP/1.1 $status\r\nContent-Type: application/json\r\n'
            'Content-Length: ${bytes.length}\r\n\r\n',
          ),
        )
        ..add(bytes);
    }

    if (path.endsWith('/exec') && segments.contains('containers')) {
      final container = segments[segments.length - 2];
      if (container == 'gone') {
        json('404 Not Found', {'message': 'No such container: gone'});
        return null;
      }
      final id = 'e${++_nextExec}';
      bodies['create $id'] = jsonDecode(body) as Map<String, Object?>;
      json('201 Created', {'Id': id});
      return null;
    }
    final id = segments[segments.length - 2];
    if (path.endsWith('/start')) {
      bodies['start $id'] = jsonDecode(body) as Map<String, Object?>;
      shells[id] = pair;
      pair.server.sink.add(
        latin1.encode(
          'HTTP/1.1 101 UPGRADED\r\nContent-Type: '
          'application/vnd.docker.raw-stream\r\n'
          'Connection: Upgrade\r\nUpgrade: tcp\r\n\r\n',
        ),
      );
      return id;
    }
    if (path.endsWith('/resize')) {
      final query = Uri.parse(target).queryParameters;
      resizes.add('$id ${query['w']}x${query['h']}');
      json('200 OK', <String, Object?>{});
      return null;
    }
    if (path.endsWith('/json')) {
      json('200 OK', {
        'ID': id,
        'Running': false,
        'ExitCode': exitCodes[id] ?? 0,
      });
      return null;
    }
    json('404 Not Found', {'message': 'no route $path'});
    return null;
  }
}

const _policy = SafetyPolicy(
  servers: {'srv-1': ServerSafety(management: true)},
);

OpenTerminal _open({
  String id = 't-1',
  String container = 'c1',
  String? shell,
  String? user,
  int columns = 120,
  int rows = 40,
}) => OpenTerminal(
  terminalId: id,
  serverId: 'srv-1',
  containerId: container,
  shell: shell,
  user: user,
  columns: columns,
  rows: rows,
);

void main() {
  late _ExecDaemon daemon;
  late List<EngineEvent> events;
  late List<AuditRecord> audits;
  late int leases;
  late int released;
  late DockerRank rank;
  late Object? openFailure;
  late ExecSessions sessions;

  // Holds the short calls back while it is pending.
  Completer<void>? controlGate;

  // The endpoint's pooled client, for the short calls.
  late DockerClient pool;

  setUp(() {
    daemon = _ExecDaemon();
    pool = DockerClient(
      DockerHttpClient(() async => daemon.connect().client),
      apiVersion: const ApiVersion(1, 44),
    );
    events = [];
    audits = [];
    leases = 0;
    released = 0;
    rank = DockerRank.cliRelay;
    openFailure = null;
    controlGate = null;
    sessions = ExecSessions(
      open: (serverId) async {
        if (openFailure case final failure?) throw failure;
        leases++;
        return (
          lease: DockerStreamLease(
            DockerClient(
              DockerHttpClient(
                () async => daemon.connect().client,
                maxConnections: 1,
              ),
              apiVersion: const ApiVersion(1, 44),
            ),
            release: () => released++,
          ),
          rank: rank,
        );
      },
      control: <T>(serverId, call) async {
        await controlGate?.future;
        return call(pool);
      },
      emit: events.add,
      fleet: (serverId) => serverId == 'srv-1',
      audit: (record) async => audits.add(record),
    );
  });

  tearDown(() async {
    await sessions.dispose();
    await pool.close();
  });

  Future<void> settle() => pumpEventQueue(times: 50);

  List<int> output(String id) => [
    for (final event in events.whereType<TerminalBytes>())
      if (event.terminalId == id) ...event.bytes,
  ];

  TerminalClosed? closed(String id) => events
      .whereType<TerminalClosed>()
      .where((e) => e.terminalId == id)
      .firstOrNull;

  test('opens a TTY exec with the default shell, streams both ways and '
      'ends with the exit code, slot back and an audit record', () async {
    sessions.open(_open(), _policy);
    await settle();

    expect(daemon.bodies['create e1'], {
      'AttachStdin': true,
      'AttachStdout': true,
      'AttachStderr': true,
      'Tty': true,
      'Cmd': kDefaultShellCommand,
      'ConsoleSize': [40, 120],
    });
    expect(daemon.bodies['start e1'], {
      'Detach': false,
      'Tty': true,
      'ConsoleSize': [40, 120],
    });
    expect(
      events.whereType<TerminalOpened>().single.command,
      kDefaultShellCommand,
    );

    daemon.shells['e1']!.server.sink.add(utf8.encode('\$ '));
    sessions.input(
      TerminalInput('t-1', Uint8List.fromList(utf8.encode('ls\r'))),
    );
    await settle();
    expect(utf8.decode(output('t-1')), '\$ ');
    expect(utf8.decode(daemon.stdin['e1']!.toBytes()), 'ls\r');

    daemon.exitCodes['e1'] = 3;
    await daemon.shells['e1']!.server.close();
    await settle();

    final end = closed('t-1')!;
    expect(end.reason, TerminalCloseReason.exited);
    expect(end.exitCode, 3);
    expect(released, leases);
    expect(sessions.isOpen('t-1'), isFalse);
    final record = audits.single;
    expect(record.action, kTerminalAuditAction);
    expect(record.targetName, 'c1');
    expect(record.exitCode, 3);
    expect(record.outcome, ActionOutcome.succeeded);
  });

  test('runs the shell and user asked for', () async {
    sessions.open(_open(shell: '/bin/ash', user: 'app'), _policy);
    await settle();

    expect(daemon.bodies['create e1']?['Cmd'], ['/bin/ash']);
    expect(daemon.bodies['create e1']?['User'], 'app');
    expect(audits, isEmpty, reason: 'recorded once it ends');
  });

  group('refuses before any exec', () {
    test('an observe-only or read-only server, as actions are', () async {
      sessions
        ..open(_open(id: 'a'), const SafetyPolicy())
        ..open(_open(id: 'b'), const SafetyPolicy(globalReadOnly: true));
      await settle();

      expect(closed('a')?.reason, TerminalCloseReason.observeOnly);
      expect(closed('b')?.reason, TerminalCloseReason.readOnly);
      expect(leases, 0);
      expect(daemon.requests, isEmpty);
    });

    test('a server outside the fleet', () async {
      sessions.open(
        const OpenTerminal(
          terminalId: 'x',
          serverId: 'other',
          containerId: 'c1',
          columns: 80,
          rows: 24,
        ),
        _policy,
      );
      await settle();
      expect(closed('x')?.reason, TerminalCloseReason.notInFleet);
    });

    test('a fifth shell on one server', () async {
      for (var i = 0; i < kTerminalsPerServerMax + 1; i++) {
        sessions.open(_open(id: 't$i'), _policy);
      }
      await settle();

      expect(
        closed('t$kTerminalsPerServerMax')?.reason,
        TerminalCloseReason.tooMany,
      );
      expect(leases, kTerminalsPerServerMax);
    });

    test('a malformed request, which the engine rejects', () {
      sessions.open(_open(), _policy);
      expect(sessions.validate(_open()), contains('already open'));
      expect(sessions.validate(_open(id: 'n', columns: 0)), isNotNull);
      expect(sessions.validate(_open(id: 'n', container: '')), isNotNull);
      expect(sessions.validate(_open(id: 'n', shell: '')), isNotNull);
    });
  });

  group('fails to open', () {
    for (final (failure, reason) in [
      (const DockerChannelUnavailable(), TerminalCloseReason.noChannel),
      (
        const DockerEndpointUnavailable(DockerQueryFailure.endpointUnavailable),
        TerminalCloseReason.endpointUnavailable,
      ),
      (
        const DockerEndpointUnavailable(DockerQueryFailure.linkUnavailable),
        TerminalCloseReason.linkLost,
      ),
    ]) {
      test('as ${reason.name} when the endpoint says so', () async {
        openFailure = failure;
        sessions.open(_open(), _policy);
        await settle();
        expect(closed('t-1')?.reason, reason);
        expect(audits, isEmpty, reason: 'no shell ever ran');
      });
    }

    test(
      'as refused, with the daemon\'s words, for a gone container',
      () async {
        sessions.open(_open(container: 'gone'), _policy);
        await settle();

        final end = closed('t-1')!;
        expect(end.reason, TerminalCloseReason.refused);
        expect(end.detail, 'No such container: gone');
        expect(released, 1);
      },
    );
  });

  test('resizes reach the daemon in order, the latest last, and one made '
      'while the exec starts follows it', () async {
    sessions
      ..open(_open(), _policy)
      ..resize(const TerminalResize('t-1', columns: 100, rows: 30));
    await settle();
    expect(daemon.bodies['create e1']?['ConsoleSize'], [40, 120]);
    expect(daemon.resizes, ['e1 100x30']);

    sessions
      ..resize(const TerminalResize('t-1', columns: 90, rows: 25))
      ..resize(const TerminalResize('t-1', columns: 80, rows: 24))
      ..resize(const TerminalResize('t-1', columns: 0, rows: 24));
    await settle();
    expect(daemon.resizes.last, 'e1 80x24');
    expect(daemon.resizes, isNot(contains('e1 0x24')));
  });

  test('input while the exec starts is passed on once it runs', () async {
    sessions
      ..open(_open(), _policy)
      ..input(TerminalInput('t-1', Uint8List.fromList(utf8.encode('id\r'))));
    await settle();
    expect(utf8.decode(daemon.stdin['e1']!.toBytes()), 'id\r');
  });

  test('input after the shell exited, while its exit code is read, is '
      'dropped', () async {
    sessions.open(_open(), _policy);
    await settle();
    final gate = controlGate = Completer<void>();
    await daemon.shells['e1']!.server.close();
    await settle();
    expect(closed('t-1'), isNull, reason: 'the exit code is still read');

    sessions.input(TerminalInput('t-1', Uint8List.fromList([0x0d])));
    gate.complete();
    await settle();
    expect(closed('t-1')?.reason, TerminalCloseReason.exited);
  });

  test('CloseTerminal closes the connection and gives the slot back', () async {
    sessions.open(_open(), _policy);
    await settle();
    sessions.close('t-1');
    await settle();

    expect(closed('t-1')?.reason, TerminalCloseReason.closed);
    expect(closed('t-1')?.exitCode, isNull);
    expect(daemon.stdinClosed, contains('e1'));
    expect(released, 1);
    expect(audits.single.outcome, ActionOutcome.succeeded);
  });

  test('a lost link ends every shell of its server', () async {
    sessions
      ..open(_open(id: 'a'), _policy)
      ..open(_open(id: 'b'), _policy);
    await settle();
    sessions.linkLost('srv-1');
    await settle();

    expect(closed('a')?.reason, TerminalCloseReason.linkLost);
    expect(closed('b')?.reason, TerminalCloseReason.linkLost);
    expect(released, 2);
    expect(audits.map((r) => r.outcome), everyElement(ActionOutcome.failed));
  });

  test('admin mode ending closes a shell over the sudo relay only', () async {
    rank = DockerRank.sudoRelay;
    sessions.open(_open(id: 'root'), _policy);
    await settle();
    rank = DockerRank.cliRelay;
    sessions.open(_open(id: 'plain'), _policy);
    await settle();

    sessions.adminEnded('srv-1');
    await settle();
    expect(closed('root')?.reason, TerminalCloseReason.adminEnded);
    expect(closed('plain'), isNull);
  });

  test('ending input half-closes it while output keeps coming', () async {
    sessions.open(_open(), _policy);
    await settle();
    sessions.endInput('t-1');
    await settle();
    daemon.shells['e1']!.server.sink.add(utf8.encode('bye'));
    await settle();

    expect(utf8.decode(output('t-1')), 'bye');
    expect(closed('t-1'), isNull);
  });

  test('output goes out at most once per batch interval', () async {
    var now = Duration.zero;
    final timers = <(Duration, void Function())>[];
    final paced = ExecSessions(
      open: (serverId) async => (
        lease: DockerStreamLease(
          DockerClient(
            DockerHttpClient(
              () async => daemon.connect().client,
              maxConnections: 1,
            ),
            apiVersion: const ApiVersion(1, 44),
          ),
        ),
        rank: DockerRank.streamlocal,
      ),
      control: <T>(serverId, call) => call(pool),
      emit: events.add,
      fleet: (_) => true,
      startTimer: (duration, callback) {
        timers.add((duration, callback));
        return Timer(const Duration(days: 1), () {});
      },
      elapsed: () => now,
    );
    addTearDown(paced.dispose);
    paced.open(_open(), _policy);
    await settle();

    final shell = daemon.shells['e1']!.server.sink;
    shell.add(utf8.encode('a'));
    await settle();
    now += const Duration(milliseconds: 10);
    shell
      ..add(utf8.encode('b'))
      ..add(utf8.encode('c'));
    await settle();

    expect(
      [for (final e in events.whereType<TerminalBytes>()) utf8.decode(e.bytes)],
      ['a'],
    );
    expect(timers.single.$1, const Duration(milliseconds: 40));

    now += const Duration(milliseconds: 40);
    timers.single.$2();
    expect(
      [for (final e in events.whereType<TerminalBytes>()) utf8.decode(e.bytes)],
      ['a', 'bc'],
    );
  });
}
