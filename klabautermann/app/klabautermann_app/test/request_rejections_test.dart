import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/account_reads.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/port_forwards.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

/// CTL-05: the engine answers a request it refuses, or whose handling
/// failed, with a [RequestRejected] that carries the request's id. The
/// read, run or open that id names settles as it does without a link,
/// and every other one keeps waiting for its own answer.
void main() {
  late FakeEngineClient engine;

  setUp(() => engine = FakeEngineClient());
  tearDown(() => engine.close());

  /// The rejection the engine sends for [request], with [id].
  RequestRejected rejection(EngineRequest request, String id) =>
      RequestRejected(
        '${request.runtimeType}',
        'no fleet server $_server',
        requestId: id,
      );

  test('a rejected host query answers no link, not nothing', () async {
    final monitoring = MonitoringController(engine);
    addTearDown(monitoring.dispose);

    final refused = monitoring.queryHost(_server, const VarLogQuery());
    final kept = monitoring.queryHost(_server, const BootsQuery());
    final [first, second] = engine.sentOfType<HostQuery>().cast<HostQuery>();
    engine.emit(rejection(first, first.queryId));

    final result = await refused.timeout(const Duration(seconds: 1));
    expect(
      (result.payload as HostQueryFailed).failure,
      HostQueryFailure.noLink,
    );

    final answer = HostResult(
      serverId: _server,
      queryId: second.queryId,
      payload: const HostQueryFailed(HostQueryFailure.failed),
    );
    engine.emit(answer);
    expect(await kept, same(answer));
  });

  test('rejected unit, redaction and TLS reads settle too', () async {
    final monitoring = MonitoringController(engine);
    addTearDown(monitoring.dispose);

    final unit = monitoring.queryUnit(_server, const SocketsQuery());
    final redaction = monitoring.redactLines(const ['token=abc']);
    final tls = monitoring.checkTlsEndpoints(const []);
    for (final request in engine.sent.toList()) {
      final id = switch (request) {
        UnitQuery(:final requestId) => requestId,
        RedactLines(:final requestId) => requestId,
        CheckTlsEndpoints(:final requestId) => requestId,
        _ => null,
      };
      if (id != null) engine.emit(rejection(request, id));
    }

    const limit = Duration(seconds: 1);
    expect(
      ((await unit.timeout(limit)).payload as UnitQueryFailed).failure,
      UnitQueryFailure.noLink,
    );
    expect(await redaction.timeout(limit), isNull);
    expect(await tls.timeout(limit), isNull);
  });

  test('a rejection settles only the read of its own request: another '
      "concern's read with the same id keeps waiting", () async {
    final admin = AdminController(engine);
    addTearDown(admin.dispose);

    // The admin reads share one id counter.
    final smart = admin.readSmart(_server);
    final firewall = admin.readFirewall(_server);
    final asked = engine.sentOfType<ReadFirewall>().single as ReadFirewall;
    engine.emit(
      RequestRejected('ReadSmart', 'failed', requestId: asked.requestId),
    );
    engine.emit(rejection(asked, asked.requestId));

    expect(
      (await firewall.timeout(const Duration(seconds: 1))).failure,
      FirewallReportFailure.noLink,
    );
    var smartSettled = false;
    unawaitedThen(smart, () => smartSettled = true);
    await pumpEventQueue();
    expect(smartSettled, isFalse);
  });

  test(
    'the shared one-shot reads settle on a rejection of their request',
    () async {
      final accounts = AccountReads(engine);
      addTearDown(accounts.dispose);

      final read = accounts.read(_server);
      final asked = engine.sentOfType<ReadAccounts>().single as ReadAccounts;
      engine.emit(rejection(asked, asked.requestId));

      expect(
        (await read.timeout(const Duration(seconds: 1))).failure,
        isNotNull,
      );
    },
  );

  test('a rejected run ends as refused, a rejected preview answers, and a '
      'rejected editor read fails', () async {
    final operations = OperationsController(engine);
    addTearDown(operations.dispose);

    operations.run(
      'plan-1',
      const ActionConfirmation(tier: ConfirmationTier.acknowledge),
    );
    engine.emit(
      const RequestRejected('RunAction', 'engine error', requestId: 'plan-1'),
    );
    await pumpEventQueue();
    expect(
      (operations.runOf('plan-1')! as RunRefused).reason,
      ActionRefusalReason.engineUnavailable,
    );

    final plan = operations.plan(
      const UnitAction(
        _server,
        unit: 'nginx.service',
        verb: SystemctlVerb.restart,
      ),
    );
    engine.emit(const RequestRejected('PlanAction', 'engine error: boom'));
    final refused = await plan.timeout(const Duration(seconds: 1));
    expect(
      (refused as PlanRefused).reason,
      ActionRefusalReason.engineUnavailable,
    );

    final read = operations.readEditable(_server, const FileTarget('/etc/a'));
    final asked = engine.sentOfType<ReadEditable>().single as ReadEditable;
    engine.emit(rejection(asked, asked.requestId));
    expect(
      await read.timeout(const Duration(seconds: 1)),
      isA<EditReadFailed>(),
    );
  });

  test('a rejected port forward ends its row', () async {
    final forwards = PortForwardsController(engine);
    addTearDown(forwards.dispose);

    final id = forwards.open(_server, host: '127.0.0.1', port: 8080);
    engine.emit(
      RequestRejected('OpenPortForward', 'port forward: failed', requestId: id),
    );
    await pumpEventQueue();

    expect(forwards.forwardsFor(_server).single.ended, isNotNull);
  });
}

/// Runs [then] when [future] completes, without awaiting it.
void unawaitedThen(Future<Object?> future, void Function() then) {
  future.then((_) => then());
}
