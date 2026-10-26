// The engine's Docker watches over a forwarding link double and a fake
// engine (03 §7.12 DKE-02, CST-01; M7, M9): the events stream before the
// first list, batched and targeted re-reads, the 60 s gap, resuming with
// `since`, list stats with their deltas, the visible set, the in-flight
// limits by rank, and teardown.
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/docker_router.dart';
import 'package:klabautermann_core/src/docker/docker_watch.dart';
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart' show SshLink;
import 'package:test/test.dart';

import '../support/engine_daemon.dart';
import '../support/fake_clock.dart';
import '../support/forwarding_link.dart';

const _srv = 'srv-1';
const _socket = '/var/run/docker.sock';
const _containersPath = '/v1.52/containers/json';

HostProfile _profile({bool relay = false}) => HostProfile(
  uid: 1000,
  sudoKind: SudoKind.none,
  tools: {'docker': relay ? '/usr/bin/docker' : null, 'podman': null},
  engineSockets: const [
    EngineSocket(path: _socket, exists: true, writable: true),
  ],
  areaStatuses: {'tools': SectionStatus.ok, 'sockets': SectionStatus.ok},
);

Map<String, Object?> _container(
  String id, {
  String state = 'running',
  String? project,
}) => {
  'Id': id,
  'Names': ['/$id'],
  'Command': 'serve --token=s3cret',
  'State': state,
  'Labels': {
    if (project != null) ...{
      'com.docker.compose.project': project,
      'com.docker.compose.service': id,
    },
  },
};

Map<String, Object?> _event(
  String id, {
  String type = 'container',
  String action = 'start',
  int time = 1760702400,
  Map<String, String> attributes = const {},
}) => {
  'Type': type,
  'Action': action,
  'Actor': {'ID': id, 'Attributes': attributes},
  'time': time,
  'timeNano': time * 1000000000,
};

Map<String, Object?> _stats({
  required int cpu,
  required int system,
  int usage = 300,
  int inactive = 100,
}) => {
  'cpu_stats': {
    'cpu_usage': {'total_usage': cpu},
    'system_cpu_usage': system,
    'online_cpus': 2,
  },
  'memory_stats': {
    'usage': usage,
    'limit': 1000,
    'stats': {'inactive_file': inactive},
  },
};

/// A router over one server's link with a fake engine, whose events a
/// test reads as they pile up.
final class _Harness {
  _Harness({this.relay = false}) {
    if (relay) {
      forwarding
        ..relayDaemon = daemon
        ..probeAnswers[_socket] = '0\n0\n1\n';
    } else {
      forwarding.daemons[_socket] = daemon;
    }
    router = DockerRouter(
      linkFor: (_) => link,
      emit: events.add,
      startTimer: clock.startTimer,
      now: () => clock.now,
    )..retain({_srv});
    daemon
      ..routes[_containersPath] = jsonEncode([
        _container('abc', project: 'demo'),
        _container('def'),
      ])
      ..routes['/v1.52/images/json'] = jsonEncode([
        {'Id': 'sha256:1'},
      ])
      ..routes['/v1.52/volumes'] = jsonEncode({
        'Volumes': [
          {
            'Name': 'data',
            'Driver': 'local',
            'Mountpoint': '/var/lib/docker/volumes/data/_data',
            'Labels': {'backup.token': 's3cret'},
          },
        ],
        'Warnings': null,
      })
      ..routes['/v1.52/networks'] = jsonEncode([
        {
          'Id': 'n1',
          'Name': 'shop_default',
          'Driver': 'bridge',
          'Labels': {'com.example.token': 's3cret'},
        },
      ]);
  }

  final bool relay;
  final clock = FakeClock();
  final daemon = EngineDaemon();
  final forwarding = ForwardingLink();
  late SshLink? link = forwarding;
  late final DockerRouter router;
  final events = <EngineEvent>[];

  /// The lists sent since the last call.
  List<DockerListChanged> lists() {
    final sent = events.whereType<DockerListChanged>().toList();
    events.clear();
    return sent;
  }

  List<String> requests(String fragment) =>
      daemon.requests.where((r) => r.contains(fragment)).toList();

