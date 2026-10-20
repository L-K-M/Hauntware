// The engine's Docker routes and detached redeploys on the GitHub-hosted
// Ubuntu runner's own engine (M4 E30, X3, X4 and X5): the sudo relay
// (rank 3) through the password prelude in admin mode, and none without
// it; a redeploy as root through that relay under `systemd-run` on the
// system manager, which outlives a forced reconnect, re-attaches, and
// whose root-owned files go only once admin mode is on again; and the
// login user's redeploy over the CLI relay (rank 2) under `systemd-run
// --uid` in admin mode and under `systemd-run --user` with linger
// without it. Root's default Docker context points at a socket nothing
// listens on, so `--host` in every step is what reaches the engine.
// runner_vm.sh runs the registry and the stacks and runs these one at a
// time; without it they skip.
@Tags(['runner-vm'])
@Timeout(Duration(minutes: 6))
library;

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show kRootOpsDir;
import 'package:test/test.dart';

import 'support/actions.dart';
import 'support/fixture.dart';
import 'support/runner_vm.dart';

/// The label each new digest of a stack's image carries, with the
/// revision it was pushed as.
const _revisionLabel = 'klabautermann.runner-vm.revision';

/// Covers the ladder's probes and the version negotiation over a relay.
const _endpointWait = Duration(seconds: 60);

/// Covers the pull from the runner's registry and the recreate.
const _redeployWait = Duration(seconds: 120);

/// Covers the supervisor seeing the link drop and dialling again.
const _redialWait = Duration(seconds: 90);

