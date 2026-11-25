import 'dart:async';
import 'dart:io';

import 'package:klabautermann_core/src/audit/audit_log.dart';
import 'package:klabautermann_core/src/engine/protocol.dart';
import 'package:klabautermann_core/src/engine/request_ids.dart';
import 'package:klabautermann_core/src/links/channel_quota.dart';
import 'package:klabautermann_core/src/operations/plan_registry.dart';
import 'package:klabautermann_core/src/runtime/engine_actions.dart';
import 'package:test/test.dart';

const _serverId = 's1';

/// The moved handlers' own contract: a cancel answers nothing, a run with
/// no held plan refuses as [ActionRefusalReason.unknownPlan], and a
/// footprint query outside the fleet is rejected by name. Links are off,
/// so the runner and the trackers stay null; that is the engine's shape
/// before its links block runs, and each case below settles without one.
void main() {
  late List<dynamic> events;

  EngineActions actions({Set<String> fleetIds = const {}}) {
    events = [];
    return EngineActions(
      links: null,
      admin: () => null,
      audit: AuditLog(Directory.systemTemp, storage: AuditStorage.memory),
      scheduler: () => null,
      profiles: const {},
      plans: PlanRegistry(),
      linkGenerations: const {},
      channelQuotas: ChannelQuotas(),
      docker: () => null,
      operations: () => null,
      safetyPolicy: () => const SafetyPolicy(),
      deviceName: () => '',
      fleetIds: () => fleetIds,
      send: events.add,
      detach: (work, {onError}) => unawaited(
        work?.then<void>(
          (_) {},
          onError: onError ?? (Object _, StackTrace _) {},
        ),
      ),
      reject: (request, reason) => events.add(
        RequestRejected(
          request.runtimeType.toString(),
          reason,
          requestId: requestIdOf(request),
        ),
      ),
    );
  }

  test('a CancelAction for an unknown plan answers nothing', () {
    actions().cancelAction(const CancelAction('p1'));

    expect(events, isEmpty);
  });

  test('a RunAction without a held plan answers unknownPlan', () {
    actions().runAction(
      const RunAction('p1', ActionConfirmation(tier: ConfirmationTier.none)),
    );

    expect(
      events.single,
      isA<ActionRefused>()
          .having(
            (event) => event.reason,
            'reason',
            ActionRefusalReason.unknownPlan,
          )
          .having((event) => event.planId, 'planId', 'p1')
          .having((event) => event.intent, 'intent', isNull),
    );
  });

  test('a FootprintQuery outside the fleet is rejected by name', () {
    actions().footprintQuery(const FootprintQuery(_serverId));

    expect(
      events.single,
      isA<RequestRejected>()
          .having((event) => event.requestName, 'requestName', 'FootprintQuery')
          .having(
            (event) => event.reason,
            'reason',
            'no fleet server $_serverId',
          )
          .having((event) => event.requestId, 'requestId', isNull),
    );
  });

  test('an AcknowledgeOperation without a tracker is refused', () {
    actions().acknowledgeOperation(
      const AcknowledgeOperation(_serverId, 'op1'),
    );

    expect(
      events.single,
      isA<RequestRejected>()
          .having(
            (event) => event.requestName,
            'requestName',
            'AcknowledgeOperation',
          )
          .having((event) => event.reason, 'reason', 'links are off')
          .having((event) => event.requestId, 'requestId', 'op1'),
    );
  });

  test('a session lend with no link runs its body as it is', () async {
    expect(await actions().lendSession(_serverId, () async => 7), 7);
  });

  test('a stack edit lookup is null while links are off', () {
    expect(actions().stackEditLookup(_serverId), isNull);
  });
}
