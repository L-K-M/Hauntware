// Spike S4 without systemd (03 §7.17; 06's spike table; M4 plan E02):
// whether a detached operation that the login user launches survives the
// end of the session that launched it, and which `setsid` launches work.
//
// On the Docker host (Alpine, BusyBox), as the fixture user over a real
// SshLink: E08's login `setsid` row (a backgrounded BusyBox `setsid`,
// whose applet has no -f), `nohup ... &`, and a plain `&` as the control,
// each running E08's wrapper. The link closes right after the launch and
// a new one reads the process and the record. BusyBox's refusal of
// `setsid -f` is recorded too.
//
// In a Debian 13 container on the runner's own Docker, as a non-root
// account through `docker exec`: util-linux `setsid -f`, which 7.17's
// table names, and E08's launcher under util-linux. The exec ending
// stands in for the session's end; there is no sshd in the container.
//
// Every case writes what it saw to
// $KLABAUTERMANN_EVIDENCE_DIR/fixture/s4/ before its expectations, so a
// failing case still leaves its evidence (klabautermann/docs/evidence/s4/).
// run.sh starts the fixture; without it these skip.
@Tags(['integration'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';
import 'dart:math';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_host/klabautermann_host.dart'
    show
        DetachedRunner,
        HostCommands,
        OpRecordField,
        OperationCommands,
        generateOpId;
import 'package:seance_core/seance_core.dart' show SshLink;
import 'package:test/test.dart';

import 'support/docker_host.dart';
import 'support/fixture.dart';
import 'support/s4.dart';

/// capture.sh's Debian 13 pin, which fixture_layout_test.dart holds equal.
const _debianImage =
    'mirror.gcr.io/library/debian:13@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5';

/// The Debian container's label, as capture.sh labels its own.
const _containerLabel = 'org.klabautermann.spike=s4';

/// The non-root account the Debian cases run as.
const _debianUser = 'klab';

/// The operation's command: long enough to still run when the new
/// session looks, and with output for the log.
const _operation = ['sh', '-c', 'sleep 8; echo s4-done'];

/// The line the operation logs when it ends.
const _operationOutput = 's4-done\n';

/// Covers a launch, which returns at once when the launcher works.
const _launchTimeout = Duration(seconds: 15);

/// The ways a login user can detach the wrapper without systemd.
enum _Launcher {
  /// E08's login `setsid` row, exactly as `detachedLaunch` builds it.
  setsidBackground,

  /// `nohup "$@" ... &`, 7.17's other BusyBox candidate.
  nohupBackground,

  /// A plain `"$@" ... &`: the control, which neither starts a session
  /// nor ignores SIGHUP.
  plainBackground,

  /// util-linux `setsid -f`, as 7.17's table names it; prints `setsid`'s
  /// own status, since it does not tell the child's PID.
  setsidFork;

  /// The launch argv for an operation recorded in [dir] as [id].
  List<String> argv({
    required String dir,
    required String id,
    required int uid,
  }) {
    if (this == setsidBackground) {
      return OperationCommands.detachedLaunch(
        DetachedRunner.loginSetsid,
        dir: dir,
        id: id,
        uid: uid,
        argv: _operation,
      );
    }
    final script = switch (this) {
      setsidBackground => throw StateError('built above'),
      nohupBackground =>
        'nohup "\$@" </dev/null >/dev/null 2>&1 &\n'
            "printf '%s\\n' \"\$!\"",
      plainBackground =>
        '"\$@" </dev/null >/dev/null 2>&1 &\n'
            "printf '%s\\n' \"\$!\"",
      setsidFork =>
        'setsid -f "\$@" </dev/null >/dev/null 2>&1\n'
            "printf '%s\\n' \"\$?\"",
    };
    return [
      'sh',
      '-c',
      script,
      'klabautermann-launch',
      ...wrapperArgv(dir: dir, id: id, uid: uid, argv: _operation),
    ];
  }
}

/// A host the cases run on: [run] for reads, [launch] for the launch,
/// and [endSession], after which [run] reads from a new session.
typedef _Host = ({
  HostRun run,
  HostRun launch,
  Future<void> Function() endSession,
});

void main() {
  final fixture = Fixture.fromEnvironment();
  if (fixture == null) {
    test('spike S4 without systemd', () {}, skip: fixtureSkipReason);
    return;
  }
  final evidence = S4Evidence(fixture.s4EvidenceDirectory);

  /// Launches the operation with [launcher] on [host], ends the session,
  /// and records what the next session sees. Returns the evidence it
  /// wrote, for the expectations.
  Future<Map<String, Object?>> detach(
    String name,
    _Host host,
    _Launcher launcher,
    Map<String, Object?> facts,
  ) async {
    final dir = (await host.run(userOpsDirLine)).stdout.trim();
    final uid = int.parse((await host.run('id -u')).stdout.trim());
    final id = generateOpId(Random.secure());

    final clock = Stopwatch()..start();
    final launch = await host.launch(
      HostCommands.commandLine(
        launcher.argv(dir: dir, id: id, uid: uid),
        quote: quoteShellWord,
      ),
    );
    final launchMs = clock.elapsedMilliseconds;
    Map<String, Object?>? running;
    await eventually(() async {
      running = parseOpRecord(
        (await host.run(
          'cat -- ${quoteShellWord('$dir/$id.json')} 2>/dev/null || true',
        )).stdout,
      );
      return running != null;
    }, timeout: const Duration(seconds: 10));
    final pid = running?[OpRecordField.pid] as int?;
    final before = pid == null ? null : await procFacts(host.run, pid);

    await host.endSession();
    await Future<void>.delayed(const Duration(seconds: 1));
    final after = pid == null ? null : await procFacts(host.run, pid);
    final done = pid == null ? null : await untilDone(host.run, dir, id);
    final log = await host.run(
      'cat -- ${quoteShellWord('$dir/$id.log')} 2>/dev/null || true',
    );
    await host.run(
      HostCommands.commandLine(
        OperationCommands.opCleanup(dir, [id]),
        quote: quoteShellWord,
      ),
    );

    final data = <String, Object?>{
      ...facts,
      'launcher': launcher.name,
      'launch': resultJson(launch),
      'launchMilliseconds': launchMs,
      'printed': launch.stdout.trim(),
      'runningRecord': running,
      'beforeSessionEnd': procJson(before),
      'afterSessionEnd': procJson(after),
      'survived': after != null,
      'newSession': before != null && before.session == pid,
      'doneRecord': done,
      'log': log.stdout,
    };
    await evidence.write(name, data);
    expect(launch.exitCode, 0, reason: '$data');
    expect(launchMs, lessThan(_launchTimeout.inMilliseconds));
    expect(running, isNotNull, reason: 'no running record: $data');
    return data;
  }

  group('on the Docker host (BusyBox)', () {
    late SshLink link;

    /// Runs a line on whichever link is current, so a read after
    /// endSession goes over the new one.
    Future<({int? exitCode, String stdout, String stderr})> run(
      String line,
    ) async {
      final result = await link.run(
        line,
        stdin: const [],
        timeout: _launchTimeout,
      );
      return (
        exitCode: result.exitCode,
        stdout: result.stdout,
        stderr: result.stderr,
      );
    }

    Future<_Host> host() async {
      link = await connectDockerHost(
        fixture,
        FixtureService.dockerHost,
        fixture.user,
      );
      return (
        run: run,
        launch: run,
        endSession: () async {
          await link.close();
          link = await connectDockerHost(
            fixture,
            FixtureService.dockerHost,
            fixture.user,
          );
        },
      );
    }

    Future<Map<String, Object?>> userland(HostRun run) async => {
      'host': 'docker-sshd',
      'user': fixture.user,
      'busybox': (await run('busybox | head -n 1')).stdout.trim(),
      'setsid': (await run('readlink -f "\$(command -v setsid)"')).stdout
          .trim(),
    };

    test('BusyBox setsid has no -f', () async {
      final h = await host();
      final refused = await h.run('setsid -f true');

      await evidence.write('fixture-busybox-setsid-f', {
        ...await userland(h.run),
        'command': 'setsid -f true',
        'result': resultJson(refused),
      });
      expect(refused.exitCode, isNot(0));
      expect(refused.stderr, contains('unrecognized option'));
    });

    test("E08's backgrounded setsid starts a session and survives the "
        "link's end", () async {
      final h = await host();
      final data = await detach(
        'fixture-setsid-background',
        h,
        _Launcher.setsidBackground,
        await userland(h.run),
      );

      final pid = (data['runningRecord']! as Map)[OpRecordField.pid];
      expect(data['printed'], '$pid', reason: r'$! is the record PID');
      expect(data['newSession'], isTrue, reason: '$data');
      expect(data['survived'], isTrue, reason: '$data');
      expect((data['doneRecord']! as Map)[OpRecordField.exit], 0);
      expect(data['log'], _operationOutput);
    });

    test("nohup ... & survives the link's end", () async {
      final h = await host();
      final data = await detach(
        'fixture-nohup-background',
        h,
        _Launcher.nohupBackground,
        await userland(h.run),
      );

      final pid = (data['runningRecord']! as Map)[OpRecordField.pid];
      expect(data['printed'], '$pid', reason: r'nohup execs: $! is the PID');
      expect(data['survived'], isTrue, reason: '$data');
      expect((data['doneRecord']! as Map)[OpRecordField.exit], 0);
    });

    test('a plain & is recorded as the control', () async {
      final h = await host();
      // Recorded, not asserted: whether it survives says whether setsid
      // matters on a host without logind, which is what the control is
      // for.
      await detach(
        'fixture-plain-background',
        h,
        _Launcher.plainBackground,
        await userland(h.run),
      );
    });
  });

  group('in a Debian container (util-linux)', () {
    late String container;

    Future<ProcessResult> docker(List<String> arguments) async {
      final result = await Process.run('docker', arguments);
      if (result.exitCode != 0) {
        fail(
          'docker ${arguments.join(' ')} exited ${result.exitCode}: '
          '${result.stderr}',
        );
      }
      return result;
    }

    setUpAll(() async {
      final present = await Process.run('docker', [
        'image',
        'inspect',
        _debianImage,
      ]);
      if (present.exitCode != 0) {
        for (var attempt = 1; ; attempt++) {
          final pull = await Process.run('docker', [
            'pull',
            '--quiet',
            _debianImage,
          ]);
          if (pull.exitCode == 0) break;
          if (attempt == 3) fail('cannot pull $_debianImage: ${pull.stderr}');
          await Future<void>.delayed(Duration(seconds: attempt * 10));
        }
      }
      final name = 'klabautermann-s4-${generateOpId(Random.secure())}';
      // No network and nothing published: the cases need neither.
      await docker([
        'run',
        '--detach',
        '--name',
        name,
        '--label',
        _containerLabel,
        '--network',
        'none',
        _debianImage,
        'sleep',
        'infinity',
      ]);
      container = name;
      addTearDown(() => Process.run('docker', ['rm', '--force', name]));
      await docker([
        'exec',
        container,
        'useradd',
        '--create-home',
        '--shell',
        '/bin/sh',
        _debianUser,
      ]);
    });

    _Host host() {
      Future<({int? exitCode, String stdout, String stderr})> run(
        String line,
      ) async {
        final result = await Process.run('docker', [
          'exec',
          '--user',
          _debianUser,
          container,
          'sh',
          '-c',
          line,
        ]).timeout(_launchTimeout);
        return (
          exitCode: result.exitCode,
          stdout: '${result.stdout}',
          stderr: '${result.stderr}',
        );
      }

      // Each read is an exec of its own, so the launch's exec has ended.
      return (run: run, launch: run, endSession: () async {});
    }

    Future<Map<String, Object?>> userland(HostRun run) async => {
      'host': _debianImage,
      'user': _debianUser,
      'setsid': (await run('setsid --version')).stdout.trim(),
    };

    test(
      'util-linux setsid -f starts a session and survives the exec',
      () async {
        final h = host();
        final data = await detach(
          'debian-setsid-fork',
          h,
          _Launcher.setsidFork,
          await userland(h.run),
        );

        expect(data['printed'], '0', reason: "setsid's own status");
        expect(data['newSession'], isTrue, reason: '$data');
        expect((data['doneRecord']! as Map)[OpRecordField.exit], 0);
        expect(data['log'], _operationOutput);
      },
    );

    test("E08's backgrounded setsid under util-linux execs in place", () async {
      final h = host();
      final data = await detach(
        'debian-setsid-background',
        h,
        _Launcher.setsidBackground,
        await userland(h.run),
      );

      final pid = (data['runningRecord']! as Map)[OpRecordField.pid];
      expect(data['printed'], '$pid', reason: r'$! is the record PID');
      expect(data['newSession'], isTrue, reason: '$data');
      expect((data['doneRecord']! as Map)[OpRecordField.exit], 0);
    });
  });
}
