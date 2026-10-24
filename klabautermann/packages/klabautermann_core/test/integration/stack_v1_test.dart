// The v1 stack actions and reads end to end on the Docker fixture (M5
// plan M29; 03 §7.16 STK-07 to STK-09, STK-23): the real engine in its
// own isolate, links on, as the fixture user. Per-service stop and
// restart through the API; a service recreated as a detached compose
// operation under BusyBox `setsid`, with `--host` and every recorded file
// in each step; a stack deployed from two files naming both; the profile
// behind a service; a folder scan finding a stack that never ran; and
// `down`, which needs the typed name and never removes volumes. run.sh
// starts and seeds the fixture (seed_docker.sh); without it these skip.
@Tags(['integration', 'docker'])
@Timeout(Duration(minutes: 4))
library;

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:test/test.dart';

import 'support/actions.dart';
import 'support/docker_host.dart';
import 'support/fixture.dart';

/// dind's own socket, for the tests' side channel into the engine.
const _dindSocket = 'unix:///run/docker-fixture/docker.sock';

/// The engine's first candidate path (03 §5.4), as every step's `--host`
/// names it.
const _host = 'unix://$dockerSocket';

/// Where seed_docker.sh writes the fixture user's stacks.
const _stacks = '/home/klab/stacks';

/// Covers a compose operation's run and the operation list's next read.
const _operationWait = Duration(seconds: 90);

