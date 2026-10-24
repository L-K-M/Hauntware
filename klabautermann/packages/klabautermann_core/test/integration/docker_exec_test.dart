// Container shells and one-off commands end to end on the Docker fixture
// (03 §7.12 CTX-07, CTX-08; M5 plan M13): the real engine in its own
// isolate, links on, as the fixture user in the Docker host's `docker`
// group. A TTY shell whose `stty size` follows a resize and whose
// `exit 3` comes back as its exit code; a non-TTY one-off whose stdout
// and stderr come back apart; a shell over rank 2, the docker CLI relay,
// on a variant that refuses streamlocal; and a shell on the variant with
// `MaxSessions 2`, where streamlocal costs no session. Each test writes
// what it saw to $KLABAUTERMANN_EVIDENCE_DIR/fixture/exec/. run.sh
// starts and seeds the fixture; without it these skip.
@Tags(['integration', 'docker'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/exec_sessions.dart'
    show kDefaultShellCommand;
import 'package:test/test.dart';

import 'support/actions.dart';
import 'support/fixture.dart';

/// The image seed_docker.sh tags, which every container here runs.
const _image = 'klabautermann-fixture/busybox:1.37';

/// dind's own socket, for the tests' side channel into the engine.
const _dindSocket = 'unix:///run/docker-fixture/docker.sock';

/// Covers a shell's start: the endpoint's resolution, the exec's create
/// and start, and the TTY's first prompt.
const _shellWait = Duration(seconds: 45);

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('the Docker exec suite', () {}, skip: fixtureSkipReason);
    return;
  }

  var terminals = 0;

  /// Runs `docker` in dind as root, out of the engine's sight.
  Future<String> dind(List<String> arguments) => fixture.exec(
    FixtureService.dind,
    ['docker', '--host', _dindSocket, ...arguments],
  );

  /// Starts a container named [name] that sleeps until removed, and
  /// returns its id.
  Future<String> sleeper(String name) async {
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
    return (await dind(['inspect', '--format', '{{.Id}}', name])).trim();
  }

  /// An engine connected to the Docker host, or to [variant] of it, with
  /// management on and the capability probe answered, so the ladder can
  /// read the profile.
  Future<(FixtureEngine, String)> start(
    String name, {
    FixtureService? variant,
  }) async {
    final FixtureEngine engine;
    final String serverId;
    if (variant == null) {
      engine = await FixtureEngine.startDocker(fixture, name);
      serverId = dockerServer;
      await engine.connect(serverId, await fixture.dockerHostKeys());
    } else {
      final (started, hostKeys) = await FixtureEngine.startDockerVariant(
        fixture,
        name,
        variant,
        user: fixture.user,
      );
      engine = started;
      serverId = variantServer;
      await engine.connect(serverId, hostKeys);
    }
    manage(engine, [serverId]);
    await engine.subscribe(serverId, {SampleStream.core});
    await engine.until<HostProfileChanged>(
      (e) => e.serverId == serverId && e.cachedAt == null,
    );
    return (engine, serverId);
  }

  /// The endpoint state [serverId]'s ladder settled in.
  Future<DockerEndpointState> resolved(
    FixtureEngine engine,
    String serverId,
  ) async {
    final queryId = 'engine-${terminals++}';
    engine.send(
      DockerQuery(
        serverId: serverId,
        queryId: queryId,
        query: const DockerEngineQuery(),
      ),
    );
    await engine.until<DockerResult>((r) => r.queryId == queryId);
    return engine.seen.whereType<DockerEndpointState>().lastWhere(
      (e) => e.serverId == serverId && e.phase != DockerEndpointPhase.resolving,
    );
  }

  /// Opens a shell in [containerId] at [columns] by [rows], and waits
  /// until it runs.
  Future<(_Shell, TerminalOpened)> open(
    FixtureEngine engine,
    String serverId,
    String containerId, {
    int columns = 80,
    int rows = 24,
  }) async {
    final id = 'shell-${terminals++}';
    final shell = _Shell(engine, id);
    engine.send(
      OpenTerminal(
        terminalId: id,
        serverId: serverId,
        containerId: containerId,
        columns: columns,
        rows: rows,
      ),
    );
    final opened = await engine.until<EngineEvent>(
      (event) => switch (event) {
        TerminalOpened(:final terminalId) ||
        TerminalClosed(:final terminalId) => terminalId == id,
        _ => false,
      },
      _shellWait,
    );
    if (opened case TerminalClosed(:final reason, :final detail)) {
      fail('the shell did not open: ${reason.name} ($detail)');
    }
    return (shell, opened as TerminalOpened);
  }

  Future<void> record(String name, Map<String, Object?> details) async {
    final evidence = const JsonEncoder.withIndent('  ').convert(details);
    print(evidence);
    await fixture.writeEvidence('exec/$name.json', '$evidence\n');
  }

  test('a TTY shell follows a resize, and exit 3 comes back as 3 '
      '(CTX-07)', () async {
    final container = await sleeper('exec-tty');
    final (engine, serverId) = await start('exec tty');
    final (shell, opened) = await open(
      engine,
      serverId,
      container,
      columns: 101,
      rows: 31,
    );
    // The default shell: bash where the image has it, else sh (03 §7.12).
    expect(opened.command, kDefaultShellCommand);

    // `stty size` prints rows, then columns.
    shell.type('stty size\n');
    final before = await shell.expectOutput(RegExp(r'(\d+) (\d+)\r?\n'));
    expect((before[1], before[2]), ('31', '101'));

    // The resize goes over its own API call while input goes down the
    // stream, so the shell may read the old size first: ask again until
    // the new one shows, a few times at most.
    engine.send(TerminalResize(shell.id, columns: 132, rows: 43));
    late RegExpMatch after;
    for (var attempt = 0; attempt < 10; attempt++) {
      final mark = shell.output.length;
      shell.type('stty size\n');
      after = await shell.expectOutput(RegExp(r'(\d+) (\d+)\r?\n'), from: mark);
      if ((after[1], after[2]) == ('43', '132')) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    expect((after[1], after[2]), ('43', '132'));

    shell.type('exit 3\n');
    final closed = await shell.closed();
    expect((closed.reason, closed.exitCode), (TerminalCloseReason.exited, 3));

    await record('tty-shell', {
      'command': opened.command,
      'sizeBefore': '${before[1]} ${before[2]}',
      'sizeAfter': '${after[1]} ${after[2]}',
      'closeReason': closed.reason.name,
      'exitCode': closed.exitCode,
    });
  });

  test('a one-off command returns stdout and stderr apart, with its exit '
      'code (CTX-08)', () async {
    final container = await sleeper('exec-oneoff');
    final (engine, serverId) = await start('exec one-off');

    final planned = await plan(
      engine,
      ContainerExec(
        serverId,
        containerId: container,
        argv: ['sh', '-c', 'echo to-out; echo to-err >&2; exit 5'],
      ),
    );
    expect(planned.preview.requiredTier, ConfirmationTier.acknowledge);
    final finished = await run(engine, planned);
    if (finished is! ActionFinished) {
      fail('the one-off did not finish: $finished');
    }

    // A command that ran reports its exit code whether it failed or not.
    expect(finished.exitCode, 5);
    expect(finished.output?.stdout, 'to-out\n');
    expect(finished.output?.stderr, 'to-err\n');
    expect(finished.output?.truncated, isFalse);

    await record('one-off', {
      'outcome': finished.outcome.name,
      'exitCode': finished.exitCode,
      'stdout': finished.output?.stdout,
      'stderr': finished.output?.stderr,
    });
  });

  test('a shell runs over rank 2, the docker CLI relay, where streamlocal '
      'is refused (neg-nostreamlocal)', () async {
    final container = await sleeper('exec-relay');
    final (engine, serverId) = await start(
      'exec relay',
      variant: FixtureService.noStreamlocal,
    );
    final endpoint = await resolved(engine, serverId);
    expect(endpoint.phase, DockerEndpointPhase.ready);
    expect(endpoint.route?.rank, DockerRank.cliRelay);

    final (shell, _) = await open(engine, serverId, container);
    shell.type('echo relay-\$((40 + 2))\n');
    await shell.expectOutput(RegExp(r'relay-42'));
    shell.type('exit\n');
    final closed = await shell.closed();
    expect((closed.reason, closed.exitCode), (TerminalCloseReason.exited, 0));

    await record('relay-shell', {
      'service': FixtureService.noStreamlocal.composeName,
      'rank': endpoint.route?.rank.name,
      'label': endpoint.label.name,
      'closeReason': closed.reason.name,
    });
  });

  test('a shell opens beside the samplers under MaxSessions 2 '
      '(neg-maxsessions2): streamlocal costs no session', () async {
    final container = await sleeper('exec-maxsessions');
    final (engine, serverId) = await start(
      'exec maxsessions2',
      variant: FixtureService.maxSessions2,
    );
    final endpoint = await resolved(engine, serverId);
    expect(endpoint.route?.rank, DockerRank.streamlocal);

    final clock = Stopwatch()..start();
    final (shell, _) = await open(engine, serverId, container);
    final openedMs = clock.elapsedMilliseconds;
    shell.type('echo beside-the-samplers\n');
    await shell.expectOutput(RegExp(r'beside-the-samplers\r?\n'));
    engine.send(CloseTerminal(shell.id));
    final closed = await shell.closed();
    expect(closed.reason, TerminalCloseReason.closed);

    await record('maxsessions2-shell', {
      'service': FixtureService.maxSessions2.composeName,
      'rank': endpoint.route?.rank.name,
      'lowSession': engine.seen
          .whereType<DockerEndpointState>()
          .where((e) => e.serverId == serverId)
          .last
          .lowSession,
      'openedMs': openedMs,
      'closeReason': closed.reason.name,
    });
  });
}

/// One open shell: what it printed so far, and how to type into it.
final class _Shell {
  _Shell(this.engine, this.id);

  final FixtureEngine engine;
  final String id;
  final _output = BytesBuilder();

  String get output => utf8.decode(_output.toBytes(), allowMalformed: true);

  void type(String text) =>
      engine.send(TerminalInput(id, Uint8List.fromList(utf8.encode(text))));

  /// Reads output until [pattern] matches what the shell printed since
  /// [from], and returns the match.
  Future<RegExpMatch> expectOutput(RegExp pattern, {int from = 0}) async {
    RegExpMatch? match() => pattern.firstMatch(output.substring(from));
    if (match() case final found?) return found;
    await engine.until<EngineEvent>((event) {
      if (event case TerminalBytes(
        :final terminalId,
        :final bytes,
      ) when terminalId == id) {
        _output.add(bytes);
      }
      if (event case TerminalClosed(:final terminalId) when terminalId == id) {
        fail('the shell closed before printing $pattern: $output');
      }
      return match() != null;
    }, _shellWait);
    return match()!;
  }

  /// Reads events until the shell closes, and returns how.
  Future<TerminalClosed> closed() => engine.until<TerminalClosed>(
    (event) => event.terminalId == id,
    _shellWait,
  );
}
