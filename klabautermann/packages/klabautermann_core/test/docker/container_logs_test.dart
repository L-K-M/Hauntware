// Container logs as a log stream (03 §5.6, §7.12 CTX-01; M7, M9) over a
// forwarding link double and a fake engine: framing by Config.Tty with
// or without a Content-Type, Podman's split frames, the ring's dropped
// count, resuming after the newest line with the inclusive `since`
// boundary dropped, a stopped container, unreadable log drivers, the
// relay's follower slots, and teardown.
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/container_logs.dart';
import 'package:klabautermann_core/src/docker/docker_router.dart';
import 'package:klabautermann_core/src/logs/log_follower.dart'
    show kFollowRingLines;
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show LogConfig, LogTimestamp;
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart' show SshLink;
import 'package:test/test.dart';

import '../support/engine_daemon.dart';
import '../support/fake_clock.dart';
import '../support/forwarding_link.dart';

const _srv = 'srv-1';
const _socket = '/var/run/docker.sock';
const _inspectPath = '/v1.52/containers/abc/json';
const _logsPath = '/v1.52/containers/abc/logs';

HostProfile _profile({bool relay = false}) => HostProfile(
  uid: 1000,
  sudoKind: SudoKind.none,
  tools: {'docker': relay ? '/usr/bin/docker' : null, 'podman': null},
  engineSockets: const [
    EngineSocket(path: _socket, exists: true, writable: true),
  ],
  areaStatuses: {'tools': SectionStatus.ok, 'sockets': SectionStatus.ok},
);

/// The [n]th nanosecond of the test's second, as the daemon prints it.
String _ts(int n) => '2026-10-17T10:00:00.${'$n'.padLeft(9, '0')}Z';

DateTime _at(int n) =>
    DateTime.utc(2026, 10, 17, 10).add(Duration(microseconds: n ~/ 1000));

/// One stdcopy frame: the stream byte, three zero bytes and the
/// big-endian length (03 §5.6).
List<int> _frame(int stream, String text) {
  final bytes = utf8.encode(text);
  final n = bytes.length;
  return [
    stream,
    0,
    0,
    0,
    n >> 24,
    n >> 16 & 255,
    n >> 8 & 255,
    n & 255,
    ...bytes,
  ];
}

List<int> _out(int n, String text) => _frame(1, '${_ts(n)} $text\n');
List<int> _err(int n, String text) => _frame(2, '${_ts(n)} $text\n');

String _inspect({
  bool tty = false,
  String driver = 'json-file',
  Map<String, String> options = const {},
}) => jsonEncode({
  'Id': 'abc',
  'Config': {'Tty': tty},
  'HostConfig': {
    'LogConfig': {'Type': driver, 'Config': options},
  },
});

/// A router over one server's link with a fake engine and a fake clock.
final class _Harness {
  _Harness({this.relay = false, EngineDaemon? daemon})
    : daemon = daemon ?? EngineDaemon() {
    if (relay) {
      forwarding
        ..relayDaemon = this.daemon
        ..probeAnswers[_socket] = '0\n0\n1\n';
    } else {
      forwarding.daemons[_socket] = this.daemon;
    }
    router = DockerRouter(
      linkFor: (_) => link,
      emit: events.add,
      startTimer: clock.startTimer,
      now: () => clock.now,
      elapsed: () => clock.elapsed,
    )..retain({_srv});
    this.daemon.routes[_inspectPath] = _inspect();
  }

  final bool relay;
  final clock = FakeClock();
  final EngineDaemon daemon;
  final forwarding = ForwardingLink();
  late SshLink? link = forwarding;
  late final DockerRouter router;
  final events = <EngineEvent>[];

  String? open({
    String streamId = 'logs-1',
    String containerId = 'abc',
    int window = 50,
    bool follow = true,
    DateTime? since,
    DateTime? until,
  }) => router.openLogs(
    OpenLogStream(
      streamId: streamId,
      spec: LogStreamSpec(
        serverId: _srv,
        source: ContainerLogSource(containerId, since: since, until: until),
        window: window,
        follow: follow,
      ),
    ),
  );

  /// Opens a stream and lets the endpoint resolve and the read start.
  Future<void> start({
    int window = 50,
    bool follow = true,
    DateTime? since,
    DateTime? until,
  }) async {
    expect(
      open(window: window, follow: follow, since: since, until: until),
      isNull,
    );
    router.probed(_srv, _profile(relay: relay));
    await settle();
  }

  Future<void> settle() => pumpEventQueue(times: 100);

  /// Lets the lines written so far arrive and their batch go.
  Future<void> flush() async {
    await settle();
    await clock.elapse(Duration.zero);
  }

