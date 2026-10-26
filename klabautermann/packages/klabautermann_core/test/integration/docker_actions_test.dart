// The engine's Docker and process actions end to end on the Docker
// fixture (M4 E28, X2 and X3): the real engine in its own isolate, links
// on, as the fixture user in the Docker host's `docker` group. Every
// container, image and stack action of the MVP, v1's volume create and
// remove, network remove, prune and pull, with the watched list
// following it; the refusals a managed stack, a protected container and
// an unverified or managed redeploy get; a kill and a stop and continue
// of the user's own process, with the start-time guard; and STK-06's
// detached redeploy under BusyBox `setsid` (spike S4), which pulls a new
// digest of the fixture registry's image and recreates the container,
// outlives the session's sshd processes, re-attaches, follows its output,
// is cleaned up and audited, with `--host` in every step. run.sh starts
// and seeds the fixture (seed_docker.sh, E27); without it these skip.
@Tags(['integration', 'docker'])
@Timeout(Duration(minutes: 4))
library;

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show HostCommands;
import 'package:seance_core/seance_core.dart' show SshLink;
import 'package:test/test.dart';

import 'support/actions.dart';
import 'support/docker_host.dart';
import 'support/fixture.dart';

/// The image seed_docker.sh tags, which the fixture's containers run.
const _image = 'klabautermann-fixture/busybox:1.37';

/// The fixture registry's app image, which the mutation stacks run.
const _appImage = 'registry:5000/klab/app:1';

/// dind's own socket, for the tests' side channel into the engine.
const _dindSocket = 'unix:///run/docker-fixture/docker.sock';

/// The engine's first candidate path (03 §5.4) as every step's `--host`
/// names it, and as the audit log's quoted steps show it.
const _host = 'unix://$dockerSocket';
const _quotedHost = "'--host' '$_host'";

/// The fixture user's operation directory on the Docker host, whose
/// login shell sets no `XDG_STATE_HOME` (03 §7.17).
const _opsDir = '/home/klab/.local/state/klabautermann/ops';

/// Covers a pull from the fixture registry and the recreate, and the
/// redial after the session's sshd processes are killed.
// A redeploy's operation lists have passed two minutes on a loaded CI
// runner (run 119864619389); the bound fails real deadlocks only.
const _redeployWait = Duration(seconds: 240);

/// Covers the supervisor seeing the link drop and dialling again.
// A Docker host restart plus a redial has passed 90 s on a loaded CI
// runner (run 120054453500); the bound fails real deadlocks only.
const _redialWait = Duration(seconds: 180);

