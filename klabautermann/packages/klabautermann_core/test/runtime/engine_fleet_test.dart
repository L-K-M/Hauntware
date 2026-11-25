import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/alerts/alert_evaluator.dart';
import 'package:klabautermann_core/src/fleet/imported_fleet.dart';
import 'package:klabautermann_core/src/fleet/synced_fleet.dart';
import 'package:klabautermann_core/src/links/channel_quota.dart';
import 'package:klabautermann_core/src/operations/confirmation.dart';
import 'package:klabautermann_core/src/operations/operation_plan.dart';
import 'package:klabautermann_core/src/operations/plan_registry.dart';
import 'package:klabautermann_core/src/runtime/engine_fleet.dart';
import 'package:klabautermann_core/src/sampling/subscriptions.dart';
import 'package:klabautermann_core/src/services/disk_usage.dart';
import 'package:klabautermann_core/src/services/packages.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show DiskUsageTree, HostProfile;
import 'package:seance_core/catalog.dart' show EndpointPin, EndpointPinStore;
import 'package:seance_core/seance_core.dart' show ImportedHost, ServerConfig;
import 'package:test/test.dart';

const _idA = 'srv-a';
const _idB = 'srv-b';

/// The fleet's own contract (ENG-11 step 2): a server that leaves the
/// fleet is forgotten by every consumer the refresh reaches, a trusted
/// synced server a round no longer confirms is reported changed, and a
/// relist never applies a listing whose servers a newer round replaced.
///
/// Every heavy consumer ([LinkSupervisor], [SamplingScheduler],
/// [LogStreamRouter], [DockerRouter], [AdminModeController],
/// [OperationTracker], [ExecSessions], [PortForwards],
/// [CapabilityCache], [HistoryStore]) is a `final class` the test cannot
/// implement, so the cases below pass no instance for them and assert the
/// retention of the consumers that do expose their state: sampling,
/// channel quotas, plans, disk trees, profiles and the viewed set. Those
/// calls are unchanged one-line forwards.
void main() {
  test('refreshFleet forgets a server that left in what it touches', () async {
    final events = <dynamic>[];
    final sampling = SamplingSubscriptions();
    final quotas = ChannelQuotas();
    final plans = PlanRegistry(now: () => DateTime.utc(2026, 1, 1));
    final trees = DiskUsageTrees(now: () => DateTime.utc(2026, 1, 1));
    final profiles = <String, HostProfile>{};
    final viewed = <String>{};
    var hosts = <ImportedHost>[_host('a'), _host('b')];
    final aId = '${importIdPrefix}a';
    final bId = '${importIdPrefix}b';

    final bGone = Completer<void>();
    final bRead = Completer<DiskUsageTree?>();
    final bTree = trees.tree(
      bId,
      '/',
      elevated: false,
      fresh: true,
      read: (cancelled) {
        unawaited(cancelled.then((_) => bGone.complete()));
        return bRead.future;
      },
    );

    final fleet = _fleet(
      events: events,
      imports: (
        hosts: () => hosts,
        hops: () => const <ImportedHost>[],
        detail: () => ImportedHostDetail.full,
      ),
      sampling: sampling,
      channelQuotas: quotas,
      plans: plans,
      diskTrees: trees,
      profiles: profiles,
      viewed: viewed,
    );
    fleet.refreshFleet();
    expect(fleet.fleetIds, {aId, bId});

    sampling.subscribe(
      Subscribe(
        serverId: bId,
        subscriptionId: 'view-b',
        streams: const {SampleStream.overview},
      ),
    );
    profiles[bId] = HostProfile(uid: 1000, user: 'me');
    viewed.addAll({aId, bId});
    final bQuota = quotas.of(bId);
    plans.hold(_plan(bId), linkGeneration: 0);

    hosts = <ImportedHost>[_host('a')];
    fleet.refreshFleet();
    await pumpEventQueue();

    expect(fleet.fleetIds, {aId});
    expect(fleet.fleetEntries().map((entry) => entry.serverId), [aId]);
    expect(
      sampling.streamsOf(bId, 'view-b'),
      isNull,
      reason: 'its subscriptions go',
    );
    expect(
      identical(quotas.of(bId), bQuota),
      isFalse,
      reason: 'its channel quota is dropped',
    );
    expect(plans.length, 0, reason: 'its held plans are dropped');
    expect(bGone.isCompleted, isTrue, reason: 'its disk tree is cancelled');
    bRead.complete(null);
    await bTree;
    expect(profiles.containsKey(bId), isFalse);
    expect(viewed, {aId});
  });

  test('applySynced reports a trusted server no longer confirmed', () {
    final events = <dynamic>[];
    final config = _server(_idA);
    final pin = _pin(config);
    final fleet = _fleet(events: events);

    // A listing that still confirms it changes nothing.
    fleet.trustedIds = {_idA};
    fleet.applySynced(SyncedFleet([config], pins: {_idA: pin}));
    expect(events.whereType<EndpointChanged>(), isEmpty);

    // The next listing holds it but does not confirm it.
    fleet.applySynced(SyncedFleet([config]));

    expect(events.whereType<EndpointChanged>().map((event) => event.serverId), [
      _idA,
    ]);
    expect(fleet.synced.confirmedIds, isEmpty);

    // No longer trusted, the same listing reports nothing.
    events.clear();
    fleet.applySynced(SyncedFleet([config]));
    expect(events.whereType<EndpointChanged>(), isEmpty);
  });

  test(
    'relistSynced does not apply a listing a newer round replaced',
    () async {
      final events = <dynamic>[];
      final pins = _GatedPins();
      final fleet = _fleet(events: events, endpointPins: pins);
      final oldServers = [_server(_idA)];

      fleet.syncedServers = oldServers;
      final relist = fleet.relistSynced();
      await pumpEventQueue();
      await pumpEventQueue();
      expect(pins.called, [_idA]);

      // A round that took meanwhile replaced the servers this relist reads.
      fleet.syncedServers = [_server(_idB)];
      pins.gate.complete();
      await relist;

      expect(
        fleet.synced.entries,
        isEmpty,
        reason: 'the old listing is dropped',
      );
    },
  );
}

