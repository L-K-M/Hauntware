// The Docker transport ladder over a forwarding link double (03 §5.3,
// §5.4, §5.9; M8): discovery order, each refusal class the exec probe
// tells apart, each rank M3 builds, and the commands it builds.
import 'dart:io';

import 'package:klabautermann_core/src/docker/docker_ladder.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show ApiVersion, DockerClient, DockerHttpClient;
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart'
    show
        ChannelOpenException,
        ChannelRefusal,
        RemoteCommandException,
        quoteShellWord;
import 'package:test/test.dart';

import '../support/forwarding_link.dart';

const _rootful = '/var/run/docker.sock';
const _rootless = '/run/user/1000/docker.sock';
const _podman = '/run/podman/podman.sock';
const _podmanRootless = '/run/user/1000/podman/podman.sock';

/// The exec probe's answers: `test -S`, `test -w`, `command -v nc`.
const _missing = '1\n1\n1\n';
const _denied = '0\n1\n1\n';
const _disabled = '0\n0\n1\n';
const _disabledWithNc = '0\n0\n0\n';

/// A profile whose probe found [present] (and checked every 03 §5.4
/// path), with [tools] on the exec `PATH`.
HostProfile _profile(
  List<String> present, {
  Map<String, String?> tools = const {
    'docker': null,
    'podman': null,
    'socat': null,
  },
  SudoKind sudo = SudoKind.none,
  bool socketsAnswered = true,
}) => HostProfile(
  uid: 1000,
  sudoKind: sudo,
  tools: tools,
  engineSockets: [
    for (final path in [_rootful, _podman, _rootless, _podmanRootless])
      EngineSocket(path: path, exists: present.contains(path), writable: true),
  ],
  areaStatuses: {
    'tools': SectionStatus.ok,
    if (socketsAnswered) 'sockets': SectionStatus.ok,
  },
);

const _dockerCli = {'docker': '/usr/bin/docker', 'podman': null, 'socat': null};
const _podmanCli = {'docker': null, 'podman': '/usr/bin/podman', 'socat': null};
const _socatOnly = {'docker': null, 'podman': null, 'socat': '/usr/bin/socat'};

/// The probe command for [path], as the ladder builds it.
String _probeCommand(String path) => HostCommands.commandLine([
  'sh',
  '-c',
  r'test -S "$1"; echo $?; test -w "$1"; echo $?; '
      r'command -v nc >/dev/null 2>&1; echo $?',
  'sh',
  path,
], quote: quoteShellWord);

Future<DockerRoute> _route(
  ForwardingLink link,
  HostProfile profile, {
  String? override,
}) async =>
    await DockerLadder.resolve(link, profile, override: override)
        as DockerRoute;

Future<DockerNoRouteReason> _none(
  ForwardingLink link,
  HostProfile profile, {
  String? override,
}) async =>
    (await DockerLadder.resolve(link, profile, override: override)
            as DockerRouteNone)
        .reason;

/// Pings through [route] with the Docker client, as the engine will.
Future<void> _ping(ForwardingLink link, DockerRoute route) async {
  final http = DockerHttpClient(() => openDockerDuplex(link, route));
  final client = DockerClient(http, apiVersion: const ApiVersion(1, 52));
  final ping = await client.ping();
  expect(ping.apiVersion, const ApiVersion(1, 52));
  await http.close();
}