  Future<void> settle() => pumpEventQueue(times: 100);

  void watch(
    Set<DockerWatchList> lists, {
    String watchId = 'w-1',
    Set<String> statsFor = const {},
  }) => router.watch(
    DockerWatch(
      serverId: _srv,
      watchId: watchId,
      lists: lists,
      statsFor: statsFor,
    ),
  );

  /// Watches [lists] and lets the endpoint resolve and the first reads
  /// finish; returns the lists they sent.
  Future<List<DockerListChanged>> start(
    Set<DockerWatchList> lists, {
    Set<String> statsFor = const {},
  }) async {
    watch(lists, statsFor: statsFor);
    router.probed(_srv, _profile(relay: relay));
    await settle();
    expect(
      events.whereType<DockerEndpointState>().last.phase,
      DockerEndpointPhase.ready,
    );
    return this.lists();
  }
}

TypeMatcher<DockerListChanged> _list(
  DockerWatchList list, {
  bool fullRelist = false,
}) => isA<DockerListChanged>()
    .having((e) => e.list, 'list', list)
    .having((e) => e.fullRelist, 'fullRelist', fullRelist)
    .having((e) => e.serverId, 'serverId', _srv);

List<String> _ids(DockerListChanged event) => [
  for (final c in (event.payload as DockerContainersPayload).containers) c.id,
];