ImportedHost _host(String alias) => ImportedHost(
  alias: alias,
  hostName: '$alias.example',
  port: 22,
  user: 'me',
);

ServerConfig _server(String id) => ServerConfig(
  id: id,
  label: id,
  host: '$id.example',
  username: 'me',
  createdAt: 0,
  updatedAt: 0,
);

EndpointPin _pin(ServerConfig server) => EndpointPin(
  serverId: server.id,
  host: server.host,
  port: server.port,
  username: server.username,
  jumpRouteIds: const [],
  confirmedAt: DateTime.utc(2026, 1, 1),
);

OperationPlan _plan(String serverId) => OperationPlan(
  intent: UnitAction(
    serverId,
    unit: 'nginx.service',
    verb: SystemctlVerb.restart,
  ),
  kind: OperationKind.restart,
  targetName: 'nginx.service',
  steps: [
    ShellStep(['true']),
  ],
  requiredLevel: RequiredLevel.login,
  runner: const RunnerFacts(identity: 'me'),
);

EngineFleet _fleet({
  required List<dynamic> events,
  EngineImports? imports,
  SamplingSubscriptions? sampling,
  ChannelQuotas? channelQuotas,
  PlanRegistry? plans,
  PackageReports? packageReports,
  DiskUsageTrees? diskTrees,
  Map<String, HostProfile>? profiles,
  Set<String>? viewed,
  EndpointPinStore? endpointPins,
}) => EngineFleet(
  sampling: sampling ?? SamplingSubscriptions(),
  alerts: AlertEvaluator(),
  scheduler: () => null,
  logs: () => null,
  operations: () => null,
  channelQuotas: channelQuotas ?? ChannelQuotas(),
  links: null,
  viewed: viewed ?? <String>{},
  terminals: () => null,
  forwards: () => null,
  docker: () => null,
  admin: () => null,
  plans: plans ?? PlanRegistry(),
  packageReports: packageReports ?? PackageReports(now: DateTime.now),
  diskTrees: diskTrees ?? DiskUsageTrees(),
  profiles: profiles ?? <String, HostProfile>{},
  capabilities: () => null,
  history: () => null,
  reachability: null,
  imports:
      imports ??
      (
        hosts: () => const <ImportedHost>[],
        hops: () => const <ImportedHost>[],
        detail: () => ImportedHostDetail.full,
      ),
  localUser: 'me',
  endpointPins: endpointPins ?? const _NoPins(),
  sync: () => throw UnimplementedError('these tests never read the account'),
  detach: (work) => work?.ignore(),
  send: events.add,
);

final class _NoPins implements EndpointPinStore {
  const _NoPins();

  @override
  Future<EndpointPin?> pinFor(String serverId) async => null;

  @override
  Future<void> confirm(EndpointPin pin) async {}

  @override
  Future<void> drop(String serverId) async {}
}

/// Answers [pinFor] only once [gate] completes, so a test can replace the
/// fleet's servers while a relist is reading the pins.
final class _GatedPins implements EndpointPinStore {
  final called = <String>[];
  final gate = Completer<void>();

  @override
  Future<EndpointPin?> pinFor(String serverId) async {
    called.add(serverId);
    await gate.future;
    return null;
  }

  @override
  Future<void> confirm(EndpointPin pin) async {}

  @override
  Future<void> drop(String serverId) async {}
}
