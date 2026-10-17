import 'dart:async';
import 'dart:math';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/fleet/reachability_service.dart';
import 'package:seance_core/seance_core.dart'
    show ProbeStatus, Prober, ServerConfig;
import 'package:test/test.dart';

import 'support/fake_clock.dart';

/// Answers each probe from [answers] (online by default), at once or,
/// while [hold] is set, once the test completes the probe's completer.
final class _FakeProber implements Prober {
  final probed = <String>[];
  final answers = <String, ProbeStatus>{};
  bool hold = false;
  final held = <Completer<ProbeStatus>>[];

  @override
  Future<ProbeStatus> probe(
    String host,
    int port, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    probed.add('$host:$port');
    final answer = answers[host] ?? ProbeStatus.online;
    if (!hold) return Future.value(answer);
    final completer = Completer<ProbeStatus>();
    held.add(completer);
    return completer.future;
  }
}

/// Jitter at its midpoint, so each sweep waits the full 45 s.
final class _MidpointRandom implements Random {
  @override
  double nextDouble() => 0.5;

  @override
  bool nextBool() => false;

  @override
  int nextInt(int max) => 0;
}

const _sweep = Duration(seconds: 45);

ServerConfig _config(String id, String host, {String? jumpHostId}) =>
    ServerConfig(
      id: id,
      label: id,
      host: host,
      username: 'deploy',
      jumpHostId: jumpHostId,
      createdAt: 0,
      updatedAt: 0,
    );

FleetEntry _entry(
  String id, {
  FleetEntryOrigin origin = FleetEntryOrigin.synced,
  EndpointConfirmation? endpoint,
}) => FleetEntry(
  serverId: id,
  label: id,
  host: '$id.example.com',
  port: 22,
  origin: origin,
  endpoint: endpoint,
);

