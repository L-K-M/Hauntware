// Elevated reads in admin mode (M4 E16b): a root-only log file read
// through the session's elevation (LOG-22), which ends denied without
// admin mode and when admin mode ends, and a stack file SFTP may not read
// read as root with the same cap and masking (STK-04).
import 'dart:async';
import 'dart:convert';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/admin/admin_mode.dart';
import 'package:klabautermann_core/src/admin/elevated_link.dart';
import 'package:klabautermann_core/src/docker/stack_sources.dart';
import 'package:klabautermann_core/src/logs/log_stream_router.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:seance_core/seance_core.dart'
    show
        ElevatedExecutor,
        ElevationProbe,
        RemoteCommandResult,
        RemoteExit,
        RemoteFileErrorKind,
        RemoteFileException,
        RemoteFileSystem;
import 'package:test/test.dart';

import '../support/fake_clock.dart';
import '../support/forwarding_link.dart';
import '../support/scripted_link.dart';

const _srv = 'srv-1';
const _secure = '/var/log/secure';
const _denied = LogStreamEnded(
  LogStreamEndReason.denied,
  detail: 'admin mode is off',
);

/// Admin mode over [link] with a NOPASSWD rule, so each start is one
/// `sudo -n` exec.
AdminSession _session(ScriptedLink link) => AdminSession.test(
  ElevatedExecutor(
    link,
    const ElevationProbe(
      sudoVersionLine: 'Sudo version 1.9.15p5',
      sudoNopasswd: true,
    ),
  ),
  null,
);