  List<LogStreamStatus> states([String streamId = 'logs-1']) => [
    for (final e in events.whereType<LogStreamState>())
      if (e.streamId == streamId) e.status,
  ];

  List<LogBatch> batches() => events.whereType<LogBatch>().toList();

  List<String> texts() => [
    for (final batch in batches())
      for (final r in batch.records) (r as ContainerRecord).text,
  ];

  List<String> requests(String fragment) =>
      daemon.requests.where((r) => r.contains(fragment)).toList();

  /// The query of the [index]th logs request.
  Map<String, String> logsQuery([int index = -1]) {
    final all = requests('/logs');
    final line = all[index < 0 ? all.length + index : index];
    return Uri.parse(line.split(' ')[1]).queryParameters;
  }
}

const _running = LogStreamRunning();
const _waitingLink = LogStreamWaiting(LogStreamWaitReason.link);

void main() {
  group('time range (CTX-03)', () {
    test('a range asks for since and until, and no tail, '
        'which Docker would apply first', () async {
      final h = _Harness();
      await h.start(
        follow: false,
        since: DateTime.utc(2026, 10, 26, 12),
        until: DateTime.utc(2026, 10, 26, 13, 0, 0, 500),
      );

      expect(h.logsQuery(), {
        'follow': '0',
        'stdout': '1',
        'stderr': '1',
        'timestamps': '1',
        'since': '1793016000.000000000',
        'until': '1793019600.500000000',
      });
    });

    test('a ranged follow resumes after the newest line, not at the '
        "range's start", () async {
      final h = _Harness();
      await h.start(since: DateTime.utc(2026, 10, 26, 12));
      expect(h.logsQuery()['since'], '1793016000.000000000');
      expect(h.logsQuery().containsKey('tail'), isFalse);

      h.daemon.writeLogs(_out(1, 'bye'));
      await h.flush();

      h.daemon.endLogs();
      await h.settle();
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.requests('/logs'), hasLength(2));
      expect(h.logsQuery()['since'], LogTimestamp.tryParse(_ts(1))!.sinceQuery);
      expect(h.logsQuery().containsKey('tail'), isFalse);
      expect(h.logsQuery()['follow'], '1', reason: 'the resume still follows');
    });
  });

  group('framing and lines (03 §5.6)', () {
    test('a non-TTY follow waits for the endpoint, asks for the tail with '
        'timestamps, and demultiplexes stdout and stderr', () async {
      final h = _Harness();
      await h.start();

      expect(h.states(), [_waitingLink, _running]);
      expect(h.requests(_inspectPath), hasLength(1));
      expect(h.logsQuery(), {
        'follow': '1',
        'stdout': '1',
        'stderr': '1',
        'timestamps': '1',
        'tail': '50',
      });

      h.daemon.writeLogs([..._out(1, 'listening'), ..._err(2, 'warn: slow')]);
      await h.flush();

      final records = h.batches().single.records.cast<ContainerRecord>();
      expect(
        [for (final r in records) (r.stream, r.at, r.text)],
        [
          (ContainerLogStream.stdout, _at(1), 'listening'),
          (ContainerLogStream.stderr, _at(2), 'warn: slow'),
        ],
      );
      expect(h.batches().single.dropped, 0);
    });

    test('Docker 20.10 sends no Content-Type: Config.Tty false still '
        'demultiplexes (D01)', () async {
      final h = _Harness(daemon: EngineDaemon(apiVersion: '1.41'))
        ..daemon.logsContentType = null;
      h.daemon.routes['/v1.41/containers/abc/json'] = _inspect();
      await h.start();

      h.daemon.writeLogs(_out(1, 'framed'));
      await h.flush();

      expect(h.texts(), ['framed']);
    });

    test('a TTY container\'s raw stream splits on newlines wherever its '
        'chunks end, without a Content-Type', () async {
      final h = _Harness()..daemon.logsContentType = null;
      h.daemon.routes[_inspectPath] = _inspect(tty: true);
      await h.start();

      h.daemon
        ..writeLogs(utf8.encode('${_ts(1)} \$ '))
        ..writeLogs(utf8.encode('ls\r\n${_ts(2)} bin  etc\r'))
        ..writeLogs(utf8.encode('\n'));
      await h.flush();

      final records = h.batches().single.records.cast<ContainerRecord>();
      expect(
        [for (final r in records) (r.stream, r.text)],
        [
          (ContainerLogStream.stdout, r'$ ls'),
          (ContainerLogStream.stdout, 'bin  etc'),
        ],
      );
    });

    test('Podman\'s line split over two frames, each with its own '
        'timestamp, arrives whole (D01)', () async {
      final h = _Harness(daemon: EngineDaemon(libpodApiVersion: '5.4.0'))
        ..daemon.logsContentType = null;
      h.daemon.routes[_inspectPath] = _inspect(driver: 'k8s-file');
      await h.start();

      h.daemon
        ..writeLogs(_frame(1, '${_ts(1)} stdout lin'))
        ..writeLogs(_frame(1, '${_ts(2)} e 520\n'));
      await h.flush();

      final record = h.batches().single.records.single as ContainerRecord;
      expect((record.text, record.at), ('stdout line 520', _at(1)));
    });

    test('lines past the ring arrive as dropped, the newest kept, and the '
        'next batch waits 50 ms', () async {
      final h = _Harness();
      await h.start();

      h.daemon.writeLogs([
        for (var i = 0; i < kFollowRingLines + 3; i++)
          ..._out(i + 1, 'line $i'),
      ]);
      await h.flush();

      final batch = h.batches().single;
      expect(batch.dropped, 3);
      expect(batch.records, hasLength(kFollowRingLines));
      expect((batch.records.first as ContainerRecord).text, 'line 3');

      h.events.clear();
      h.daemon.writeLogs(_out(9999, 'later'));
      await h.flush();
      expect(h.batches(), isEmpty);
      await h.clock.elapse(const Duration(milliseconds: 50));
      expect(h.texts(), ['later']);
    });
  });

  group('resume (03 §5.6)', () {
    test('a link back resumes since the newest line, dropping the '
        're-sent boundary line, and holds every record', () async {
      final h = _Harness();
      await h.start();
      h.daemon.writeLogs([..._out(1, 'one'), ..._err(3, 'three')]);
      await h.flush();
      h.events.clear();

      h
        ..link = null
        ..router.update(_srv);
      await h.settle();
      expect(h.daemon.logStreams, isEmpty);
      h
        ..link = (ForwardingLink()..daemons[_socket] = h.daemon)
        ..router.update(_srv);
      await h.settle();

      expect(h.states(), [_waitingLink, _running]);
      final query = h.logsQuery();
      expect(query['since'], LogTimestamp.tryParse(_ts(3))!.sinceQuery);
      expect(query.containsKey('tail'), isFalse);

      h.daemon.writeLogs([..._err(3, 'three'), ..._out(4, 'four')]);
      await h.flush();
      // The last batch went no time ago by the fake clock.
      await h.clock.elapse(const Duration(milliseconds: 50));
      expect(h.texts(), ['four']);
      expect(h.batches().single.dropped, 0);
    });

    test('a follow outlasts its container\'s stop: it reads again after '
        '1 s since the newest line, backing off while nothing comes', () async {
      final h = _Harness();
      await h.start();
      h.daemon.writeLogs(_out(1, 'bye'));
      await h.flush();

      h.daemon.endLogs();
      await h.settle();
      await h.clock.elapse(const Duration(milliseconds: 999));
      expect(h.requests('/logs'), hasLength(1));
      await h.clock.elapse(const Duration(milliseconds: 1));
      expect(h.requests('/logs'), hasLength(2));
      expect(h.requests(_inspectPath), hasLength(2));
      expect(h.logsQuery()['since'], LogTimestamp.tryParse(_ts(1))!.sinceQuery);

      h.daemon.endLogs();
      await h.settle();
      await h.clock.elapse(const Duration(milliseconds: 1999));
      expect(h.requests('/logs'), hasLength(2));
      await h.clock.elapse(const Duration(milliseconds: 1));
      expect(h.requests('/logs'), hasLength(3));

      h.daemon.writeLogs(_out(2, 'back'));
      await h.flush();
      expect(h.texts(), ['bye', 'back']);
      expect(h.states(), [_waitingLink, _running]);
    });

    test('a window reads its last lines once and ends', () async {
      final h = _Harness();
      await h.start(window: 2, follow: false);
      expect(h.logsQuery()['follow'], '0');
      expect(h.logsQuery()['tail'], '2');

      h.daemon
        ..writeLogs([..._out(1, 'a'), ..._out(2, 'b')])
        ..endLogs();
      await h.flush();

      expect(h.texts(), ['a', 'b']);
      expect(
        h.states().last,
        const LogStreamEnded(LogStreamEndReason.windowFilled),
      );
    });
  });

  group('drivers and failures (CTX-01)', () {
    test('which drivers keep readable logs', () {
      String? driver(
        String type, {
        Map<String, String>? options,
        bool podman = false,
      }) => unreadableLogDriver(
        LogConfig(type: type, config: options ?? const {}),
        podman: podman,
      );

      expect(driver('json-file'), isNull);
      expect(driver('local'), isNull);
      expect(driver('journald'), isNull);
      expect(driver('syslog'), isNull, reason: 'dual logging');
      expect(driver('syslog', options: {'cache-disabled': 'true'}), 'syslog');
      expect(driver('none'), 'none');
      expect(driver('k8s-file', podman: true), isNull);
      expect(driver('journald', podman: true), isNull);
      expect(driver('passthrough', podman: true), 'passthrough');
      expect(unreadableLogDriver(null, podman: false), isNull);
    });

    test('a driver without readable logs ends the stream naming it, '
        'before any logs request', () async {
      final h = _Harness();
      h.daemon.routes[_inspectPath] = _inspect(
        driver: 'gelf',
        options: {'cache-disabled': 'true'},
      );
      await h.start();

      expect(
        h.states().last,
        const LogStreamEnded(
          LogStreamEndReason.logDriverUnreadable,
          detail: 'gelf',
        ),
      );
      expect(h.requests('/logs'), isEmpty);
    });

    test('a 501 from the logs request, a cache turned off daemon-wide, '
        'reads as the same reason', () async {
      final h = _Harness();
      h.daemon
        ..routes[_inspectPath] = _inspect(driver: 'fluentd')
        ..failures[_logsPath] = (
          501,
          'configured logging driver does not support reading',
        );
      await h.start();

      expect(
        h.states().last,
        const LogStreamEnded(
          LogStreamEndReason.logDriverUnreadable,
          detail: 'fluentd',
        ),
      );
    });

    test('a container that is gone ends as missing, and a bad reference '
        'as invalid without a read', () async {
      final h = _Harness();
      h.daemon.routes.remove(_inspectPath);
      await h.start();
      expect(
        h.states().last,
        const LogStreamEnded(
          LogStreamEndReason.missing,
          detail: 'page not found',
        ),
      );

      expect(h.open(streamId: 'logs-2', containerId: '../x'), isNull);
      expect(h.states('logs-2'), [
        const LogStreamEnded(LogStreamEndReason.invalid),
      ]);
      expect(
        h.router.openLogs(
          OpenLogStream(
            streamId: 'logs-3',
            spec: LogStreamSpec(
              serverId: 'elsewhere',
              source: const ContainerLogSource('abc'),
              window: 1,
              follow: true,
            ),
          ),
        ),
        'no fleet server elsewhere',
      );
    });

    test('a server without an endpoint ends its streams as failed', () async {
      final h = _Harness();
      h.open();
      h.router.probed(
        _srv,
        HostProfile(
          uid: 1000,
          sudoKind: SudoKind.none,
          areaStatuses: {
            'tools': SectionStatus.ok,
            'sockets': SectionStatus.ok,
          },
        ),
      );
      await h.settle();

      expect(
        h.states().last,
        isA<LogStreamEnded>().having(
          (s) => s.reason,
          'reason',
          LogStreamEndReason.failed,
        ),
      );
    });
  });

  group('slots and teardown (M9)', () {
    test('on a relay two follows run and a third waits for a channel, '
        'until one closes', () async {
      final h = _Harness(relay: true);
      for (final id in ['logs-1', 'logs-2', 'logs-3']) {
        h.open(streamId: id);
      }
      h.router.probed(_srv, _profile(relay: true));
      await h.settle();

      expect(h.states('logs-1').last, _running);
      expect(h.states('logs-2').last, _running);
      expect(
        h.states('logs-3').last,
        const LogStreamWaiting(LogStreamWaitReason.channel),
      );
      expect(h.daemon.logStreams, hasLength(2));

      h.router.closeLogs('logs-1');
      await h.settle();
      expect(
        h.states('logs-1').last,
        const LogStreamEnded(LogStreamEndReason.closed),
      );
      expect(h.states('logs-3').last, _running);
      expect(h.daemon.logStreams, hasLength(2));
    });

    test('streamlocal costs no session: three follows run', () async {
      final h = _Harness();
      for (final id in ['logs-1', 'logs-2', 'logs-3']) {
        h.open(streamId: id);
      }
      h.router.probed(_srv, _profile());
      await h.settle();

      expect(h.daemon.logStreams, hasLength(3));
    });

    test('a close ends the stream and its connection; Disconnect and fleet '
        'removal end the rest as failed', () async {
      final h = _Harness();
      await h.start();
      h.open(streamId: 'logs-2');
      await h.settle();
      expect(h.daemon.logStreams, hasLength(2));

      h.router.closeLogs('logs-1');
      await h.settle();
      expect(h.daemon.logStreams, hasLength(1));
      expect(h.states().last, const LogStreamEnded(LogStreamEndReason.closed));

      h.router.retain(const {});
      await h.settle();
      expect(
        h.states('logs-2').last,
        const LogStreamEnded(LogStreamEndReason.failed),
      );
      expect(h.daemon.logStreams, isEmpty);
      await h.router.close();
    });
  });
}