/// Covers a container event reaching the watched list (DKE-02's 2 s) on
/// a busy runner.
const _listWait = Duration(seconds: 15);

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the v1 stack suite', () {}, skip: fixtureSkipReason);
    return;
  }

  late Map<Endpoint, Set<String>> hostKeys;
  setUpAll(() async => hostKeys = await fixture.dockerHostKeys());

  var watches = 0;
  var queries = 0;

  /// Runs `docker` in dind as root, out of the engine's sight.
  Future<String> dind(List<String> arguments) => fixture.exec(
    FixtureService.dind,
    ['docker', '--host', _dindSocket, ...arguments],
  );

  Future<String> containerId(String name) async =>
      (await dind(['inspect', '--format', '{{.Id}}', name])).trim();

  Future<String> containerState(String name) async =>
      (await dind(['inspect', '--format', '{{.State.Status}}', name])).trim();

  /// An engine connected to the Docker host as the fixture user, with
  /// management on and the capability probe answered.
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

  /// Sends [spec] to the Docker host and returns its answer.
  Future<DockerPayload> query(
    FixtureEngine engine,
    DockerQuerySpec spec,
  ) async {
    final queryId = 'stack-query-${queries++}';
    engine.send(
      DockerQuery(serverId: dockerServer, queryId: queryId, query: spec),
    );
    final result = await engine.until<DockerResult>(
      (r) => r.serverId == dockerServer && r.queryId == queryId,
    );
    return result.payload;
  }

  /// The stack list once it holds a verdict for [project].
  Future<DockerStacksPayload> stacks(
    FixtureEngine engine,
    String project,
  ) async {
    engine.send(
      DockerWatch(
        serverId: dockerServer,
        watchId: 'stacks-${watches++}',
        lists: const {DockerWatchList.stacks},
      ),
    );
    final event = await engine.until<DockerListChanged>(
      (e) =>
          e.serverId == dockerServer &&
          e.list == DockerWatchList.stacks &&
          e.payload is DockerStacksPayload &&
          (e.payload as DockerStacksPayload).verdicts[project] is StackVerified,
      _listWait,
    );
    return event.payload as DockerStacksPayload;
  }

  /// Runs [planned], a detached compose operation, and returns it once it
  /// ended.
  Future<DetachedOperation> runDetached(
    FixtureEngine engine,
    ActionPlanned planned,
  ) async {
    final started = await run(engine, planned) as ActionFinished;
    expectSucceeded(started);
    final id = started.operationId!;
    final done = await engine.until<OperationsChanged>(
      (e) =>
          e.serverId == dockerServer &&
          e.operations.any(
            (o) => o.id == id && o.state != DetachedOperationState.running,
          ),
      _operationWait,
    );
    final operation = done.operations.singleWhere((o) => o.id == id);
    engine.send(AcknowledgeOperation(dockerServer, id));
    return operation;
  }

  /// Every step of [preview] is a compose command naming the engine's
  /// socket and each of [files].
  void expectComposeSteps(ActionPreview preview, List<String> files) {
    expect(preview.detached, isTrue);
    expect(
      preview.steps,
      everyElement(
        isA<ShellStep>().having(
          (s) => s.argv.join(' '),
          'argv',
          allOf([
            contains('--host $_host'),
            for (final file in files) contains('-f $file'),
          ]),
        ),
      ),
    );
  }

  test('a service stops and restarts alone, through the API '
      '(STK-23)', () async {
    final engine = await start('stack-service');
    final worker = await containerId('services-worker-1');

    for (final (verb, state) in const [
      (StackVerb.stop, 'exited'),
      (StackVerb.restart, 'running'),
    ]) {
      final planned = await plan(
        engine,
        StackAction(
          dockerServer,
          project: 'services',
          verb: verb,
          service: 'worker',
        ),
      );
      expect(
        planned.preview.steps,
        everyElement(
          isA<ApiStep>().having((s) => s.path, 'path', contains(worker)),
        ),
      );
      expectSucceeded(await run(engine, planned));
      expect(await containerState('services-worker-1'), state);
      expect(await containerState('services-app-1'), 'running');
    }
  });

  test('a service is recreated as a detached compose operation that '
      'leaves the others alone (STK-23)', () async {
    final engine = await start('stack-recreate');
    final worker = await containerId('services-worker-1');
    final app = await containerId('services-app-1');

    final planned = await plan(
      engine,
      const StackComposeAction(
        dockerServer,
        project: 'services',
        verb: StackComposeVerb.recreateService,
        service: 'worker',
      ),
    );
    expect(planned.preview.targetName, 'services/worker');
    expectComposeSteps(planned.preview, ['$_stacks/services/compose.yaml']);

    final operation = await runDetached(engine, planned);
    expect(operation.state, DetachedOperationState.done);
    expect(operation.exitCode, 0);
    expect(operation.unit, isNull, reason: 'setsid, not systemd-run');
    expect(await containerId('services-worker-1'), isNot(worker));
    expect(await containerId('services-app-1'), app);
  });

  test('a stack deployed from two files names both, and every step passes '
      'them on (STK-09)', () async {
    final engine = await start('stack-override');
    final payload = await stacks(engine, 'override');
    final override = payload.grouping.project('override')!;
    const files = [
      '$_stacks/override/compose.yaml',
      '$_stacks/override/compose.override.yaml',
    ];
    expect(override.configFiles, files);

    final planned = await plan(
      engine,
      const StackComposeAction(
        dockerServer,
        project: 'override',
        verb: StackComposeVerb.recreateService,
        service: 'app',
      ),
    );
    expectComposeSteps(planned.preview, files);
  });

  test("a stack's profiles are read from its files, and a folder scan "
      'finds the stack that never ran (STK-08, STK-09)', () async {
    final engine = await start('stack-folders');

    expect(
      await query(engine, const DockerStackProfilesQuery('profiled')),
      isA<DockerStackProfilesPayload>().having((p) => p.profiles, 'profiles', [
        'debug',
      ]),
    );

    final scan = await query(engine, DockerStackScanQuery([_stacks]));
    expect(scan, isA<DockerStackScanPayload>());
    final found = scan as DockerStackScanPayload;
    expect(found.incomplete, isFalse);
    expect(
      found.files,
      containsAll([
        '$_stacks/idle/compose.yaml',
        '$_stacks/override/compose.override.yaml',
        '$_stacks/services/compose.yaml',
      ]),
    );
    expect(
      (await dind([
        'ps',
        '--all',
        '--quiet',
        '--filter',
        'label=com.docker.compose.project=idle',
      ])).trim(),
      isEmpty,
      reason: 'only the scan knows the idle stack',
    );
  });

  test('down needs the typed name and removes the containers but never '
      'the volumes (STK-23)', () async {
    final engine = await start('stack-down');
    final planned = await plan(
      engine,
      const StackComposeAction(
        dockerServer,
        project: 'downable',
        verb: StackComposeVerb.down,
      ),
    );
    final preview = planned.preview;
    expect(preview.requiredTier, ConfirmationTier.typedPhrase);
    expectComposeSteps(preview, ['$_stacks/downable/compose.yaml']);
    final argv = (preview.steps.last as ShellStep).argv;
    expect(argv, contains('down'));
    expect(argv, isNot(anyOf(contains('-v'), contains('--volumes'))));

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
    expect(await containerState('downable-app-1'), 'running');

    final operation = await runDetached(
      engine,
      await plan(
        engine,
        const StackComposeAction(
          dockerServer,
          project: 'downable',
          verb: StackComposeVerb.down,
        ),
      ),
    );
    expect(operation.exitCode, 0);
    expect(
      (await dind([
        'ps',
        '--all',
        '--quiet',
        '--filter',
        'label=com.docker.compose.project=downable',
      ])).trim(),
      isEmpty,
    );
  });
}
