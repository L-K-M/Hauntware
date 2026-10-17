// Low-session mode and the joined channel accounting (03 §5.2; M9) over
// one forwarding link double, which the log router and the Docker router
// share as the supervisor's link: learned limits of 2, 3 and 4 over a
// relay and over streamlocal, a limit learned on the live link, recovery
// on a new link, and the host's log reads and the Docker session's
// channels counting against one quota per server.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/docker_router.dart';
import 'package:klabautermann_core/src/docker/docker_watch.dart';
import 'package:klabautermann_core/src/links/channel_quota.dart';
import 'package:klabautermann_core/src/logs/log_stream_router.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show
        RemoteCommandResult,
        RemoteProcess,
        SshLinkDegraded,
        SshLinkDegradedReason,
        SshLinkSeen;
import 'package:test/test.dart';

import '../support/engine_daemon.dart';
import '../support/fake_clock.dart';
import '../support/forwarding_link.dart';
import '../support/scripted_link.dart' show ScriptedProcess;

const _srv = 'srv-1';
const _socket = '/var/run/docker.sock';
const _containersPath = '/v1.52/containers/json';
const _running = LogStreamRunning();
const _forChannel = LogStreamWaiting(LogStreamWaitReason.channel);

HostProfile _profile({required bool relay}) => HostProfile(
  uid: 1000,
  sudoKind: SudoKind.none,
  tools: {'docker': relay ? '/usr/bin/docker' : null, 'podman': null},
  engineSockets: const [
    EngineSocket(path: _socket, exists: true, writable: true),
  ],
  areaStatuses: {'tools': SectionStatus.ok, 'sockets': SectionStatus.ok},
);

Map<String, Object?> _stats() => {
  'cpu_stats': {
    'cpu_usage': {'total_usage': 1},
    'system_cpu_usage': 1,
    'online_cpus': 1,
  },
  'memory_stats': {'usage': 1, 'limit': 2},
};

/// Both routers over one server's link, sharing its quota as the engine
/// isolate wires them.
final class _Harness {
  _Harness({required this.relay, int? learnedLimit}) {
    link = _link(learnedLimit);
    logs = LogStreamRouter(
      linkFor: (_) => link,
      emit: events.add,
      quotas: quotas,
      startTimer: clock.startTimer,
      elapsed: () => clock.elapsed,
    )..retain({_srv});
    docker = DockerRouter(
      linkFor: (_) => link,
      emit: events.add,
      quotas: quotas,
      startTimer: clock.startTimer,
      now: () => clock.now,
      elapsed: () => clock.elapsed,
    )..retain({_srv});
    daemon.routes
      ..[_containersPath] = jsonEncode([
        {
          'Id': 'abc',
          'Names': ['/abc'],
          'State': 'running',
        },
      ])
      ..['/v1.52/containers/abc/json'] = jsonEncode({
        'Id': 'abc',
        'Config': {'Tty': false},
        'HostConfig': {
          'LogConfig': {'Type': 'json-file', 'Config': <String, String>{}},
        },
      });
  }

  final bool relay;
  final clock = FakeClock();
  final daemon = EngineDaemon();
  final quotas = ChannelQuotas();
  final events = <EngineEvent>[];

  /// The host processes started: journal reads and follows.
  final host = <ScriptedProcess>[];
  late ForwardingLink link;
  late final LogStreamRouter logs;
  late final DockerRouter docker;

  ChannelQuota get quota => quotas.of(_srv);

  /// A fresh link to the server, which has learned [learnedLimit].
  ForwardingLink _link(int? learnedLimit) {
    final next = ForwardingLink()
      ..seen = SshLinkSeen(learnedSessionLimit: learnedLimit)
      ..answerStart = _hostProcess;
    if (relay) {
      next
        ..relayDaemon = daemon
        ..probeAnswers[_socket] = '0\n0\n1\n';
    } else {
      next.daemons[_socket] = daemon;
    }
    return next;
  }

  Future<RemoteProcess>? _hostProcess(String command) {
    if (!command.contains('journalctl')) return null;
    final process = ScriptedProcess();
    host.add(process);
    return Future.value(process);
  }

  /// The link went and a new one, which has learned nothing, came up;
  /// the supervisor tells both routers.
  void reconnect() {
    link = _link(null);
    logs.update(_srv);
    docker.update(_srv);
  }

  Future<void> settle() => pumpEventQueue(times: 100);

  void watch(Set<DockerWatchList> lists, {Set<String> statsFor = const {}}) =>
      docker.watch(
        DockerWatch(
          serverId: _srv,
          watchId: 'w-1',
          lists: lists,
          statsFor: statsFor,
        ),
      );

  void probed() => docker.probed(_srv, _profile(relay: relay));