/// Covers a container event reaching the watched list (DKE-02's 2 s) on
/// a busy runner.
const _listWait = Duration(seconds: 15);

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the Docker actions suite', () {}, skip: fixtureSkipReason);
    return;
  }

  late Map<Endpoint, Set<String>> hostKeys;
  setUpAll(() async => hostKeys = await fixture.dockerHostKeys());

  var watches = 0;

  /// Runs `docker` in dind as root, out of the engine's sight.
  Future<String> dind(List<String> arguments) => fixture.exec(
    FixtureService.dind,
    ['docker', '--host', _dindSocket, ...arguments],
  );

  /// [name]'s full container id, read in dind.
  Future<String> containerId(String name) async =>
      (await dind(['inspect', '--format', '{{.Id}}', name])).trim();

  /// An engine connected to the Docker host as the fixture user, with
  /// management on and the capability probe answered, so plans can read
  /// its profile and endpoint.
  Future<FixtureEngine> start(String name) async {
    final engine = await FixtureEngine.startDocker(fixture, name);
    manage(engine, [dockerServer]);
    await engine.connect(dockerServer, hostKeys);
    await engine.subscribe(dockerServer, {SampleStream.core});
    await engine.until<HostProfileChanged>(
      (e) => e.serverId == dockerServer && e.cachedAt == null,
    );
    return engine;
  }

  /// Watches [lists] on the Docker host and returns the watch id.
  String watch(FixtureEngine engine, Set<DockerWatchList> lists) {
    final watchId = 'actions-${watches++}';
    engine.send(
      DockerWatch(serverId: dockerServer, watchId: watchId, lists: lists),
    );
    return watchId;
  }

  /// Returns once the latest [list] that [accept] takes arrives. A list
  /// can arrive while an action runs, before its ActionFinished, and
  /// `run` reads past it: the latest one already seen counts too, since
  /// it is the list as it stands.
  Future<void> untilList(
    FixtureEngine engine,
    DockerWatchList list,
    bool Function(DockerPayload payload) accept,
  ) async {
    bool ours(DockerListChanged event) =>
        event.serverId == dockerServer && event.list == list;
    final latest = engine.seen.whereType<DockerListChanged>().where(ours);
    if (latest.lastOrNull case final event? when accept(event.payload)) {
      return;
    }
    await engine.until<DockerListChanged>(
      (event) => ours(event) && accept(event.payload),
      _listWait,
    );
  }

  /// Returns once the container list holds [test] for the container [id],
  /// or for its absence when [test] gets null.
  Future<void> untilContainer(
    FixtureEngine engine,
    String id,
    bool Function(ContainerSummary? container) test,
  ) => untilList(engine, DockerWatchList.containers, (payload) {
    if (payload case DockerQueryFailed(:final failure)) {
      fail('the container list failed: ${failure.name}');
    }
    final containers = (payload as DockerContainersPayload).containers;
    return test(containers.where((c) => c.id == id).firstOrNull);
  });

  test('each container action runs on the id and the list follows '
      '(CTR-02, CTR-05)', () async {
    const name = 'actions-target';
    await dind([
      'run',
      '--detach',
      '--name',
      name,
      _image,
      'sh',
      '-c',
      'while :; do sleep 60; done',
    ]);
    addTearDown(() => dind(['rm', '--force', name]));
    final id = await containerId(name);
    final engine = await start('container-actions');
    watch(engine, {DockerWatchList.containers});
    await untilContainer(engine, id, (c) => c?.state == 'running');

    Future<void> act(
      ContainerVerb verb,
      String state, {
      KillSignal? signal,
    }) async {
      final planned = await plan(
        engine,
        ContainerAction(
          dockerServer,
          containerId: id,
          verb: verb,
          signal: signal,
        ),
      );
      final preview = planned.preview;
      expect(preview.targetName, name);
      expect(preview.requiredLevel, RequiredLevel.login);
      expect(preview.runner.identity, fixture.user);
      expect(preview.steps.single, isA<ApiStep>());
      final step = preview.steps.single as ApiStep;
      expect(step.method, 'POST');
      expect(step.path, endsWith('/containers/$id/${verb.name}'));
      expectSucceeded(await run(engine, planned));
      await untilContainer(engine, id, (c) => c?.state == state);
    }

    await act(ContainerVerb.pause, 'paused');
    await act(ContainerVerb.unpause, 'running');
    await act(ContainerVerb.stop, 'exited');
    await act(ContainerVerb.start, 'running');
    await act(ContainerVerb.restart, 'running');
    await act(ContainerVerb.kill, 'exited', signal: KillSignal.sigkill);

    final removal = await plan(
      engine,
      RemoveContainer(dockerServer, containerId: id),
    );
    expect(removal.preview.requiredTier, ConfirmationTier.acknowledge);
    expectSucceeded(await run(engine, removal));
    await untilContainer(engine, id, (c) => c == null);
  });

  test('a bulk action runs one step per container and the list follows '
      '(CTR-07)', () async {
    const names = ['actions-bulk-a', 'actions-bulk-b'];
    for (final name in names) {
      await dind([
        'run',
        '--detach',
        '--name',
        name,
        _image,
        'sh',
        '-c',
        'while :; do sleep 60; done',
      ]);
      addTearDown(() => dind(['rm', '--force', name]));
    }
    final ids = [for (final name in names) await containerId(name)];
    final engine = await start('bulk-actions');
    watch(engine, {DockerWatchList.containers});
    for (final id in ids) {
      await untilContainer(engine, id, (c) => c?.state == 'running');
    }

    Future<void> act(ContainerBulkVerb verb, String? state) async {
      final planned = await plan(
        engine,
        ContainerBulkAction(dockerServer, containerIds: ids, verb: verb),
      );
      expect(planned.preview.targetName, names.join(', '));
      expect(planned.preview.steps, hasLength(2));
      expectSucceeded(await run(engine, planned));
      for (final id in ids) {
        await untilContainer(engine, id, (c) => c?.state == state);
      }
    }

    await act(ContainerBulkVerb.stop, 'exited');
    await act(ContainerBulkVerb.start, 'running');
    await act(ContainerBulkVerb.restart, 'running');
    await act(ContainerBulkVerb.stop, 'exited');
    await act(ContainerBulkVerb.remove, null);
  });

  test('an unused image is removed; one in use only by force, with its '
      'typed name (IMG-02)', () async {
    const unused = 'actions-unused:1';
    const inUse = 'actions-in-use:1';
    await dind(['commit', 'coolify-app', unused]);
    await dind(['tag', _image, inUse]);
    addTearDown(() async {
      for (final tag in [unused, inUse]) {
        try {
          await dind(['image', 'rm', tag]);
        } on Object {
          // Removed by the test.
        }
      }
    });
    final engine = await start('image-actions');
    watch(engine, {DockerWatchList.images});

    final removed = await plan(
      engine,
      RemoveImage(dockerServer, image: unused),
    );
    expect(removed.preview.requiredTier, ConfirmationTier.acknowledge);
    expectSucceeded(await run(engine, removed));
    await untilList(
      engine,
      DockerWatchList.images,
      (payload) =>
          payload is DockerImagesPayload &&
          !payload.images.any((i) => i.repoTags.contains(unused)),
    );

    expect(
      await planAnswer(engine, RemoveImage(dockerServer, image: inUse)),
      isA<ActionRefused>().having(
        (r) => r.reason,
        'reason',
        ActionRefusalReason.imageInUse,
      ),
    );
    final forced = await plan(
      engine,
      RemoveImage(dockerServer, image: inUse, force: true),
    );
    expect(forced.preview.requiredTier, ConfirmationTier.typedPhrase);
    expect(
      await run(
        engine,
        forced,
        confirmation: const ActionConfirmation(
          tier: ConfirmationTier.acknowledge,
        ),
      ),
      isA<ActionRefused>().having(
        (r) => r.reason,
        'reason',
        ActionRefusalReason.confirmationMismatch,
      ),
    );
    // A refused run takes its plan with it: the next run needs a new one.
    expect(
      await run(engine, forced),
      isA<ActionRefused>().having(
        (r) => r.reason,
        'reason',
        ActionRefusalReason.unknownPlan,
      ),
    );
    await planAndRun(
      engine,
      RemoveImage(dockerServer, image: inUse, force: true),
    );
    // The tag went; the image its containers run stays.
    expect(await dind(['image', 'ls', '--quiet', inUse]), isEmpty);
    expect(await dind(['image', 'ls', '--quiet', _image]), isNotEmpty);
  });

  test('a volume is created, refused while a container mounts it, and '
      'removed with its typed name (VOL-02)', () async {
    const volume = 'actions-volume';
    const user = 'actions-volume-user';
    addTearDown(() async {
      for (final arguments in [
        ['rm', '--force', user],
        ['volume', 'rm', volume],
      ]) {
        try {
          await dind(arguments);
        } on Object {
          // Removed by the test.
        }
      }
    });
    final engine = await start('volume-actions');
    watch(engine, {DockerWatchList.volumes});

    bool listed(DockerPayload payload) =>
        payload is DockerVolumesPayload &&
        payload.volumes.any((v) => v.name == volume);

    final created = await plan(
      engine,
      CreateVolume(dockerServer, name: volume, driver: 'local'),
    );
    expect(created.preview.requiredTier, ConfirmationTier.acknowledge);
    expectSucceeded(await run(engine, created));
    await untilList(engine, DockerWatchList.volumes, listed);
    expect(
      (await dind([
        'volume',
        'inspect',
        '--format',
        '{{.Driver}}',
        volume,
      ])).trim(),
      'local',
    );
    expect(
      await planAnswer(engine, CreateVolume(dockerServer, name: volume)),
      isA<ActionRefused>().having(
        (r) => r.reason,
        'reason',
        ActionRefusalReason.volumeExists,
      ),
    );

    // A stopped container still holds the volume.
    await dind(['create', '--name', user, '-v', '$volume:/data', _image]);
    expect(
      await planAnswer(engine, RemoveVolume(dockerServer, name: volume)),
      isA<ActionRefused>().having(
        (r) => r.reason,
        'reason',
        ActionRefusalReason.volumeInUse,
      ),
    );
    await dind(['rm', user]);

    final removal = await plan(
      engine,
      RemoveVolume(dockerServer, name: volume),
    );
    expect(removal.preview.requiredTier, ConfirmationTier.typedPhrase);
    expectSucceeded(await run(engine, removal));
    await untilList(
      engine,
      DockerWatchList.volumes,
      (payload) => payload is DockerVolumesPayload && !listed(payload),
    );
    expect(
      await dind(['volume', 'ls', '--quiet', '--filter', 'name=^$volume\$']),
      isEmpty,
    );
  });

  test('a network is refused while built in or a container is on it, and '
      'removed once it is free (DNW-02)', () async {
    const network = 'actions-network';
    const user = 'actions-network-user';
    addTearDown(() async {
      for (final arguments in [
        ['rm', '--force', user],
        ['network', 'rm', network],
      ]) {
        try {
          await dind(arguments);
        } on Object {
          // Removed by the test.
        }
      }
    });
    final engine = await start('network-actions');
    watch(engine, {DockerWatchList.networks});
    final id = (await dind(['network', 'create', network])).trim();

    bool listed(DockerPayload payload) =>
        payload is DockerNetworksPayload &&
        payload.networks.any((n) => n.name == network);

    await untilList(engine, DockerWatchList.networks, listed);
    expect(
      await planAnswer(
        engine,
        RemoveNetwork(dockerServer, networkId: 'bridge'),
      ),
      isA<ActionRefused>().having(
        (r) => r.reason,
        'reason',
        ActionRefusalReason.builtinNetwork,
      ),
    );

    await dind([
      'run',
      '--detach',
      '--name',
      user,
      '--network',
      network,
      _image,
      'sleep',
      '600',
    ]);
    expect(
      await planAnswer(engine, RemoveNetwork(dockerServer, networkId: id)),
      isA<ActionRefused>().having(
        (r) => r.reason,
        'reason',
        ActionRefusalReason.networkInUse,
      ),
    );
    await dind(['rm', '--force', user]);

    final removal = await plan(
      engine,
      RemoveNetwork(dockerServer, networkId: id),
    );
    expect(removal.preview.requiredTier, ConfirmationTier.acknowledge);
    expectSucceeded(await run(engine, removal));
    await untilList(
      engine,
      DockerWatchList.networks,
      (payload) => payload is DockerNetworksPayload && !listed(payload),
    );
    expect(
      await dind(['network', 'ls', '--quiet', '--filter', 'id=$id']),
      isEmpty,
    );
  });

  test('a prune previews what it removes and what it keeps, and removes '
      'what it previewed (DKE-05, IMG-06)', () async {
    const volume = 'prune-volume';
    const user = 'prune-user';
    const tag = 'klab-prune/scratch:1';
    addTearDown(() async {
      for (final arguments in [
        ['rm', '--force', user],
        ['volume', 'rm', volume],
        ['rmi', tag],
      ]) {
        try {
          await dind(arguments);
        } on Object {
          // Removed by the test.
        }
      }
    });
    final engine = await start('prune-actions');

    // A volume prune lists the unused volume, keeps a mounted one and is
    // only previewed: other suites' volumes share the engine.
    await dind(['volume', 'create', volume]);
    final volumes = await plan(
      engine,
      const PruneDocker(dockerServer, kind: DockerPruneKind.volumes),
    );
    expect(volumes.preview.requiredTier, ConfirmationTier.typedPhrase);
    expect(volumes.preview.targetName, 'volumes');
    expect([
      for (final item in volumes.preview.prune!.removes) item.name,
    ], contains(volume));

    // Committing the same tag twice leaves the first image dangling.
    await dind(['create', '--name', user, _image, 'true']);
    await dind(['commit', user, tag]);
    final dangling = (await dind([
      'image',
      'inspect',
      '--format',
      '{{.Id}}',
      tag,
    ])).trim();
    await dind(['commit', '--change', 'LABEL second=1', user, tag]);
    final short = dangling.substring('sha256:'.length, 'sha256:'.length + 12);

    final images = await plan(
      engine,
      const PruneDocker(dockerServer, kind: DockerPruneKind.images),
    );
    expect([
      for (final item in images.preview.prune!.removes) item.name,
    ], contains(short));
    expectSucceeded(await run(engine, images));
    expect(
      await dind([
        'image',
        'ls',
        '--quiet',
        '--no-trunc',
        '--filter',
        'dangling=true',
      ]),
      isNot(contains(dangling)),
    );
    // A tagged image stays: only `-a` removes it.
    expect(await dind(['image', 'ls', '--quiet', tag]), isNotEmpty);
  });

  test('a pull streams its layers from the fixture registry, the host\'s '
      'docker pull pulls too, and a tag it lacks fails with what the daemon '
      'said (IMG-03, REG-01)', () async {
    const tag = 'registry:5000/klab/app:pulled';
    addTearDown(() async {
      try {
        await dind(['rmi', tag]);
      } on Object {
        // Never pulled.
      }
    });
    final engine = await start('pull-actions');

    // The tag the registry serves, under a name the engine does not hold,
    // so the daemon downloads rather than finds it.
    await dind(['tag', _appImage, tag]);
    await dind(['push', tag]);
    await dind(['rmi', tag]);
    final pulled = await plan(
      engine,
      const PullImage(dockerServer, reference: tag),
    );
    expect(pulled.preview.requiredTier, ConfirmationTier.acknowledge);
    expectSucceeded(await run(engine, pulled));
    final reports = [
      for (final event in engine.seen)
        if (event is ImagePullProgress && event.planId == pulled.planId) event,
    ];
    expect(reports, isNotEmpty);
    expect(reports.last.status, contains('Status:'));
    expect(await dind(['image', 'ls', '--quiet', tag]), isNotEmpty);

    // The host's own docker pull (REG-01), over the link, prints its
    // progress.
    await dind(['rmi', tag]);
    final host = await plan(
      engine,
      const PullImage(dockerServer, reference: tag, via: PullRoute.host),
    );
    // A shell step that succeeds reports its exit code, unlike an API one.
    expect(
      await run(engine, host),
      isA<ActionFinished>()
          .having((f) => f.outcome, 'outcome', ActionOutcome.succeeded)
          .having((f) => f.exitCode, 'exitCode', 0)
          .having((f) => f.output?.stdout, 'stdout', contains(tag)),
    );
    expect(await dind(['image', 'ls', '--quiet', tag]), isNotEmpty);

    final missing = await plan(
      engine,
      const PullImage(dockerServer, reference: 'registry:5000/klab/app:none'),
    );
    expect(
      await run(engine, missing),
      isA<ActionFinished>()
          .having((f) => f.failure, 'failure', ActionFailure.stepFailed)
          .having((f) => f.output?.stderr, 'detail', isNotEmpty),
    );
  });

  test('a stack stops, starts and restarts its containers (STK-03)', () async {
    final engine = await start('stack-actions');
    watch(engine, {DockerWatchList.containers});
    final app = await containerId('orphans-app-1');

    for (final (verb, state) in const [
      (StackVerb.stop, 'exited'),
      (StackVerb.start, 'running'),
      (StackVerb.restart, 'running'),
    ]) {
      final planned = await plan(
        engine,
        StackAction(dockerServer, project: 'orphans', verb: verb),
      );
      expect(planned.preview.targetName, 'orphans');
      expect(planned.preview.ownership, isNull);
      expect(
        planned.preview.steps,
        everyElement(
          isA<ApiStep>().having(
            (s) => s.path,
            'path',
            endsWith('/${verb.name}'),
          ),
        ),
      );
      expectSucceeded(await run(engine, planned));
      await untilContainer(engine, app, (c) => c?.state == state);
    }
  });

  test('a managed stack and a protected container need the typed name, '
      'and an unverified or managed stack is not redeployed', () async {
    final engine = await start('action-refusals');

    final managed = await plan(
      engine,
      const StackAction(
        dockerServer,
        project: 'managed',
        verb: StackVerb.restart,
      ),
    );
    expect(managed.preview.ownership, isNotNull);
    expect(managed.preview.requiredTier, ConfirmationTier.typedPhrase);

    final protected = await plan(
      engine,
      ContainerAction(
        dockerServer,
        containerId: await containerId('ssh-port'),
        verb: ContainerVerb.stop,
      ),
    );
    expect(protected.preview.protected, ProtectedReason.publishesSessionPort);
    expect(protected.preview.requiredTier, ConfirmationTier.typedPhrase);

    for (final planned in [managed, protected]) {
      expect(
        await run(
          engine,
          planned,
          confirmation: const ActionConfirmation(
            tier: ConfirmationTier.acknowledge,
          ),
        ),
        isA<ActionRefused>().having(
          (r) => r.reason,
          'reason',
          ActionRefusalReason.confirmationMismatch,
        ),
      );
    }
    expect(
      (await dind([
        'inspect',
        '--format',
        '{{.State.Status}}',
        'ssh-port',
      ])).trim(),
      'running',
    );

    for (final (project, reason) in const [
      ('gone', ActionRefusalReason.stackUnverified),
      ('managed', ActionRefusalReason.stackManaged),
    ]) {
      expect(
        await planAnswer(engine, RedeployStack(dockerServer, project: project)),
        isA<ActionRefused>().having((r) => r.reason, 'reason', reason),
        reason: project,
      );
    }
  });

  test('the user\'s own process is stopped, continued and killed, and only '
      'while its start time holds (PRC-02)', () async {
    final link = await connectDockerHost(
      fixture,
      FixtureService.dockerHost,
      fixture.user,
    );
    final pid = int.parse(
      (await _shell(
        link,
        'nohup sleep 300 </dev/null >/dev/null 2>&1 & echo \$!',
      )).trim(),
    );
    addTearDown(() => _shell(link, 'kill -KILL $pid 2>/dev/null || true'));
    final ticks = int.parse(
      (await _shell(
        link,
        HostCommands.commandLine(
          HostCommands.startTicks(pid),
          quote: quoteShellWord,
        ),
      )).trim(),
    );
    Future<String> state() async =>
        (await _shell(link, "cut -d ' ' -f 3 /proc/$pid/stat")).trim();
    final engine = await start('process-actions');

    // Another start time is another process: nothing is planned.
    expect(
      await planAnswer(
        engine,
        KillProcess(dockerServer, pid: pid, startTicks: ticks + 1),
      ),
      isA<ActionRefused>().having(
        (r) => r.reason,
        'reason',
        ActionRefusalReason.targetChanged,
      ),
    );

    final stop = await plan(
      engine,
      KillProcess(
        dockerServer,
        pid: pid,
        startTicks: ticks,
        signal: KillSignal.sigstop,
      ),
    );
    expect(stop.preview.targetName, 'sleep');
    expect(stop.preview.requiredLevel, RequiredLevel.login);
    expect((stop.preview.steps.single as ShellStep).elevated, isFalse);
    expectSucceeded(await run(engine, stop));
    expect(await state(), 'T');

    await planAndRun(
      engine,
      KillProcess(
        dockerServer,
        pid: pid,
        startTicks: ticks,
        signal: KillSignal.sigcont,
      ),
    );
    expect(await state(), 'S');

    // A plan whose process ended before it ran fails its check.
    final kill = await plan(
      engine,
      KillProcess(dockerServer, pid: pid, startTicks: ticks),
    );
    await _shell(link, 'kill -KILL $pid; while [ -e /proc/$pid ]; do :; done');
    expect(
      await run(engine, kill),
      isA<ActionFinished>()
          .having((f) => f.outcome, 'outcome', ActionOutcome.failed)
          .having((f) => f.failure, 'failure', ActionFailure.revalidation)
          .having(
            (f) => f.revalidation,
            'revalidation',
            RevalidationFailure.processGone,
          ),
    );
  });

  test('a redeploy pulls the new digest and recreates the stack as a '
      'detached operation under setsid that outlives the session, '
      're-attaches, logs, is cleaned up and audited (STK-06, '
      'SAF-23)', () async {
    // A new digest of the app image in the registry, with dind's own
    // tag back on the old one, so only the redeploy's pull fetches it.
    final oldImage = (await dind([
      'image',
      'inspect',
      '--format',
      '{{.Id}}',
      _appImage,
    ])).trim();
    await dind([
      'commit',
      '--change',
      'LABEL klabautermann.fixture.revision=2',
      'redeploy-app-1',
      _appImage,
    ]);
    await dind(['push', '--quiet', _appImage]);
    await dind(['image', 'tag', oldImage, _appImage]);
    final before = await containerId('redeploy-app-1');

    final engine = await start('redeploy');
    final planned = await plan(
      engine,
      const RedeployStack(dockerServer, project: 'redeploy'),
    );
    final preview = planned.preview;
    expect(preview.detached, isTrue);
    expect(preview.runner.identity, fixture.user);
    expect(preview.hostWrites, contains(HostWriteRow.userOperationRecords));
    expect(preview.hostWrites, isNot(contains(HostWriteRow.transientUnit)));
    expect(preview.steps, hasLength(3));
    expect(
      preview.steps,
      everyElement(
        isA<ShellStep>().having(
          (s) => s.argv.join(' '),
          'argv',
          contains('--host $_host'),
        ),
      ),
    );

    final started = await run(engine, planned) as ActionFinished;
    expectSucceeded(started);
    final id = started.operationId!;

    // Its output, followed as any log file is, once the engine's read of
    // the operation directory lists it.
    await engine.until<OperationsChanged>(
      (e) => e.serverId == dockerServer && e.operations.any((o) => o.id == id),
    );
    const streamId = 'redeploy-output';
    engine.send(
      OpenLogStream(
        streamId: streamId,
        spec: LogStreamSpec(
          serverId: dockerServer,
          source: OperationLogSource(id),
          window: 100,
          follow: true,
        ),
      ),
    );

    // The session's sshd processes die, as on a dropped network path: the
    // operation goes on, and the engine finds it again over a new link.
    await fixture.exec(FixtureService.dockerHost, [
      'pkill',
      '-KILL',
      '-f',
      // `sshd:` before OpenSSH 9.8 split off `sshd-session:`.
      'sshd.*: ${fixture.user}',
    ]);
    await engine.until<LinkState>(
      (e) => e.serverId == dockerServer && e.status is! LinkReady,
      _redialWait,
    );
    await engine.until<LinkState>(
      (e) => e.serverId == dockerServer && e.status is LinkReady,
      _redialWait,
    );
    final done = await engine.until<OperationsChanged>(
      (e) =>
          e.serverId == dockerServer &&
          e.operations.any(
            (o) => o.id == id && o.state != DetachedOperationState.running,
          ),
      _redeployWait,
    );
    final operation = done.operations.singleWhere((o) => o.id == id);
    expect(operation.state, DetachedOperationState.done);
    expect(operation.exitCode, 0);
    expect(operation.unit, isNull, reason: 'setsid, not systemd-run');
    expect(operation.directory, OpDirectoryKind.user);

    final after = await containerId('redeploy-app-1');
    expect(after, isNot(before), reason: 'the new digest recreates it');
    expect(
      (await dind([
        'inspect',
        '--format',
        '{{index .Config.Labels "klabautermann.fixture.revision"}}',
        'redeploy-app-1',
      ])).trim(),
      '2',
    );
    expect(
      engine.seen.whereType<LogBatch>().where(
        (b) => b.streamId == streamId && b.records.isNotEmpty,
      ),
      isNotEmpty,
      reason: 'the operation wrote output',
    );

    // Acknowledged, the result is audited and its files go.
    engine.send(AcknowledgeOperation(dockerServer, id));
    await engine.until<OperationsChanged>(
      (e) => e.serverId == dockerServer && !e.operations.any((o) => o.id == id),
    );
    final link = await connectDockerHost(
      fixture,
      FixtureService.dockerHost,
      fixture.user,
    );
    expect(
      await _shell(link, 'ls $_opsDir 2>/dev/null | grep -c "^$id\\." || true'),
      '0\n',
    );
    engine.send(const AuditQuery(dockerServer));
    final audit = await engine.until<AuditRecords>(
      (e) => e.serverId == dockerServer,
    );
    final record = audit.records.firstWhere((r) => r.action == 'RedeployStack');
    expect(record.targetName, 'redeploy');
    expect(record.outcome, ActionOutcome.succeeded);
    expect(record.steps, hasLength(3));
    expect(record.steps, everyElement(contains(_quotedHost)));
  });
}

/// [commandLine]'s stdout over [link]; a non-zero exit fails the test.
Future<String> _shell(SshLink link, String commandLine) async {
  final result = await link.run(commandLine, stdin: const []);
  if (result.exitCode != 0) {
    fail('`$commandLine` exited ${result.exitCode}: ${result.stderr}');
  }
  return result.stdout;
}