void main() {
  group('events and lists (DKE-02)', () {
    test('the events stream opens before the first list, which crosses '
        'whole, without command lines, and grouped by stack', () async {
      final h = _Harness();
      final sent = await h.start({
        DockerWatchList.containers,
        DockerWatchList.stacks,
      });

      expect(sent, [
        _list(DockerWatchList.containers, fullRelist: true),
        _list(DockerWatchList.stacks, fullRelist: true),
      ]);
      final containers =
          (sent.first.payload as DockerContainersPayload).containers;
      expect([for (final c in containers) c.id], ['abc', 'def']);
      expect(containers.first.command, isNull);
      final grouping = (sent.last.payload as DockerStacksPayload).grouping;
      expect(grouping.projects.single.name, 'demo');
      expect([for (final c in grouping.unmanaged) c.id], ['def']);
      expect(sent.first.at, h.clock.now);

      final events = h.daemon.requests.indexWhere((r) => r.contains('/events'));
      expect(events, lessThan(h.daemon.requests.indexWhere(_isList)));
      expect(
        Uri.parse(
          h.requests('/events').single.split(' ')[1],
        ).queryParameters['filters'],
        jsonEncode({
          'type': ['container', 'image', 'volume', 'network'],
        }),
      );
    });

    test('a burst for one container reads it alone once, 250 ms after the '
        'first event, and merges it in', () async {
      final h = _Harness();
      await h.start({DockerWatchList.containers});
      h.daemon.routes[_containersPath] = jsonEncode([
        _container('abc', state: 'exited'),
      ]);

      for (final action in ['kill', 'die', 'stop']) {
        h.daemon.emit(_event('abc', action: action));
      }
      await h.clock.elapse(const Duration(milliseconds: 249));
      expect(h.lists(), isEmpty);
      await h.clock.elapse(const Duration(milliseconds: 1));

      final sent = h.lists();
      expect(sent, [_list(DockerWatchList.containers)]);
      final containers =
          (sent.single.payload as DockerContainersPayload).containers;
      expect([for (final c in containers) c.id], ['abc', 'def']);
      expect(containers.first.state, 'exited');
      final targeted = h.requests(_containersPath).last;
      expect(
        Uri.parse(targeted.split(' ')[1]).queryParameters['filters'],
        jsonEncode({
          'id': ['abc'],
        }),
      );
      expect(h.requests(_containersPath), hasLength(2));
    });

    test('an action re-reads what it changed, which the event that '
        'preceded the change could not show', () async {
      final h = _Harness();
      await h.start({DockerWatchList.containers, DockerWatchList.images});

      // Docker logs a pause before the list it reads holds it
      // (containerPause), so the event's own read sees it running.
      h.daemon.emit(_event('abc', action: 'pause'));
      await h.clock.elapse(kDockerEventBatch);
      final early = h.lists().single;
      expect(
        (early.payload as DockerContainersPayload).containers.first.state,
        'running',
      );

      // The action's reply comes once the list holds the change.
      h.daemon.routes[_containersPath] = jsonEncode([
        _container('abc', state: 'paused'),
      ]);
      h.router.actionRan(_srv, containers: {'abc'});
      await h.clock.elapse(kDockerEventBatch);
      final sent = h.lists();
      expect(sent, [_list(DockerWatchList.containers)]);
      final containers =
          (sent.single.payload as DockerContainersPayload).containers;
      expect([for (final c in containers) c.id], ['abc', 'def']);
      expect(containers.first.state, 'paused');
      expect(
        Uri.parse(
          h.requests(_containersPath).last.split(' ')[1],
        ).queryParameters['filters'],
        jsonEncode({
          'id': ['abc'],
        }),
      );

      // An image removal re-reads the images.
      final images = h.requests('/images/json').length;
      h.router.actionRan(_srv, images: true);
      await h.clock.elapse(kDockerEventBatch);
      expect(h.lists(), [_list(DockerWatchList.images)]);
      expect(h.requests('/images/json'), hasLength(images + 1));
    });

    test('a container prune re-reads the whole container list', () async {
      final h = _Harness();
      await h.start({DockerWatchList.containers});
      h.daemon.routes[_containersPath] = jsonEncode([_container('abc')]);

      h.router.actionRan(_srv, everyContainer: true);
      await h.clock.elapse(kDockerEventBatch);
      expect(_ids(h.lists().single), ['abc']);
      expect(
        Uri.parse(
          h.requests(_containersPath).last.split(' ')[1],
        ).queryParameters['filters'],
        isNull,
      );
    });

    test('an action on a server without a watch reads nothing', () async {
      final h = _Harness();
      h.router.actionRan(_srv, containers: {'abc'}, images: true);
      await h.clock.elapse(kDockerEventBatch);
      expect(h.daemon.requests, isEmpty);
    });

    test('a container the targeted read misses is gone, and one it finds '
        'joins at the end', () async {
      final h = _Harness();
      await h.start({DockerWatchList.containers});
      h.daemon.routes[_containersPath] = jsonEncode([_container('new')]);

      h.daemon
        ..emit(_event('abc', action: 'destroy'))
        ..emit(_event('new', action: 'create'));
      await h.clock.elapse(kDockerEventBatch);

      expect(_ids(h.lists().single), ['def', 'new']);
    });

    test('a burst over more containers than a targeted read takes '
        're-lists once', () async {
      final h = _Harness();
      await h.start({DockerWatchList.containers});

      for (var i = 0; i < 17; i++) {
        h.daemon.emit(_event('c$i', action: 'create'));
      }
      await h.clock.elapse(kDockerEventBatch);

      expect(h.lists(), [_list(DockerWatchList.containers)]);
      expect(h.requests(_containersPath).last, contains('?all=1 '));
      expect(h.requests(_containersPath), hasLength(2));
    });

    test('image events re-read the images; exec, volume and unwatched '
        'events read nothing', () async {
      final h = _Harness();
      await h.start({DockerWatchList.images});

      h.daemon
        ..emit(_event('abc', action: 'exec_start: sh -c true'))
        ..emit(_event('vol', type: 'volume', action: 'create'))
        ..emit(_event('abc', action: 'die'));
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.lists(), isEmpty);
      expect(h.requests(_containersPath), isEmpty);

      h.daemon.emit(_event('sha256:2', type: 'image', action: 'pull'));
      await h.clock.elapse(kDockerEventBatch);
      expect(h.lists(), [_list(DockerWatchList.images)]);
      expect(h.requests('/images/json'), hasLength(2));
    });

    test('volume events re-read the volumes, labels masked; image and '
        'container events read no volumes (VOL-01)', () async {
      final h = _Harness();
      final first = await h.start({DockerWatchList.volumes});

      expect(first, [_list(DockerWatchList.volumes, fullRelist: true)]);
      final volumes = (first.single.payload as DockerVolumesPayload).volumes;
      expect(volumes.single.name, 'data');
      expect(volumes.single.labels['backup.token']?.isMasked, isTrue);

      h.daemon
        ..emit(_event('sha256:2', type: 'image', action: 'pull'))
        ..emit(_event('abc', action: 'die'));
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.lists(), isEmpty);
      expect(h.requests('/volumes'), hasLength(1));

      h.daemon.emit(_event('cache', type: 'volume', action: 'create'));
      await h.clock.elapse(kDockerEventBatch);
      expect(h.lists(), [_list(DockerWatchList.volumes)]);
      expect(h.requests('/volumes'), hasLength(2));
    });

    test('network events re-read the networks, labels masked; volume '
        'events read no networks (DNW-01)', () async {
      final h = _Harness();
      final first = await h.start({DockerWatchList.networks});

      expect(first, [_list(DockerWatchList.networks, fullRelist: true)]);
      final networks = (first.single.payload as DockerNetworksPayload).networks;
      expect(networks.single.name, 'shop_default');
      expect(networks.single.labels['com.example.token']?.isMasked, isTrue);

      h.daemon.emit(_event('cache', type: 'volume', action: 'create'));
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.lists(), isEmpty);

      h.daemon.emit(_event('n2', type: 'network', action: 'create'));
      await h.clock.elapse(kDockerEventBatch);
      expect(h.lists(), [_list(DockerWatchList.networks)]);
      expect(h.requests('/networks'), hasLength(2));
    });

    test('a network connect re-reads the container it joined, whose '
        'networks the use counts read (DNW-01)', () async {
      final h = _Harness();
      await h.start({DockerWatchList.containers, DockerWatchList.networks});

      h.daemon.emit(
        _event(
          'n1',
          type: 'network',
          action: 'connect',
          attributes: const {'container': 'abc', 'name': 'shop_default'},
        ),
      );
      await h.clock.elapse(kDockerEventBatch);

      expect(
        h.lists(),
        unorderedEquals([
          _list(DockerWatchList.containers),
          _list(DockerWatchList.networks),
        ]),
      );
      final targeted = h.requests(_containersPath).last;
      expect(
        Uri.parse(targeted.split(' ')[1]).queryParameters['filters'],
        jsonEncode({
          'id': ['abc'],
        }),
      );
    });

    test('a failed volume read reaches the watch, and the next event reads '
        'again', () async {
      final h = _Harness();
      h.daemon.failures['/v1.52/volumes'] = (500, 'boom');
      final first = await h.start({DockerWatchList.volumes});

      expect(
        first.single.payload,
        isA<DockerQueryFailed>().having(
          (f) => f.failure,
          'failure',
          DockerQueryFailure.daemonError,
        ),
      );

      h.daemon.failures.remove('/v1.52/volumes');
      h.daemon.emit(_event('cache', type: 'volume', action: 'destroy'));
      await h.clock.elapse(kDockerEventBatch);
      expect(h.lists().single.payload, isA<DockerVolumesPayload>());
    });

    test('a second watch gets the lists held without a read, and a list it '
        'adds is read', () async {
      final h = _Harness();
      await h.start({DockerWatchList.containers});

      h.watch({
        DockerWatchList.containers,
        DockerWatchList.images,
      }, watchId: 'w-2');
      await h.settle();

      expect(h.lists(), [
        _list(DockerWatchList.containers),
        _list(DockerWatchList.images, fullRelist: true),
      ]);
      expect(h.requests(_containersPath), hasLength(1));
      expect(h.requests('/events'), hasLength(1));
    });
  });

  group('resume and the 60 s gap (03 §5.6)', () {
    Future<_Harness> watchedWithEvent() async {
      final h = _Harness();
      await h.start({DockerWatchList.containers});
      h.daemon.emit(_event('abc', time: 1760702460));
      await h.clock.elapse(kDockerEventBatch);
      expect(h.lists(), hasLength(1));
      return h;
    }

    Future<void> dropLink(_Harness h, Duration away) async {
      h
        ..link = null
        ..router.update(_srv);
      await h.settle();
      expect(h.daemon.eventStreams, isEmpty);
      await h.clock.elapse(away);
      h
        ..link = (ForwardingLink()..daemons[_socket] = h.daemon)
        ..router.update(_srv);
      await h.settle();
    }

    test('a link back within 60 s resumes the stream since the last event, '
        'and re-lists, though not as a fresh list', () async {
      final h = await watchedWithEvent();
      final listed = h.requests(_containersPath).length;

      await dropLink(h, const Duration(seconds: 60));

      expect(h.requests('/events').last, contains('since=1760702460'));
      expect(h.requests(_containersPath), hasLength(listed + 1));
      expect(h.lists(), [_list(DockerWatchList.containers)]);

      // An event missed while away arrives again, and is read.
      h.daemon.emit(_event('abc', action: 'die', time: 1760702490));
      await h.clock.elapse(kDockerEventBatch);
      expect(h.lists(), [_list(DockerWatchList.containers)]);
    });

    test('a list a watch adds while the link is away is read when it is '
        'back, though the stream resumes', () async {
      final h = await watchedWithEvent();
      h
        ..link = null
        ..router.update(_srv);
      await h.settle();
      h.watch({DockerWatchList.images}, watchId: 'w-2');
      await h.settle();
      expect(h.lists(), isEmpty);

      h
        ..link = (ForwardingLink()..daemons[_socket] = h.daemon)
        ..router.update(_srv);
      await h.settle();
      expect(h.requests('/events').last, contains('since=1760702460'));
      expect(h.lists(), [
        _list(DockerWatchList.containers),
        _list(DockerWatchList.images, fullRelist: true),
      ]);
    });

    test('a daemon that restarted while the link was away replays no '
        'event, and the re-list still shows the container it lost', () async {
      final h = await watchedWithEvent();
      h.daemon.routes[_containersPath] = jsonEncode([
        _container('abc', state: 'exited'),
      ]);

      await dropLink(h, const Duration(seconds: 10));

      final containers =
          (h.lists().single.payload as DockerContainersPayload).containers;
      expect(
        [for (final c in containers) (c.id, c.state)],
        [('abc', 'exited')],
      );
    });

    test('a link back after more than 60 s re-lists in full', () async {
      final h = await watchedWithEvent();
      final listed = h.requests(_containersPath).length;

      await dropLink(h, const Duration(seconds: 61));

      expect(h.requests('/events').last, isNot(contains('since=')));
      expect(h.requests(_containersPath), hasLength(listed + 1));
      expect(h.lists(), [_list(DockerWatchList.containers, fullRelist: true)]);
    });

    test('a stream that ends opens again after 1 s, since the last event, '
        'and backs off while it keeps failing', () async {
      final h = await watchedWithEvent();

      h.daemon.failures['/v1.52/events'] = (500, 'restarting');
      await h.daemon.dropEvents();
      await h.settle();
      await h.clock.elapse(const Duration(seconds: 1));
      expect(h.requests('/events'), hasLength(2));
      await h.clock.elapse(const Duration(milliseconds: 1999));
      expect(h.requests('/events'), hasLength(2));
      await h.clock.elapse(const Duration(milliseconds: 1));
      expect(h.requests('/events'), hasLength(3));

      h.daemon.failures.clear();
      await h.clock.elapse(const Duration(seconds: 4));
      expect(h.requests('/events'), hasLength(4));
      expect(h.requests('/events').last, contains('since=1760702460'));
      expect(h.daemon.eventStreams, hasLength(1));
    });

    test('a stream that ends before any event re-lists when it opens '
        'again', () async {
      final h = _Harness();
      await h.start({DockerWatchList.containers});

      await h.daemon.dropEvents();
      await h.settle();
      await h.clock.elapse(const Duration(seconds: 1));

      expect(h.lists(), [_list(DockerWatchList.containers, fullRelist: true)]);
      expect(h.requests(_containersPath), hasLength(2));
    });
  });

  group('list stats (CST-01)', () {
    test('memory crosses less inactive_file from the first read, and CPU '
        'from the second, by the spec formula', () async {
      final h = _Harness();
      h.daemon.routes['/v1.52/containers/abc/stats'] = jsonEncode(
        _stats(cpu: 1000, system: 10000),
      );

      final first = await h.start({DockerWatchList.stats}, statsFor: {'abc'});
      final row = (first.single.payload as DockerStatsPayload).stats.single;
      expect(first.single.list, DockerWatchList.stats);
      expect(row.containerId, 'abc');
      expect(row.cpuPercent, isNull);
      expect(row.memoryUsed, 200);
      expect(row.memoryLimit, 1000);
      expect(row.at, h.clock.now);
      expect(
        h.requests('/stats').single,
        contains('/containers/abc/stats?stream=false&one-shot=true'),
      );

      h.daemon.routes['/v1.52/containers/abc/stats'] = jsonEncode(
        _stats(cpu: 1500, system: 20000, usage: 500, inactive: 50),
      );
      await h.clock.elapse(kDockerStatsInterval);
      final next =
          (h.lists().single.payload as DockerStatsPayload).stats.single;
      // (500 / 10000) * 2 CPUs * 100.
      expect(next.cpuPercent, 10.0);
      expect(next.memoryUsed, 450);
    });

    test('network and block I/O totals and PIDs come with each row '
        '(CTR-08)', () async {
      final h = _Harness();
      h.daemon.routes['/v1.52/containers/abc/stats'] = jsonEncode({
        ..._stats(cpu: 1000, system: 10000),
        'networks': {
          'eth0': {'rx_bytes': 1000, 'tx_bytes': 200},
          'eth1': {'rx_bytes': 24},
        },
        'blkio_stats': {
          'io_service_bytes_recursive': [
            {'major': 8, 'minor': 0, 'op': 'read', 'value': 4096},
            {'major': 8, 'minor': 0, 'op': 'write', 'value': 512},
            {'major': 8, 'minor': 16, 'op': 'Read', 'value': 4096},
          ],
        },
        'pids_stats': {'current': 7},
      });

      final first = await h.start({DockerWatchList.stats}, statsFor: {'abc'});
      final row = (first.single.payload as DockerStatsPayload).stats.single;
      expect(
        (row.networkRx, row.networkTx, row.blockRead, row.blockWrite, row.pids),
        (1024, 200, 8192, 512, 7),
      );
    });

    test(
      'a container without networks or I/O accounting reads as unknown',
      () async {
        final h = _Harness();
        h.daemon.routes['/v1.52/containers/abc/stats'] = jsonEncode({
          ..._stats(cpu: 1000, system: 10000),
          'blkio_stats': {'io_service_bytes_recursive': null},
        });

        final first = await h.start({DockerWatchList.stats}, statsFor: {'abc'});
        final row = (first.single.payload as DockerStatsPayload).stats.single;
        expect(
          (
            row.networkRx,
            row.networkTx,
            row.blockRead,
            row.blockWrite,
            row.pids,
          ),
          (null, null, null, null, null),
        );
      },
    );

    test('after more than 60 s away the first read has no CPU %, which '
        'would span the outage', () async {
      final h = _Harness();
      h.daemon.routes['/v1.52/containers/abc/stats'] = jsonEncode(
        _stats(cpu: 1000, system: 10000),
      );
      await h.start({DockerWatchList.stats}, statsFor: {'abc'});

      h
        ..link = null
        ..router.update(_srv);
      await h.settle();
      await h.clock.elapse(const Duration(seconds: 61));
      h.daemon.routes['/v1.52/containers/abc/stats'] = jsonEncode(
        _stats(cpu: 90000, system: 900000),
      );
      h
        ..link = (ForwardingLink()..daemons[_socket] = h.daemon)
        ..router.update(_srv);
      await h.settle();

      final rows = [
        for (final e in h.lists())
          if (e.payload case DockerStatsPayload(:final stats)) ...stats,
      ];
      expect(rows.single.cpuPercent, isNull);
    });

    test('a new visible set is read from the next round on, and stopped '
        'or gone containers are left out', () async {
      final h = _Harness();
      h.daemon.routes[_containersPath] = jsonEncode([
        _container('abc'),
        _container('def'),
        _container('off', state: 'exited'),
      ]);
      for (final id in ['abc', 'def', 'off']) {
        h.daemon.routes['/v1.52/containers/$id/stats'] = jsonEncode(
          _stats(cpu: 1000, system: 10000),
        );
      }
      await h.start(
        {DockerWatchList.containers, DockerWatchList.stats},
        statsFor: {'abc', 'gone'},
      );
      h.daemon.requests.clear();

      h.watch(
        {DockerWatchList.containers, DockerWatchList.stats},
        statsFor: {'def', 'off', 'gone'},
      );
      await h.settle();
      expect(h.lists(), isEmpty);
      await h.clock.elapse(kDockerStatsInterval);

      expect(h.requests('/stats'), [
        contains('/containers/def/stats'),
        contains('/containers/gone/stats'),
      ]);
      final rows = (h.lists().single.payload as DockerStatsPayload).stats;
      expect([for (final r in rows) r.containerId], ['def']);
      // def's first read: no CPU yet.
      expect(rows.single.cpuPercent, isNull);
    });

    test('streamlocal reads at most 4 at once', () async {
      final h = _Harness();
      final ids = {for (var i = 0; i < 6; i++) 'c$i'};
      for (final id in ids) {
        h.daemon.routes['/v1.52/containers/$id/stats'] = jsonEncode(
          _stats(cpu: 1, system: 1),
        );
      }
      h.daemon.hold = (path) => path.endsWith('/stats');

      await h.start({DockerWatchList.stats}, statsFor: ids);
      expect(h.daemon.held, hasLength(kDockerStatsInFlight));
      h.daemon.release();
      await h.settle();
      expect(h.daemon.held, hasLength(2));
      h.daemon.release();
      await h.settle();
      expect(
        (h.lists().single.payload as DockerStatsPayload).stats,
        hasLength(6),
      );
    });

    test('a relay reads one at a time (M9), its events stream on a '
        'connection of its own', () async {
      final h = _Harness(relay: true);
      h.daemon
        ..routes['/v1.52/containers/abc/stats'] = jsonEncode(
          _stats(cpu: 1, system: 1),
        )
        ..routes['/v1.52/containers/def/stats'] = jsonEncode(
          _stats(cpu: 1, system: 1),
        )
        ..hold = (path) => path.endsWith('/stats');

      await h.start({DockerWatchList.stats}, statsFor: {'abc', 'def'});
      expect(h.forwarding.started, everyElement(contains(" 'docker' ")));
      expect(h.daemon.held, hasLength(1));
      h.daemon.release();
      await h.settle();
      expect(h.daemon.held, hasLength(1));
      h.daemon.release();
      await h.settle();
      expect(
        (h.lists().single.payload as DockerStatsPayload).stats,
        hasLength(2),
      );
      expect(h.daemon.eventStreams, hasLength(1));
    });
  });

  group('a failed endpoint (D06)', () {
    test('an engine that does not answer is looked for again while a watch '
        'holds, after 5 s, then 10 s, and the lists follow once it '
        'answers', () async {
      final h = _Harness();
      h.daemon.failures['/_ping'] = (500, 'starting');
      h.watch({DockerWatchList.containers});
      h.router.probed(_srv, _profile());
      await h.settle();
      DockerEndpointState last() =>
          h.events.whereType<DockerEndpointState>().last;
      expect(last().failure, DockerEndpointFailure.unreachable);
      int pings() => h.requests('_ping').length;
      expect(pings(), 1);

      await h.clock.elapse(const Duration(seconds: 5));
      expect(pings(), 2);
      expect(last().failure, DockerEndpointFailure.unreachable);
      await h.clock.elapse(const Duration(seconds: 9));
      expect(pings(), 2);

      h.daemon.failures.clear();
      await h.clock.elapse(const Duration(seconds: 1));
      expect(last().phase, DockerEndpointPhase.ready);
      expect(h.lists(), [_list(DockerWatchList.containers, fullRelist: true)]);
    });

    test('a new watch looks again at once, and its retries start at 5 s '
        'again', () async {
      final h = _Harness();
      h.daemon.failures['/_ping'] = (500, 'starting');
      h.watch({DockerWatchList.containers});
      h.router.probed(_srv, _profile());
      await h.settle();
      int pings() => h.requests('_ping').length;
      await h.clock.elapse(const Duration(seconds: 5));
      await h.clock.elapse(const Duration(seconds: 10));
      expect(pings(), 3);

      h.router.unwatch(const DockerUnwatch(serverId: _srv, watchId: 'w-1'));
      h.watch({DockerWatchList.containers});
      await h.settle();
      expect(pings(), 4);
      await h.clock.elapse(const Duration(seconds: 5));
      expect(pings(), 5);
    });

    test('without a watch a failure stands until asked again', () async {
      final h = _Harness();
      h.daemon.failures['/_ping'] = (500, 'starting');
      h.watch({DockerWatchList.containers});
      h.router
        ..unwatch(const DockerUnwatch(serverId: _srv, watchId: 'w-1'))
        ..probed(_srv, _profile());
      await h.settle();
      await h.clock.elapse(const Duration(minutes: 5));
      expect(h.requests('_ping'), hasLength(1));
    });
  });

  group('teardown', () {
    test(
      'the last unwatch ends the events stream and the stats rounds',
      () async {
        final h = _Harness();
        h.daemon.routes['/v1.52/containers/abc/stats'] = jsonEncode(
          _stats(cpu: 1, system: 1),
        );
        await h.start(
          {DockerWatchList.containers, DockerWatchList.stats},
          statsFor: {'abc'},
        );
        h.watch({DockerWatchList.containers}, watchId: 'w-2');
        await h.settle();
        h.lists();

        h.router.unwatch(const DockerUnwatch(serverId: _srv, watchId: 'w-1'));
        await h.clock.elapse(kDockerStatsInterval);
        expect(h.lists(), isEmpty);
        expect(h.daemon.eventStreams, hasLength(1));
        final polled = h.requests('/stats').length;

        h.router.unwatch(const DockerUnwatch(serverId: _srv, watchId: 'w-2'));
        await h.settle();
        expect(h.daemon.eventStreams, isEmpty);
        h.daemon.emit(_event('abc'));
        await h.clock.elapse(const Duration(seconds: 30));
        expect(h.lists(), isEmpty);
        expect(h.requests('/stats'), hasLength(polled));
        expect(h.requests('/events'), hasLength(1));
      },
    );

    test('Disconnect and leaving the fleet end the watches', () async {
      final h = _Harness();
      await h.start({DockerWatchList.containers});

      h.router.disconnect(_srv);
      await h.settle();
      expect(h.daemon.eventStreams, isEmpty);
      h.router.update(_srv);
      await h.settle();
      expect(h.requests('/events'), hasLength(1));

      h.watch({DockerWatchList.containers});
      await h.settle();
      expect(h.daemon.eventStreams, hasLength(1));
      h.router.retain(const {});
      await h.settle();
      expect(h.daemon.eventStreams, isEmpty);
    });

    test('a watch outside the fleet, over the stats limit or above the '
        'watch limit is answered with a failed list', () async {
      final h = _Harness();
      h.router.watch(
        const DockerWatch(
          serverId: 'elsewhere',
          watchId: 'w',
          lists: {DockerWatchList.images},
        ),
      );
      h.watch(
        {DockerWatchList.stats},
        statsFor: {for (var i = 0; i <= kDockerStatsForMax; i++) 'c$i'},
      );
      for (var i = 0; i <= kDockerWatchesMax; i++) {
        h.watch({DockerWatchList.containers}, watchId: 'w-$i');
      }

      final failures = [
        for (final e in h.lists())
          if (e.payload case DockerQueryFailed(:final failure))
            (e.serverId, e.list, failure),
      ];
      expect(failures, [
        ('elsewhere', DockerWatchList.images, DockerQueryFailure.notInFleet),
        (_srv, DockerWatchList.stats, DockerQueryFailure.invalidQuery),
        (_srv, DockerWatchList.containers, DockerQueryFailure.tooManyQueries),
      ]);
    });
  });
}

bool _isList(String request) => request.contains(_containersPath);