// FL-04, 03 §4.7, §5.12: the engine probes only confirmed endpoints,
// reports jump-routed servers unknown and pauses in the background.
void main() {
  late FakeClock clock;
  late Zone zone;
  late _FakeProber prober;
  late List<Reachability> events;
  late Set<String> linked;
  late ReachabilityService service;

  // ProbeService takes its timers from the zone, so the service runs in
  // one whose timers the fake clock fires.
  T run<T>(T Function() body) => zone.run(body);

  Map<String, ReachabilityStatus> answers() => {
    for (final event in events) event.serverId: event.status,
  };

  setUp(() {
    clock = FakeClock();
    zone = Zone.current.fork(
      specification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) =>
            clock.startTimer(duration, callback),
      ),
    );
    prober = _FakeProber();
    events = [];
    linked = {};
    service = run(
      () => ReachabilityService(
        emit: events.add,
        hasLink: linked.contains,
        prober: prober,
        random: _MidpointRandom(),
      ),
    );
  });
  tearDown(() => run(service.dispose));

  test('probeTargets keeps imports and confirmed synced servers with a '
      'config', () {
    final configs = {
      for (final id in [
        'confirmed',
        'unconfirmed',
        'changed',
        'ssh-config:web',
      ])
        id: _config(id, '$id.example.com'),
    };

    final targets = probeTargets([
      _entry('confirmed', endpoint: EndpointConfirmation.confirmed),
      // Neither is probed even with a config, which the engine never gives
      // them: their endpoint could belong to whoever rewrote it (SAF-09).
      _entry('unconfirmed', endpoint: EndpointConfirmation.unconfirmed),
      _entry('changed', endpoint: EndpointConfirmation.changed),
      _entry('ssh-config:web', origin: FleetEntryOrigin.sshConfig),
      // No config: nothing to dial, so nothing to probe.
      _entry('ssh-config:nouser', origin: FleetEntryOrigin.sshConfig),
    ], (id) => configs[id]);

    expect(
      [for (final target in targets) target.id],
      ['confirmed', 'ssh-config:web'],
    );
  });

  test('probes direct servers and reports jump-routed ones unknown '
      'without a probe', () async {
    prober.answers['down.example.com'] = ProbeStatus.offline;
    prober.answers['filtered.example.com'] = ProbeStatus.unknown;
    run(
      () => service.update([
        _config('up', 'up.example.com'),
        _config('down', 'down.example.com'),
        _config('filtered', 'filtered.example.com'),
        _config('inner', 'inner.example.com', jumpHostId: 'bastion'),
      ]),
    );
    await clock.elapse(Duration.zero);

    expect(
      prober.probed,
      unorderedEquals([
        'up.example.com:22',
        'down.example.com:22',
        'filtered.example.com:22',
      ]),
    );
    expect(answers(), {
      'up': ReachabilityStatus.online,
      'down': ReachabilityStatus.offline,
      'filtered': ReachabilityStatus.unknown,
      'inner': ReachabilityStatus.unknown,
    });

    // Each sweep reports every server again, 45 s apart.
    events.clear();
    await clock.elapse(_sweep - const Duration(seconds: 1));
    expect(events, isEmpty);
    await clock.elapse(const Duration(seconds: 1));
    expect(prober.probed, hasLength(6));
    expect(
      answers().keys,
      unorderedEquals(['up', 'down', 'filtered', 'inner']),
    );
  });

  test('answers go out on a later turn than the update', () async {
    run(
      () => service.update([
        _config('up', 'up.example.com'),
        _config('inner', 'inner.example.com', jumpHostId: 'bastion'),
      ]),
    );
    await pumpEventQueue();
    expect(events, isEmpty);

    await clock.elapse(Duration.zero);
    expect(events, hasLength(3));
  });

  test('a server with a link is answered online without a probe', () async {
    linked.add('up');
    run(
      () => service.update([
        _config('up', 'up.example.com'),
        _config('other', 'other.example.com'),
      ]),
    );
    await clock.elapse(Duration.zero);

    expect(prober.probed, ['other.example.com:22']);
    expect(answers(), {
      'up': ReachabilityStatus.online,
      'other': ReachabilityStatus.online,
    });
  });

  test('the background pauses probing and drops answers in flight; the '
      'foreground sweeps at once', () async {
    run(() => service.update([_config('up', 'up.example.com')]));
    prober.hold = true;
    await clock.elapse(Duration.zero);
    expect(prober.probed, hasLength(1));

    run(() => service.activity = AppActivity.background);
    prober.held.single.complete(ProbeStatus.online);
    await clock.elapse(const Duration(minutes: 10));
    expect(prober.probed, hasLength(1), reason: 'no sweep in background');
    expect(events, isEmpty, reason: 'the paused sweep reports nothing');

    prober.hold = false;
    run(() => service.activity = AppActivity.foreground);
    await clock.elapse(Duration.zero);
    expect(prober.probed, hasLength(2));
    expect(answers(), {'up': ReachabilityStatus.online});
  });

  test(
    'a server that leaves the targets is no longer probed or reported',
    () async {
      run(
        () => service.update([
          _config('stays', 'stays.example.com'),
          _config('leaves', 'leaves.example.com'),
          _config('inner', 'inner.example.com', jumpHostId: 'bastion'),
        ]),
      );
      await clock.elapse(Duration.zero);
      prober.probed.clear();
      events.clear();

      // Removal alone keeps the schedule.
      run(() => service.update([_config('stays', 'stays.example.com')]));
      await clock.elapse(Duration.zero);
      expect(prober.probed, isEmpty);

      await clock.elapse(_sweep);
      expect(prober.probed, ['stays.example.com:22']);
      expect(answers(), {'stays': ReachabilityStatus.online});
    },
  );

  test('a new target sweeps at once; an unchanged update waits for the '
      'schedule', () async {
    run(() => service.update([_config('a', 'a.example.com')]));
    await clock.elapse(Duration.zero);
    expect(prober.probed, ['a.example.com:22']);

    run(() => service.update([_config('a', 'a.example.com')]));
    await clock.elapse(const Duration(seconds: 10));
    expect(prober.probed, hasLength(1));

    run(
      () => service.update([
        _config('a', 'a.example.com'),
        _config('b', 'b.example.com'),
      ]),
    );
    await clock.elapse(Duration.zero);
    expect(
      prober.probed.skip(1),
      unorderedEquals(['a.example.com:22', 'b.example.com:22']),
    );
    expect(answers().keys, unorderedEquals(['a', 'b']));
  });

  test('an endpoint change probes the new endpoint and drops the old '
      "one's answer", () async {
    prober.hold = true;
    run(() => service.update([_config('srv', 'old.example.com')]));
    await clock.elapse(Duration.zero);
    expect(prober.probed, ['old.example.com:22']);

    prober.hold = false;
    run(() => service.update([_config('srv', 'new.example.com')]));
    prober.held.single.complete(ProbeStatus.online);
    await clock.elapse(Duration.zero);

    expect(prober.probed, ['old.example.com:22', 'new.example.com:22']);
    expect(events, hasLength(1), reason: 'the old probe is not reported');
  });

  test('an empty target list stops probing', () async {
    run(
      () => service.update([
        _config('a', 'a.example.com'),
        _config('inner', 'inner.example.com', jumpHostId: 'bastion'),
      ]),
    );
    await clock.elapse(Duration.zero);
    prober.probed.clear();
    events.clear();

    run(() => service.update(const []));
    await clock.elapse(const Duration(minutes: 5));
    expect(prober.probed, isEmpty);
    expect(events, isEmpty);
  });
}