Future<void> _until(bool Function() condition) async {
  final sw = Stopwatch()..start();
  while (!condition()) {
    if (sw.elapsed > const Duration(seconds: 5)) fail('condition not met');
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

void main() {
  group('ElevatedStartLink', () {
    test('a start runs the command line as root under sh -c; the rest '
        'goes to the link, and closing leaves it open', () async {
      final link = ScriptedLink();
      final elevated = ElevatedStartLink(link, _session(link));
      final started = elevated.start("env LC_ALL=C 'tail' '-n' '5' '/x'");
      await _until(() => link.commands.isNotEmpty);
      expect(
        link.commands.single,
        startsWith("env LC_ALL=C sudo -n -- 'sh' '-c' "),
      );
      expect(link.commands.single, contains('tail'));
      (await link.process(0))
        ..emitText('line\n')
        ..end();
      await started;

      expect(elevated.state, link.state);
      await elevated.close();
      expect(link.closes, 0);
    });
  });

  group('log files (LOG-22)', () {
    late ScriptedLink link;
    late AdminSession? admin;
    late List<EngineEvent> events;
    late LogStreamRouter router;

    setUp(() {
      link = ScriptedLink();
      admin = null;
      events = [];
      final clock = FakeClock();
      router = LogStreamRouter(
        linkFor: (_) => link,
        emit: events.add,
        adminFor: (_) => admin,
        startTimer: clock.startTimer,
        elapsed: () => clock.elapsed,
      )..retain({_srv});
      addTearDown(router.close);
    });

    void open(String id, {required bool follow, bool elevated = true}) =>
        expect(
          router.open(
            OpenLogStream(
              streamId: id,
              spec: LogStreamSpec(
                serverId: _srv,
                source: FileLogSource(_secure, elevated: elevated),
                window: 5,
                follow: follow,
              ),
            ),
          ),
          isNull,
        );

    List<LogStreamStatus> statuses(String id) => [
      for (final e in events)
        if (e case LogStreamState(:final streamId, :final status))
          if (streamId == id) status,
    ];

    test('without admin mode an elevated window or follow ends denied and '
        'runs nothing', () async {
      open('w', follow: false);
      open('f', follow: true);
      await pumpEventQueue();
      expect(statuses('w').last, _denied);
      expect(statuses('f').last, _denied);
      expect(link.commands, isEmpty);
    });

    test('with admin mode a window reads the file as root', () async {
      admin = _session(link);
      open('w', follow: false);
      await _until(() => link.commands.isNotEmpty);
      expect(link.commands.single, contains("sudo -n -- 'sh' '-c'"));
      expect(link.commands.single, contains(_secure));
      (await link.process(0))
        ..emitText('Oct 18 sshd[1]: Accepted publickey\n')
        ..end();
      await _until(() => statuses('w').any((s) => s is LogStreamEnded));
      final batch = events.whereType<LogBatch>().single;
      expect(batch.records, hasLength(1));
    });

    test('a plain read of the same file does not elevate', () async {
      admin = _session(link);
      open('w', follow: false, elevated: false);
      await _until(() => link.commands.isNotEmpty);
      expect(link.commands.single, isNot(contains('sudo')));
    });

    test('an elevated follow ends denied when admin mode does', () async {
      admin = _session(link);
      open('f', follow: true);
      await _until(() => link.commands.isNotEmpty);
      expect(link.commands.single, contains("sudo -n -- 'sh' '-c'"));
      expect(link.commands.single, contains("'-F'"));

      admin = null;
      router.adminChanged(_srv);
      await _until(() => statuses('f').any((s) => s is LogStreamEnded));
      expect(statuses('f').last, _denied);
    });
  });

  group('stack files (STK-04)', () {
    const compose = '/srv/shop/compose.yaml';
    late ScriptedLink elevation;
    late AdminSession? admin;
    late StackSources stacks;
    late DockerClient client;

    setUp(() {
      elevation = ScriptedLink();
      admin = null;
      final engine = _Engine();
      client = DockerClient(
        DockerHttpClient(() async => engine.connect().client),
        apiVersion: ApiVersion.tryParse('1.52')!,
      );
      stacks = StackSources(
        socketPath: '/var/run/docker.sock',
        run: (command, {required timeout, required maxOutputBytes}) async =>
            switch (command) {
              _ when command.contains('test -f') => const RemoteCommandResult(
                exitCode: 0,
                stdout: '0\n',
              ),
              _ when command.contains('docker-compose version') =>
                const RemoteCommandResult(
                  exitCode: 0,
                  stdout: '0 127\nDocker Compose version v2.29.7\n\n',
                ),
              _ => const RemoteCommandResult(exitCode: 0, stdout: 'web aa11\n'),
            },
        openFileSystem: () async => _DeniedFiles(),
        admin: () => admin,
      );
    });

    test('denied over SFTP without admin mode stays denied', () async {
      expect(
        await stacks.readFile(client, 'shop', compose),
        isA<DockerStackFileFailed>().having(
          (f) => f.failure,
          'failure',
          StackFileFailure.permissionDenied,
        ),
      );
      expect(elevation.commands, isEmpty);
    });

    test('with admin mode the file is read as root and masked', () async {
      admin = _session(elevation);
      final reading = stacks.readFile(client, 'shop', compose);
      await _until(() => elevation.commands.isNotEmpty);
      expect(elevation.commands.single, contains("sudo -n -- 'sh' '-c'"));
      expect(elevation.commands.single, contains(compose));
      const text =
          'services:\n  web:\n    environment:\n'
          '      DB_PASSWORD: hunter2\n';
      (await elevation.process(0))
        ..emitText('${utf8.encode(text).length}\n$text')
        ..end();

      final payload = await reading as DockerStackFilePayload;
      final shown = payload.text.map((s) => s.display).join();
      expect(shown, contains('DB_PASSWORD'));
      expect(shown, isNot(contains('hunter2')));
      expect(payload.size, utf8.encode(text).length);
      expect(payload.truncated, isFalse);
    });

    test('a file past the cap keeps its complete lines', () async {
      admin = _session(elevation);
      final reading = stacks.readFile(client, 'shop', compose);
      final line = '${'a' * 1023}\n';
      final big = line * (kStackFileMaxBytes ~/ line.length + 2);
      (await elevation.process(0)).emitText('${big.length}\n$big');

      final payload = await reading as DockerStackFilePayload;
      expect(payload.truncated, isTrue);
      final shown = payload.text.map((s) => s.display).join();
      expect(shown.length, lessThanOrEqualTo(kStackFileMaxBytes));
      expect(shown, endsWith('\n'));
    });

    test('a missing path and a link answer as SFTP would', () async {
      admin = _session(elevation);
      for (final (exit, failure) in [
        (4, StackFileFailure.notFound),
        (3, StackFileFailure.notRegularFile),
      ]) {
        final index = elevation.processes.length;
        final reading = stacks.readFile(client, 'shop', compose);
        (await elevation.process(index)).end(RemoteExit(exitCode: exit));
        expect(
          await reading,
          isA<DockerStackFileFailed>().having(
            (f) => f.failure,
            'failure',
            failure,
          ),
        );
      }
    });
  });
}

/// The container list of one verified compose project.
final class _Engine extends FakeDaemon {
  @override
  String respond(String requestLine) {
    final body = utf8.encode(
      jsonEncode([
        {
          'Id': 'a' * 64,
          'Names': ['/shop-web-1'],
          'State': 'running',
          'Labels': {
            ComposeLabelKeys.project: 'shop',
            ComposeLabelKeys.service: 'web',
            ComposeLabelKeys.oneoff: 'False',
            ComposeLabelKeys.projectWorkingDir: '/srv/shop',
            ComposeLabelKeys.projectConfigFiles: '/srv/shop/compose.yaml',
            ComposeLabelKeys.configHash: 'aa11',
          },
        },
      ]),
    );
    return 'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n'
        'Content-Length: ${body.length}\r\n\r\n${utf8.decode(body)}';
  }
}

/// An SFTP file system that may read nothing.
final class _DeniedFiles implements RemoteFileSystem {
  @override
  Never noSuchMethod(Invocation invocation) => throw const RemoteFileException(
    kind: RemoteFileErrorKind.permissionDenied,
    operation: 'stat',
    message: 'Permission denied',
  );
}