void main() {
  group('rank 1', () {
    test('reaches the socket over streamlocal, without an exec', () async {
      final link = ForwardingLink();
      final daemon = link.daemons[_rootful] = PingDaemon();

      final route = await _route(link, _profile([_rootful]));

      expect(route.rank, DockerRank.streamlocal);
      expect(route.socketPath, _rootful);
      expect(route.runtime, EngineRuntime.docker);
      expect(route.mode, EngineMode.rootful);
      expect(route.label, DockerRouteLabel.socketForward);
      expect(route.rootEquivalence, DockerRootEquivalence.rootfulSocket);
      expect(route.relayArgv, isEmpty);
      expect(link.commands, isEmpty);
      // The trial channel is closed again.
      expect(daemon.closed, daemon.connections);

      await _ping(link, route);
      expect(daemon.requests, ['HEAD /_ping HTTP/1.1']);
      expect(link.started, isEmpty);
    });

    test('tries the sockets in 03 §5.4 order, not the probe\'s', () async {
      final link = ForwardingLink()
        ..daemons[_podman] = PingDaemon()
        ..daemons[_rootless] = PingDaemon();

      final route = await _route(link, _profile([_podman, _rootless]));

      expect(link.opens, [_rootless]);
      expect(route.runtime, EngineRuntime.docker);
      expect(route.mode, EngineMode.rootless);
      expect(route.rootEquivalence, DockerRootEquivalence.rootlessEngine);
    });

    test('a podman socket is classified as podman', () async {
      final link = ForwardingLink()..daemons[_podmanRootless] = PingDaemon();

      final route = await _route(link, _profile([_podmanRootless]));

      expect(route.runtime, EngineRuntime.podman);
      expect(route.mode, EngineMode.rootless);
    });

    test('the override goes first; a custom path is unclassified', () async {
      const custom = '/srv/engine/api.sock';
      final link = ForwardingLink()
        ..daemons[custom] = PingDaemon()
        ..daemons[_rootful] = PingDaemon();

      final route = await _route(link, _profile([_rootful]), override: custom);

      expect(link.opens, [custom]);
      expect(route.socketPath, custom);
      expect(route.runtime, isNull);
      expect(route.mode, isNull);
      expect(route.rootEquivalence, DockerRootEquivalence.unclassified);
    });

    test('an override naming a 03 §5.4 path takes its class', () async {
      final link = ForwardingLink()..daemons[_podman] = PingDaemon();

      final route = await _route(link, _profile(const []), override: _podman);

      expect(route.runtime, EngineRuntime.podman);
      expect(route.mode, EngineMode.rootful);
    });

    test('a link failure other than a forwarding refusal propagates', () {
      final link = ForwardingLink()
        ..openFailures.add(
          const ChannelOpenException(ChannelRefusal.other, 'too many streams'),
        );

      expect(
        DockerLadder.resolve(link, _profile([_rootful])),
        throwsA(isA<ChannelOpenException>()),
      );
    });
  });

  group('refusal classes', () {
    test('missing: one probe of that path, then the next candidate', () async {
      final link = ForwardingLink()
        ..probeAnswers[_rootful] = _missing
        ..daemons[_podman] = PingDaemon();

      final route = await _route(link, _profile([_rootful, _podman]));

      expect(link.opens, [_rootful, _podman]);
      expect(link.commands, [_probeCommand(_rootful)]);
      expect(route.socketPath, _podman);
      expect(route.rank, DockerRank.streamlocal);
    });

    test('missing everywhere is no socket', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _missing;

      expect(
        await _none(link, _profile([_rootful])),
        DockerNoRouteReason.noSocket,
      );
    });

    test('denied without sudo names the access check', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _denied;

      expect(
        await _none(link, _profile([_rootful], tools: _dockerCli)),
        DockerNoRouteReason.socketDenied,
      );
      expect(link.started, isEmpty);
    });

    test('denied with sudo needs admin mode; rank 3 is never tried', () async {
      for (final sudo in [SudoKind.sudo, SudoKind.sudoRs, SudoKind.unknown]) {
        final link = ForwardingLink()..probeAnswers[_rootful] = _denied;

        expect(
          await _none(
            link,
            _profile([_rootful], tools: _dockerCli, sudo: sudo),
          ),
          DockerNoRouteReason.needsAdminMode,
        );
        expect(link.commands, [_probeCommand(_rootful)]);
        expect(link.started, isEmpty);
      }
    });

    test('a denied socket moves on to the next candidate', () async {
      final link = ForwardingLink()
        ..probeAnswers[_rootful] = _denied
        ..daemons[_rootless] = PingDaemon();

      final route = await _route(link, _profile([_rootful, _rootless]));

      expect(route.socketPath, _rootless);
    });

    test('disabled forwarding goes to the relay ranks', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _disabled;

      final route = await _route(link, _profile([_rootful], tools: _dockerCli));

      expect(route.rank, DockerRank.cliRelay);
    });

    test('the reason is the first in precedence across candidates', () async {
      var link = ForwardingLink()
        ..probeAnswers[_rootful] = _denied
        ..probeAnswers[_rootless] = _missing;
      expect(
        await _none(link, _profile([_rootful, _rootless])),
        DockerNoRouteReason.socketDenied,
      );

      link = ForwardingLink()
        ..probeAnswers[_rootful] = _denied
        ..probeAnswers[_rootless] = _disabled;
      expect(
        await _none(link, _profile([_rootful, _rootless])),
        DockerNoRouteReason.noRelay,
      );
    });

    test('a failed probe is probe failed', () async {
      var link = ForwardingLink()
        ..runFailures.add(const RemoteCommandException('channel dropped'));
      expect(
        await _none(link, _profile([_rootful])),
        DockerNoRouteReason.probeFailed,
      );

      link = ForwardingLink()
        ..runFailures.add(
          const ChannelOpenException(ChannelRefusal.sessionLimit, 'refused'),
        );
      expect(
        await _none(link, _profile([_rootful])),
        DockerNoRouteReason.probeFailed,
      );

      link = ForwardingLink()
        ..probeAnswers[_rootful] = _disabled
        ..probeExitCode = 127;
      expect(
        await _none(link, _profile([_rootful])),
        DockerNoRouteReason.probeFailed,
      );

      link = ForwardingLink()..probeAnswers[_rootful] = 'Welcome!\n0\n0\n0\n';
      expect(
        await _none(link, _profile([_rootful])),
        DockerNoRouteReason.probeFailed,
      );
    });

    test('no candidate: no socket, or unknown without the probe', () async {
      expect(
        await _none(ForwardingLink(), _profile(const [])),
        DockerNoRouteReason.noSocket,
      );
      expect(
        await _none(
          ForwardingLink(),
          _profile(const [], socketsAnswered: false),
        ),
        DockerNoRouteReason.socketsUnknown,
      );
    });
  });

  group('rank 2', () {
    test('docker dial-stdio names the socket with --host', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _disabled;

      final route = await _route(link, _profile([_rootful], tools: _dockerCli));

      expect(route.rank, DockerRank.cliRelay);
      expect(route.label, DockerRouteLabel.cliRelay);
      expect(route.relayArgv, [
        'docker',
        '--host',
        'unix://$_rootful',
        'system',
        'dial-stdio',
      ]);

      await _ping(link, route);
      expect(link.started, [
        HostCommands.commandLine(route.relayArgv, quote: quoteShellWord),
      ]);
      expect(link.relayDaemon.requests, ['HEAD /_ping HTTP/1.1']);
    });

    test('podman dial-stdio names the socket with --url', () async {
      final link = ForwardingLink()..probeAnswers[_podman] = _disabled;

      final route = await _route(link, _profile([_podman], tools: _podmanCli));

      expect(route.relayArgv, [
        'podman',
        '--url',
        'unix://$_podman',
        'system',
        'dial-stdio',
      ]);
    });

    test('a podman socket takes the docker CLI without podman', () async {
      final link = ForwardingLink()..probeAnswers[_podman] = _disabled;

      final route = await _route(link, _profile([_podman], tools: _dockerCli));

      expect(route.relayArgv.first, 'docker');
    });

    test('a docker socket never takes the podman CLI', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _disabled;

      expect(
        await _none(link, _profile([_rootful], tools: _podmanCli)),
        DockerNoRouteReason.noRelay,
      );
    });

    test('a CLI outside the exec PATH is not found (Snap)', () async {
      // A Snap docker lives in /snap/bin, which a non-interactive exec's
      // PATH may lack: the probe reports it absent.
      final link = ForwardingLink()..probeAnswers[_rootful] = _disabled;

      final none = await _none(
        link,
        _profile(
          [_rootful],
          tools: const {'docker': null, 'podman': null, 'socat': null},
        ),
      );

      expect(none, DockerNoRouteReason.noRelay);
      expect(link.started, isEmpty);
    });

    test('a CLI the probe did not report is not tried', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _disabled;

      expect(
        await _none(link, _profile([_rootful], tools: const {})),
        DockerNoRouteReason.noRelay,
      );
    });
  });

  group('rank 4', () {
    test('socat when the probe saw it', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _disabledWithNc;

      final route = await _route(link, _profile([_rootful], tools: _socatOnly));

      expect(route.rank, DockerRank.socketRelay);
      expect(route.label, DockerRouteLabel.socatRelay);
      expect(route.relayArgv, ['socat', 'STDIO', 'UNIX-CONNECT:$_rootful']);
      await _ping(link, route);
    });

    test('nc -U when socat is absent and the probe found nc', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _disabledWithNc;

      final route = await _route(link, _profile([_rootful]));

      expect(route.rank, DockerRank.socketRelay);
      expect(route.relayArgv, ['nc', '-U', _rootful]);
      await _ping(link, route);
    });

    test('a path socat would split goes to nc -U', () async {
      const odd = '/srv/a,b:c!!d/docker.sock';
      final link = ForwardingLink()..probeAnswers[odd] = _disabledWithNc;

      final route = await _route(
        link,
        _profile(const [], tools: _socatOnly),
        override: odd,
      );

      expect(route.relayArgv, ['nc', '-U', odd]);
    });

    test('neither socat nor nc is no relay', () async {
      final link = ForwardingLink()..probeAnswers[_rootful] = _disabled;

      expect(
        await _none(link, _profile([_rootful])),
        DockerNoRouteReason.noRelay,
      );
    });
  });

  group('labels', () {
    test('cover every rank plus none, once each', () async {
      final none = await DockerLadder.resolve(
        ForwardingLink(),
        _profile(const []),
      );
      expect(none, isA<DockerRouteNone>());
      final labels = [for (final r in DockerRank.values) r.label];
      expect(labels.toSet(), hasLength(DockerRank.values.length));
      expect({...labels, none.label}, DockerRouteLabel.values.toSet());
      expect([for (final r in DockerRank.values) r.number], [1, 2, 4]);
    });
  });

  group('quoting', () {
    test('an override with a line break or NUL is refused', () {
      for (final bad in ['relative.sock', '/a\nb.sock', '/a\rb', '/a\u0000b']) {
        expect(
          DockerLadder.resolve(
            ForwardingLink(),
            _profile(const []),
            override: bad,
          ),
          throwsArgumentError,
          reason: bad,
        );
      }
    });

    test('the probe passes a hostile path to the shell unchanged', () async {
      final link = ForwardingLink(probeShell: ProbeShell.local);
      final dir = await Directory.systemTemp.createTemp('klab-');
      link.workingDirectory = dir.path;
      addTearDown(() => dir.delete(recursive: true));

      // A real socket whose name a shell would act on unquoted.
      final hostile = "${dir.path}/a b'\"\$(touch pwned)`touch pwned`;x";
      final server = await ServerSocket.bind(
        InternetAddress(hostile, type: InternetAddressType.unix),
        0,
      );
      addTearDown(server.close);

      final route = await _route(
        link,
        _profile(const [], tools: _dockerCli),
        override: hostile,
      );

      expect(route.rank, DockerRank.cliRelay);
      expect(route.relayArgv, contains('unix://$hostile'));
      expect(File('${dir.path}/pwned').existsSync(), isFalse);

      final missing = '$hostile.gone';
      expect(
        await _none(link, _profile(const []), override: missing),
        DockerNoRouteReason.noSocket,
      );
      expect(File('${dir.path}/pwned').existsSync(), isFalse);
    }, tags: ['shell']);
  });
}
