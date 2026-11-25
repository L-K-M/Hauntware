import 'dart:async';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/alerts/alert_evaluator.dart';
import 'package:klabautermann_core/src/catalog/engine_sync.dart';
import 'package:klabautermann_core/src/catalog/engine_vault.dart';
import 'package:klabautermann_core/src/catalog/klabautermann_records.dart';
import 'package:klabautermann_core/src/catalog/sync_credentials.dart';
import 'package:klabautermann_core/src/fleet/synced_fleet.dart';
import 'package:klabautermann_core/src/runtime/engine_sync_chain.dart';
import 'package:seance_core/catalog.dart'
    show
        EndpointPin,
        EndpointPinStore,
        InMemoryConflictAwareHostKeyStore,
        SyncTuple;
import 'package:test/test.dart';

const _ruleId = '0b7e4c3a-5d1f-4e2a-9c8b-7a6f5e4d3c2b';

const _rule = SyncedRule(
  id: _ruleId,
  rule: ThresholdRule(
    metric: 'cpu.busy',
    scope: RuleScope.server,
    op: ThresholdOp.greaterThan,
    raise: ThresholdBound(value: 90, duration: Duration(minutes: 5)),
    clear: ThresholdBound(value: 70, duration: Duration(minutes: 2)),
    evalScope: RuleEvalScope.client,
  ),
  target: 'srv-a',
);

/// The chain's own contract (ENG-5): bodies run one at a time in order,
/// each link completes normally whatever its body throws, and the
/// preferences the app last heard decide what a send repeats.
void main() {
  late List<dynamic> events;
  late EngineSyncChain syncChain;

  setUp(() {
    events = [];
    syncChain = _chain(events: events, faults: events);
  });

  test('runs chained bodies one at a time, in order', () async {
    final gate = Completer<void>();
    final secondRan = Completer<void>();
    syncChain.chain(() async {
      events.add('first:start');
      await gate.future;
      events.add('first:end');
    });
    syncChain.chain(() async {
      events.add('second');
      secondRan.complete();
    });

    await pumpEventQueue();
    expect(events, ['first:start']);

    gate.complete();
    await secondRan.future;
    expect(events, ['first:start', 'first:end', 'second']);
  });

  test('a body that throws does not stop the next one', () async {
    syncChain.chain(() async => throw StateError('boom'));
    syncChain.chain(() async {
      events.add('next');
    });

    await pumpEventQueue();

    expect(events.whereType<String>(), ['next']);
    expect(events.whereType<StateError>(), hasLength(1));
  });

  test('sendServerPrefs sends AlertRulesChanged only when the rules '
      'changed', () async {
    final support = Directory.systemTemp.createTempSync('klab-sync-chain-');
    addTearDown(() => support.deleteSync(recursive: true));
    final records = await KlabautermannRecordStore.open(
      support,
      access: SupportDirectoryAccess.exclusive,
    );
    await records.put(
      'klabautermann:rule:$_ruleId',
      const SyncTuple(updatedAt: 1, deviceId: 'device-a'),
      encodeSyncedRule(_rule),
    );
    final sync = await _openSync(support);
    final sent = <dynamic>[];
    final chain = EngineSyncChain(
      sync: () => sync,
      send: sent.add,
      alerts: AlertEvaluator(),
      fleetEntries: () => const <FleetEntry>[],
      syncedFleet: () => SyncedFleet.empty,
      refreshSynced: () async {},
      relistSynced: () async {},
      endpointPins: const _NoPins(),
      pinPublicationRelease: null,
      fault: (error, stack) => sent.add(error),
    );

    await chain.sendServerPrefs();
    expect(sent.whereType<AlertRulesChanged>(), hasLength(1));

    sent.clear();
    await chain.sendServerPrefs();
    expect(sent.whereType<AlertRulesChanged>(), isEmpty);
  });
}

EngineSyncChain _chain({
  required List<dynamic> events,
  required List<dynamic> faults,
}) => EngineSyncChain(
  sync: () => throw StateError('sync is not used by these bodies'),
  send: events.add,
  alerts: AlertEvaluator(),
  fleetEntries: () => const <FleetEntry>[],
  syncedFleet: () => SyncedFleet.empty,
  refreshSynced: () async {},
  relistSynced: () async {},
  endpointPins: const _NoPins(),
  pinPublicationRelease: null,
  fault: (error, stack) => faults.add(error),
);

/// Opens a real [EngineSync] over [support], as the engine's own tests do;
/// the class is final, so the preferences send is exercised against it
/// rather than a fake.
Future<EngineSync> _openSync(Directory support) async {
  final keystore = _MemoryKeystore();
  late final EngineSync sync;
  final vault = EngineVault(
    support,
    access: SupportDirectoryAccess.exclusive,
    keystore: keystore,
    enrolled: () => sync.account != null,
  );
  return sync = await EngineSync.open(
    supportDirectory: support,
    access: SupportDirectoryAccess.exclusive,
    deviceId: 'device-a',
    hostKeys: InMemoryConflictAwareHostKeyStore(),
    keystore: keystore,
    vault: vault,
    transport: (baseUrl, {token}) => throw UnimplementedError(),
  );
}

final class _NoPins implements EndpointPinStore {
  const _NoPins();

  @override
  Future<EndpointPin?> pinFor(String serverId) async => null;

  @override
  Future<void> confirm(EndpointPin pin) async {}

  @override
  Future<void> drop(String serverId) async {}
}

final class _MemoryKeystore implements SyncKeystore {
  @override
  Future<void> putApiKey(String name, String value) async {}

  @override
  Future<String?> getApiKey(String name) async => null;

  @override
  Future<void> deleteApiKey(String name) async {}

  @override
  Future<List<int>?> readMasterKey() async => null;

  @override
  Future<void> writeMasterKey(List<int> key) async {}
}