  /// Opens a journal read on the log router.
  void journal(String streamId, {bool follow = true}) => expect(
    logs.open(
      OpenLogStream(
        streamId: streamId,
        spec: LogStreamSpec(
          serverId: _srv,
          source: const JournalLogSource(),
          window: 10,
          follow: follow,
        ),
      ),
    ),
    isNull,
  );

  /// Opens a container log follow on the Docker router.
  void container(String streamId) => expect(
    docker.openLogs(
      OpenLogStream(
        streamId: streamId,
        spec: LogStreamSpec(
          serverId: _srv,
          source: const ContainerLogSource('abc'),
          window: 10,
          follow: true,
        ),
      ),
    ),
    isNull,
  );

  LogStreamStatus? status(String streamId) => [
    for (final e in events)
      if (e case LogStreamState(streamId: final id, :final status))
        if (id == streamId) status,
  ].lastOrNull;

  DockerEndpointState get state => events.whereType<DockerEndpointState>().last;

  int get listReads =>
      daemon.requests.where((r) => r.contains('/containers/json')).length;

  Future<void> close() async {
    await logs.close();
    await docker.close();
  }
}

void main() {
  group('learned session limits (03 §5.2, M9)', () {
    for (final limit in [2, 3, 4]) {
      final follows = limit < kFollowerMinSessionLimit ? 'no follow' : 'one';

      test('relay, limit $limit: the mode is named, the events stream '
          'gives way to a re-list every 15 s, and $follows runs', () async {
        final h = _Harness(relay: true, learnedLimit: limit);
        h
          ..journal('j1')
          ..container('c1')
          ..watch({DockerWatchList.containers})
          ..probed();
        await h.settle();

        expect(h.state.phase, DockerEndpointPhase.ready);
        expect(h.state.lowSession, isTrue);
        expect(h.daemon.eventStreams, isEmpty);
        expect(h.listReads, 1);
        await h.clock.elapse(kDockerListPoll);
        expect(h.listReads, 2);
        expect(h.daemon.eventStreams, isEmpty);

        // The journal follow opened first, so it has the one slot.
        expect(h.status('j1'), limit < 4 ? _forChannel : _running);
        expect(h.status('c1'), _forChannel);
        expect(h.daemon.logStreams, isEmpty);
        await h.close();
      });

      test('streamlocal, limit $limit: the mode is named for the host '
          'follows; the events stream and container follows cost no '
          'session, and stats are read one at a time', () async {
        final h = _Harness(relay: false, learnedLimit: limit);
        final ids = {'abc', 'def', 'ghi'};
        for (final id in ids) {
          h.daemon.routes['/v1.52/containers/$id/stats'] = jsonEncode(_stats());
        }
        h.daemon.hold = (path) => path.endsWith('/stats');
        h
          ..journal('j1')
          ..journal('j2')
          ..container('c1')
          ..container('c2')
          ..watch({DockerWatchList.stats}, statsFor: ids)
          ..probed();
        await h.settle();

        expect(h.state.lowSession, isTrue);
        expect(h.daemon.eventStreams, hasLength(1));
        expect(h.status('c1'), _running);
        expect(h.status('c2'), _running);
        expect(h.daemon.logStreams, hasLength(2));
        expect(h.status('j1'), limit < 4 ? _forChannel : _running);
        expect(h.status('j2'), _forChannel);
        expect(h.daemon.held, hasLength(1));
        h.daemon.release();
        await h.settle();
        expect(h.daemon.held, hasLength(1));
        h.daemon.release();
        await h.settle();
        h.daemon.release();
        await h.close();
      });
    }

    test(
      'a limit the live link learns sends the state again with the mode, '
      'and a relay\'s events stream gives its slot back for re-lists',
      () async {
        final h = _Harness(relay: true);
        h
          ..watch({DockerWatchList.containers})
          ..probed();
        await h.settle();
        expect(h.state.lowSession, isFalse);
        expect(h.daemon.eventStreams, hasLength(1));
        expect(h.quota.held(ChannelShare.follower), 1);
        final reads = h.listReads;

        h.link
          ..seen = const SshLinkSeen(learnedSessionLimit: 4)
          ..state = const SshLinkDegraded(
            SshLinkDegradedReason.sessionLimitLearned,
          );
        h.docker.update(_srv);
        expect(h.state.phase, DockerEndpointPhase.ready);
        expect(h.state.lowSession, isTrue);
        expect(h.state.route!.rank, DockerRank.cliRelay);
        await h.settle();
        expect(h.daemon.eventStreams, isEmpty);
        expect(h.quota.held(ChannelShare.follower), 0);

        // The lost stream finds no channel and re-lists, then every 15 s.
        await h.clock.elapse(const Duration(seconds: 1));
        expect(h.listReads, reads + 1);
        await h.clock.elapse(kDockerListPoll);
        expect(h.listReads, reads + 2);
        expect(h.daemon.eventStreams, isEmpty);
        await h.close();
      },
    );

    test('a new link has learned nothing: the mode ends, the waiting follow '
        'runs and the events stream opens', () async {
      final h = _Harness(relay: true, learnedLimit: 2);
      h
        ..container('c1')
        ..watch({DockerWatchList.containers})
        ..probed();
      await h.settle();
      expect(h.state.lowSession, isTrue);
      expect(h.status('c1'), _forChannel);
      expect(h.daemon.eventStreams, isEmpty);

      h.reconnect();
      await h.settle();
      final states = h.events.whereType<DockerEndpointState>().toList();
      expect(states.reversed.take(2).map((s) => (s.phase, s.lowSession)), [
        (DockerEndpointPhase.ready, false),
        (DockerEndpointPhase.resolving, false),
      ]);
      expect(h.status('c1'), _running);
      expect(h.daemon.logStreams, hasLength(1));
      expect(h.daemon.eventStreams, hasLength(1));
      expect(h.quota.held(ChannelShare.follower), 2);
      await h.close();
    });
  });

  group('one quota for the host and Docker (M9)', () {
    test('relay: a journal follow and a container follow fill the follower '
        'share, so the events stream polls and a second journal follow '
        'waits until the container follow closes', () async {
      final h = _Harness(relay: true);
      h
        ..journal('j1')
        ..container('c1')
        ..watch({DockerWatchList.containers})
        ..probed();
      await h.settle();

      expect(h.state.lowSession, isFalse);
      expect(h.status('j1'), _running);
      expect(h.status('c1'), _running);
      expect(h.daemon.eventStreams, isEmpty);
      expect(h.listReads, 1);

      h.journal('j2');
      expect(h.status('j2'), _forChannel);
      h.docker.closeLogs('c1');
      await h.settle();
      expect(h.status('j2'), _running);
      expect(h.host, hasLength(2));

      // The share stays full, so the next try re-lists again.
      await h.clock.elapse(kDockerListPoll);
      expect(h.listReads, 2);
      expect(h.daemon.eventStreams, isEmpty);
      await h.close();
    });

    test('relay: the pooled connection holds a short-action slot until its '
        'idle close, so one host window runs beside it and the next '
        'waits', () async {
      final h = _Harness(relay: true);
      h.docker.query(
        const DockerQuery(
          serverId: _srv,
          queryId: 'q',
          query: DockerImagesQuery(),
        ),
      );
      h.daemon.routes['/v1.52/images/json'] = '[]';
      h.probed();
      await h.settle();
      expect(h.events.whereType<DockerResult>().last.queryId, 'q');
      expect(h.link.relays, hasLength(1));
      expect(h.quota.held(ChannelShare.shortAction), 1);

      h
        ..journal('w1', follow: false)
        ..journal('w2', follow: false);
      expect(h.status('w1'), _running);
      expect(h.status('w2'), _forChannel);

      await h.clock.elapse(const Duration(seconds: 30));
      expect(h.link.relays.single.closeCalls, 1);
      expect(h.status('w2'), _running);
      await h.close();
    });

    test('relay, limit 2: the journal and container follows wait, and the '
        'stack checks run one at a time in the short-action slot the '
        'pooled connection leaves', () async {
      final h = _Harness(relay: true, learnedLimit: 2);
      h.daemon.routes[_containersPath] = jsonEncode([
        for (final project in ['a', 'b'])
          {
            'Id': project,
            'Names': ['/$project'],
            'State': 'running',
            'Labels': {
              'com.docker.compose.project': project,
              'com.docker.compose.service': 'web',
              'com.docker.compose.project.config_files':
                  '/srv/$project/compose.yaml',
              'com.docker.compose.project.working_dir': '/srv/$project',
              'com.docker.compose.config-hash': 'feed',
            },
          },
      ]);
      final checks = <Completer<RemoteCommandResult>>[];
      h.link.answer = (command) {
        if (!command.contains('/srv/')) return null;
        final check = Completer<RemoteCommandResult>();
        checks.add(check);
        return check.future;
      };
      h
        ..journal('j1')
        ..container('c1')
        ..watch({DockerWatchList.stacks})
        ..probed();
      await h.settle();

      expect(h.status('j1'), _forChannel);
      expect(h.status('c1'), _forChannel);
      expect(h.quota.held(ChannelShare.shortAction), 2);
      expect(checks, hasLength(1));

      // A missing file decides the stack at once.
      checks.single.complete(
        const RemoteCommandResult(stdout: '1\n', exitCode: 0),
      );
      await h.settle();
      expect(checks, hasLength(2));
      checks.last.complete(
        const RemoteCommandResult(stdout: '1\n', exitCode: 0),
      );
      await h.settle();
      expect(h.quota.held(ChannelShare.shortAction), 1);
      final stacks = h.events.whereType<DockerListChanged>().last.payload;
      expect(
        (stacks as DockerStacksPayload).verdicts.values,
        everyElement(isA<StackSourceNotOnHost>()),
      );
      await h.close();
    });
  });
}