void main() {
  final vm = RunnerVm.fromEnvironment();
  if (vm == null) {
    test('the runner-VM Docker suite', () {}, skip: runnerVmSkipReason);
    return;
  }

  var revision = 1;
  var watches = 0;

  /// An engine with management on for every imported server, connected
  /// to [serverId] with the capability probe answered on this link, so
  /// plans can read its profile and endpoint.
  Future<FixtureEngine> start(String name, String serverId) async {
    final engine = await vm.engine(name);
    manage(engine, [
      limitedServer,
      journalServer,
      sudoServer,
      nocacheServer,
      lingerServer,
    ]);
    await engine.connect(serverId, vm.hostKeys);
    await engine.subscribe(serverId, {SampleStream.core});
    bool live(HostProfileChanged e) =>
        e.serverId == serverId && e.cachedAt == null;
    if (!engine.seen.whereType<HostProfileChanged>().any(live)) {
      await engine.until<HostProfileChanged>(live);
    }
    return engine;
  }

  /// Turns admin mode on for [serverId] with [password]; anything else
  /// fails the test.
  Future<void> admin(
    FixtureEngine engine,
    String serverId,
    String password,
  ) async {
    final (state, _) = await turnOnAdmin(engine, serverId, [password]);
    expect(state.phase, AdminModePhase.on, reason: '${state.failure}');
  }

  /// Watches [serverId]'s containers, so the engine resolves its endpoint
  /// and says what it found.
  void watch(FixtureEngine engine, String serverId) => engine.send(
    DockerWatch(
      serverId: serverId,
      watchId: 'runner-vm-${watches++}',
      lists: const {DockerWatchList.containers},
    ),
  );

  /// The next endpoint state for [serverId] that [accept] takes, or the
  /// latest one already seen when it does.
  Future<DockerEndpointState> endpoint(
    FixtureEngine engine,
    String serverId,
    bool Function(DockerEndpointState state) accept,
  ) async {
    bool ours(DockerEndpointState e) => e.serverId == serverId;
    final latest = engine.seen.whereType<DockerEndpointState>().where(ours);
    if (latest.lastOrNull case final state? when accept(state)) return state;
    return engine.until<DockerEndpointState>(
      (e) => ours(e) && accept(e),
      _endpointWait,
    );
  }

  /// [user]'s stack container, as compose names it.
  String containerOf(String user) => '$user-app-1';

  Future<String> containerId(String user) async => (await vm.docker([
    'inspect',
    '--format',
    '{{.Id}}',
    containerOf(user),
  ])).trim();

  Future<String> revisionOf(String user) async => (await vm.docker([
    'inspect',
    '--format',
    '{{index .Config.Labels "$_revisionLabel"}}',
    containerOf(user),
  ])).trim();

  /// Pushes a new digest of [user]'s stack image to the registry, with
  /// the runner's own tag back on the old one, so only the redeploy's
  /// pull fetches it; returns the revision it carries.
  Future<String> pushNewDigest(String user) async {
    final image = '${vm.registry}/$user:1';
    final label = '${++revision}';
    final old = (await vm.docker([
      'image',
      'inspect',
      '--format',
      '{{.Id}}',
      image,
    ])).trim();
    await vm.docker([
      'commit',
      '--change',
      'LABEL $_revisionLabel=$label',
      containerOf(user),
      image,
    ]);
    await vm.docker(['push', '--quiet', image]);
    await vm.docker(['image', 'tag', old, image]);
    return label;
  }

  /// Expects every step of [preview] to name the route's socket with
  /// `--host`: root's default context reaches nothing.
  void expectHostInEveryStep(ActionPreview preview, DockerEndpointRoute route) {
    expect(preview.steps, hasLength(3));
    expect(
      preview.steps,
      everyElement(
        isA<ShellStep>().having(
          (s) => s.argv.join(' '),
          'argv',
          contains('--host unix://${route.socketPath}'),
        ),
      ),
    );
  }

  /// The next list from [serverId] that holds operation [id] in a state
  /// [accept] takes, and that operation. Lists an earlier wait read past
  /// do not count, so a list after a reconnect proves the re-attach.
  Future<DetachedOperation> nextOperation(
    FixtureEngine engine,
    String serverId,
    String id,
    bool Function(DetachedOperation operation) accept, {
    Duration timeout = _redeployWait,
  }) async {
    final changed = await engine.until<OperationsChanged>(
      (e) =>
          e.serverId == serverId &&
          e.operations.any((o) => o.id == id && accept(o)),
      timeout,
    );
    return changed.operations.singleWhere((o) => o.id == id);
  }

  /// [serverId]'s operation [id] once a list holds it in a state [accept]
  /// takes, counting the lists an earlier wait read past (a list can
  /// arrive before the event that wait was for).
  Future<DetachedOperation> untilOperation(
    FixtureEngine engine,
    String serverId,
    String id,
    bool Function(DetachedOperation operation) accept, {
    Duration timeout = _redeployWait,
  }) async {
    for (final seen in engine.seen.whereType<OperationsChanged>()) {
      if (seen.serverId != serverId) continue;
      if (seen.operations.where((o) => o.id == id).firstOrNull
          case final operation? when accept(operation)) {
        return operation;
      }
    }
    return nextOperation(engine, serverId, id, accept, timeout: timeout);
  }

  /// Waits until [serverId]'s list no longer holds operation [id], which
  /// the latest list already read may show.
  Future<void> untilOperationGone(
    FixtureEngine engine,
    String serverId,
    String id,
  ) async {
    bool gone(OperationsChanged e) =>
        e.serverId == serverId && !e.operations.any((o) => o.id == id);
    final latest = engine.seen
        .whereType<OperationsChanged>()
        .where((e) => e.serverId == serverId)
        .lastOrNull;
    if (latest != null && gone(latest)) return;
    await engine.until<OperationsChanged>(gone, actionWait);
  }

  /// The audit record of the redeploy on [serverId], the engine's only
  /// one.
  Future<AuditRecord> redeployRecord(
    FixtureEngine engine,
    String serverId,
  ) async {
    engine.send(AuditQuery(serverId));
    final audit = await engine.until<AuditRecords>(
      (e) => e.serverId == serverId,
    );
    return audit.records.singleWhere((r) => r.action == 'RedeployStack');
  }

  test('rank 3 through the password prelude: the sudo relay reaches the '
      'engine only in admin mode, and a redeploy runs as root under '
      'systemd-run, outlives a forced reconnect, re-attaches, and its '
      'root files go once admin mode is on again (CN-07, STK-06, '
      'SAF-23)', () async {
    final user = vm.sudoUser;
    final engine = await start('docker-sudo-relay', sudoServer);

    // The socket refuses the account and sudo exists: no route until
    // admin mode is on.
    watch(engine, sudoServer);
    final denied = await endpoint(
      engine,
      sudoServer,
      (s) => s.phase == DockerEndpointPhase.failed,
    );
    expect(denied.failure, DockerEndpointFailure.noRoute);
    expect(denied.noRouteReason, DockerNoRouteReason.needsAdminMode);

    await admin(engine, sudoServer, await vm.sudoPassword());
    final ready = await endpoint(
      engine,
      sudoServer,
      (s) => s.phase == DockerEndpointPhase.ready,
    );
    final route = ready.route!;
    expect(route.rank, DockerRank.sudoRelay);
    expect(route.rootEquivalence, DockerRootEquivalence.sudoRelay);

    final pushed = await pushNewDigest(user);
    final before = await containerId(user);
    final planned = await plan(
      engine,
      RedeployStack(sudoServer, project: user),
    );
    final preview = planned.preview;
    expect(preview.detached, isTrue);
    expect(preview.requiredLevel, RequiredLevel.admin);
    expect(preview.runner.identity, 'root');
    expect(preview.runner.credentials, RunnerCredentials.adminPassword);
    expect(
      preview.hostWrites,
      containsAll([
        HostWriteRow.rootOperationRecords,
        HostWriteRow.transientUnit,
      ]),
    );
    expectHostInEveryStep(preview, route);

    final started = await run(engine, planned) as ActionFinished;
    expectSucceeded(started);
    final id = started.operationId!;
    await untilOperation(engine, sudoServer, id, (_) => true);

    // The session's sshd processes die, as on a dropped network path:
    // admin mode ends with the link, the operation goes on under the
    // system manager, and the engine finds it again over a new link.
    final processes = await vm.connectionProcesses(user);
    expect(processes, isNotEmpty);
    await vm.sudo(['kill', '-KILL', for (final pid in processes) '$pid']);
    final ended = await engine.until<AdminModeState>(
      (s) => s.serverId == sudoServer && s.phase == AdminModePhase.expired,
      _redialWait,
    );
    expect(ended.ended, AdminEnd.linkLost);
    await engine.until<LinkState>(
      (e) => e.serverId == sudoServer && e.status is LinkReady,
      _redialWait,
    );
    final done = await nextOperation(
      engine,
      sudoServer,
      id,
      (o) => o.state != DetachedOperationState.running,
    );
    expect(done.state, DetachedOperationState.done);
    expect(done.exitCode, 0);
    expect(done.directory, OpDirectoryKind.root);
    expect(done.unit, 'klabautermann-op-$id.service');
    expect(await containerId(user), isNot(before));
    expect(await revisionOf(user), pushed);

    // Acknowledged with admin mode off, the result is audited, and its
    // files wait: the login user cannot unlink in the root directory.
    engine.send(AcknowledgeOperation(sudoServer, id));
    await untilOperation(
      engine,
      sudoServer,
      id,
      (o) => o.acknowledged,
      timeout: actionWait,
    );
    expect(await vm.sudo(['ls', kRootOpsDir]), contains('$id.'));
    final record = await redeployRecord(engine, sudoServer);
    expect(record.targetName, user);
    expect(record.outcome, ActionOutcome.succeeded);
    expect(record.steps, everyElement(contains("'--host'")));

    // Admin mode on again deletes them through the prelude.
    await admin(engine, sudoServer, await vm.sudoPassword());
    await untilOperationGone(engine, sudoServer, id);
    expect(await vm.sudo(['ls', kRootOpsDir]), isNot(contains('$id.')));
  });

  test('in admin mode the login user\'s redeploy runs under systemd-run '
      '--uid over the CLI relay (STK-06, SAF-23)', () async {
    final user = vm.lingerUser;
    final engine = await start('docker-uid', lingerServer);
    await admin(engine, lingerServer, await vm.lingerPassword());

    // The account is in the docker group and forwarding is off on the
    // leg's sshd, so the CLI relays the API.
    watch(engine, lingerServer);
    final route = (await endpoint(
      engine,
      lingerServer,
      (s) => s.phase == DockerEndpointPhase.ready,
    )).route!;
    expect(route.rank, DockerRank.cliRelay);

    final pushed = await pushNewDigest(user);
    final planned = await plan(
      engine,
      RedeployStack(lingerServer, project: user),
    );
    final preview = planned.preview;
    expect(preview.requiredLevel, RequiredLevel.login);
    expect(preview.runner.identity, user);
    expect(preview.runner.credentials, RunnerCredentials.adminPassword);
    expect(
      preview.hostWrites,
      containsAll([
        HostWriteRow.userOperationRecords,
        HostWriteRow.transientUnit,
      ]),
    );
    expect(
      preview.hostWrites,
      isNot(contains(HostWriteRow.rootOperationRecords)),
    );
    expectHostInEveryStep(preview, route);

    final started = await run(engine, planned) as ActionFinished;
    expectSucceeded(started);
    final id = started.operationId!;
    final done = await untilOperation(
      engine,
      lingerServer,
      id,
      (o) => o.state != DetachedOperationState.running,
    );
    expect(done.state, DetachedOperationState.done);
    expect(done.exitCode, 0);
    expect(done.directory, OpDirectoryKind.user);
    expect(done.unit, 'klabautermann-op-$id.service');
    expect(await revisionOf(user), pushed);

    // The login user's files go at once.
    engine.send(AcknowledgeOperation(lingerServer, id));
    await untilOperationGone(engine, lingerServer, id);
  });

  test('without admin mode the login user\'s redeploy runs under '
      'systemd-run --user, which linger keeps (STK-06, SAF-23)', () async {
    final user = vm.lingerUser;
    final engine = await start('docker-user', lingerServer);
    final profile = await hostProfile(engine, lingerServer);
    expect(profile.lingerEnabled, isTrue);
    expect(profile.xdgRuntimeDir, isNotNull);

    watch(engine, lingerServer);
    final route = (await endpoint(
      engine,
      lingerServer,
      (s) => s.phase == DockerEndpointPhase.ready,
    )).route!;
    expect(route.rank, DockerRank.cliRelay);

    final pushed = await pushNewDigest(user);
    final planned = await plan(
      engine,
      RedeployStack(lingerServer, project: user),
    );
    final preview = planned.preview;
    expect(preview.requiredLevel, RequiredLevel.login);
    expect(preview.runner.identity, user);
    expect(preview.runner.credentials, RunnerCredentials.session);
    expect(
      preview.hostWrites,
      containsAll([
        HostWriteRow.userOperationRecords,
        HostWriteRow.transientUnit,
      ]),
    );
    expectHostInEveryStep(preview, route);

    final started = await run(engine, planned) as ActionFinished;
    expectSucceeded(started);
    final id = started.operationId!;
    final done = await untilOperation(
      engine,
      lingerServer,
      id,
      (o) => o.state != DetachedOperationState.running,
    );
    expect(done.state, DetachedOperationState.done);
    expect(done.exitCode, 0);
    expect(done.directory, OpDirectoryKind.user);
    expect(done.unit, 'klabautermann-op-$id.service');
    expect(await revisionOf(user), pushed);

    engine.send(AcknowledgeOperation(lingerServer, id));
    await untilOperationGone(engine, lingerServer, id);
  });
}
