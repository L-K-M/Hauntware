// The scripted MVP session the host write inventory brackets (M4 E31,
// X6; 03 §8.11, plan M18): run.sh snapshots the Docker host as root
// before and after this test alone, and inventory.dart checks the diff
// against inventory_allowlist.txt. The session samples every stream,
// watches the Docker lists and reads a container's log, runs every MVP
// container, image and stack action and a process signal as the fixture
// user, and a detached redeploy that outlives a dropped link, re-attaches
// and is acknowledged. Its own checks stay light: the action suites
// (E28, E29) test the outcomes, and this one exercises the writes. It
// runs only from run.sh's inventory leg; without the fixture it skips.
@Tags(['inventory'])
@Timeout(Duration(minutes: 6))
library;

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart' show HostCommands;
import 'package:seance_core/seance_core.dart' show SshLink;
import 'package:test/test.dart';

import 'support/actions.dart';
import 'support/docker_host.dart';
import 'support/fixture.dart';

/// The image seed_docker.sh tags, which the scratch container runs.
const _image = 'klabautermann-fixture/busybox:1.37';

/// An image of its own that no container uses, committed from the
/// scratch container, which the session removes.
const _scratchImage = 'klabautermann-fixture/inventory:1';

/// The container the session creates and acts on.
const _scratchContainer = 'inventory-scratch';

/// dind's own socket, for the session's side channel into the engine.
const _dindSocket = 'unix:///run/docker-fixture/docker.sock';

/// Covers the redeploy's pull and up, and the redial after the session's
/// sshd processes are killed.
const _redeployWait = Duration(seconds: 120);
const _redialWait = Duration(seconds: 90);

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the inventory session', () {}, skip: fixtureSkipReason);
    return;
  }

  /// Runs `docker` in dind as root, out of the engine's sight: the
  /// session's setup, whose engine changes inventory.sh does not see.
  Future<String> dind(List<String> arguments) => fixture.exec(
    FixtureService.dind,
    ['docker', '--host', _dindSocket, ...arguments],
  );

  test('a session of every MVP read and action, a detached redeploy '
      'among them, writes only what 03 §8.11 allows', () async {
    final hostKeys = await fixture.dockerHostKeys();
    final scratch = (await dind([
      'run',
      '--detach',
      '--name',
      _scratchContainer,
      _image,
      'sleep',
      '600',
    ])).trim();
    await dind(['commit', _scratchContainer, _scratchImage]);
    // What a session that failed part-way left; the session removes both.
    addTearDown(
      () => fixture.exec(FixtureService.dind, [
        'sh',
        '-c',
        'docker --host $_dindSocket rm --force $_scratchContainer; '
            'docker --host $_dindSocket image rm --force $_scratchImage; '
            'true',
      ]),
    );

    final engine = await FixtureEngine.startDocker(fixture, 'inventory');
    manage(engine, [dockerServer]);
    await engine.connect(dockerServer, hostKeys);

    // Sampling: every stream, and the probe's profile.
    await engine.subscribe(dockerServer, SampleStream.values.toSet());
    await engine.until<HostProfileChanged>(
      (e) => e.serverId == dockerServer && e.cachedAt == null,
    );

    // The Docker lists and a container's log.
    engine.send(
      const DockerWatch(
        serverId: dockerServer,
        watchId: 'inventory',
        lists: {
          DockerWatchList.containers,
          DockerWatchList.images,
          DockerWatchList.stacks,
        },
      ),
    );
    await engine.until<DockerListChanged>(
      (e) => e.serverId == dockerServer && e.list == DockerWatchList.containers,
    );
    engine.send(
      OpenLogStream(
        streamId: 'inventory-log',
        spec: LogStreamSpec(
          serverId: dockerServer,
          source: ContainerLogSource(scratch),
          window: 20,
          follow: false,
        ),
      ),
    );
    await engine.until<LogStreamState>(
      (e) => e.streamId == 'inventory-log' && e.status is LogStreamEnded,
    );

    // Every container action, the scratch container removed last with
    // its volumes.
    for (final verb in [
      ContainerVerb.restart,
      ContainerVerb.pause,
      ContainerVerb.unpause,
      ContainerVerb.stop,
      ContainerVerb.start,
      ContainerVerb.kill,
    ]) {
      await planAndRun(
        engine,
        ContainerAction(dockerServer, containerId: scratch, verb: verb),
      );
    }
    await planAndRun(
      engine,
      RemoveContainer(dockerServer, containerId: scratch, volumes: true),
    );
    await planAndRun(
      engine,
      const RemoveImage(dockerServer, image: _scratchImage),
    );
    await planAndRun(
      engine,
      const StackAction(
        dockerServer,
        project: 'orphans',
        verb: StackVerb.restart,
      ),
    );

    // A signal to the user's own process.
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
    final ticks = int.parse(
      (await _shell(
        link,
        HostCommands.commandLine(
          HostCommands.startTicks(pid),
          quote: quoteShellWord,
        ),
      )).trim(),
    );
    await planAndRun(
      engine,
      KillProcess(dockerServer, pid: pid, startTicks: ticks),
    );

    // The detached redeploy: it outlives the session's sshd processes,
    // the engine finds it again over a new link, and acknowledging its
    // result deletes its files.
    final started = await planAndRun(
      engine,
      const RedeployStack(dockerServer, project: 'redeploy'),
    );
    final id = started.operationId!;
    await engine.until<OperationsChanged>(
      (e) => e.serverId == dockerServer && e.operations.any((o) => o.id == id),
    );
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
    expect(
      done.operations.singleWhere((o) => o.id == id).state,
      DetachedOperationState.done,
    );
    engine.send(AcknowledgeOperation(dockerServer, id));
    await engine.until<OperationsChanged>(
      (e) => e.serverId == dockerServer && !e.operations.any((o) => o.id == id),
    );

    engine.send(const Disconnect(dockerServer));
    await engine.until<LinkState>(
      (e) => e.serverId == dockerServer && e.status is LinkClosed,
    );
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
