// Stack source verification (03 §7.16 STK-01, STK-05, STK-10; M11) over
// a forwarding link double whose execs the test answers: each verdict,
// the hash flag fallback, the legacy CLI, the short-action slots, and
// the quoting through a real `sh`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/docker_router.dart';
import 'package:klabautermann_core/src/docker/stack_sources.dart';
import 'package:klabautermann_core/src/links/channel_quota.dart';
import 'package:klabautermann_docker/klabautermann_docker.dart'
    show ComposeLabelKeys, groupComposeProjects, maskedLabels;
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

import '../support/engine_daemon.dart';
import '../support/fake_clock.dart';
import '../support/forwarding_link.dart';

const _srv = 'srv-1';
const _socket = '/var/run/docker.sock';
const _containersPath = '/v1.52/containers/json';
const _compose = '/srv/demo/compose.yaml';
const _plugin = '0 127\nDocker Compose version v2.29.7\n\n';

final _profile = HostProfile(
  uid: 1000,
  sudoKind: SudoKind.none,
  tools: const {'docker': '/usr/bin/docker', 'podman': null},
  engineSockets: const [
    EngineSocket(path: _socket, exists: true, writable: true),
  ],
  areaStatuses: const {'tools': SectionStatus.ok, 'sockets': SectionStatus.ok},
);

Map<String, String> _labels({
  String project = 'demo',
  required String service,
  String? hash,
  String? files = _compose,
  String directory = '/srv/demo',
  String? envFile,
  Map<String, String> extra = const {},
}) => {
  ComposeLabelKeys.project: project,
  ComposeLabelKeys.service: service,
  ComposeLabelKeys.projectConfigFiles: ?files,
  ComposeLabelKeys.projectWorkingDir: directory,
  ComposeLabelKeys.projectEnvironmentFile: ?envFile,
  ComposeLabelKeys.configHash: ?hash,
  ...extra,
};

Map<String, Object?> _container(String id, Map<String, String> labels) => {
  'Id': id,
  'Names': ['/$id'],
  'State': 'running',
  'Labels': labels,
};

/// The words of [command] as `quoteShellWord` quoted them, past the
/// `HostCommands.commandLine` prefix.
List<String> _argv(String command) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  for (var i = 0; i < command.length; i++) {
    final c = command[i];
    if (c == ' ') {
      if (inWord) words.add(word.toString());
      word.clear();
      inWord = false;
    } else if (c == "'") {
      final end = command.indexOf("'", i + 1);
      word.write(command.substring(i + 1, end));
      i = end;
      inWord = true;
    } else if (c == '"') {
      final end = command.indexOf('"', i + 1);
      word.write(command.substring(i + 1, end).replaceAll(r'\\', r'\'));
      i = end;
      inWord = true;
    } else {
      word.write(c);
      inWord = true;
    }
  }
  if (inWord) words.add(word.toString());
  return words.sublist(4);
}

enum _Run { test, cli, config }

/// A router over one server whose execs the test answers: which config
/// files exist, the CLI detection's output and `config --hash`'s.
final class _Harness {
  _Harness(List<Map<String, Object?>> containers) {
    forwarding
      ..daemons[_socket] = daemon
      ..answer = _answer;
    daemon.routes[_containersPath] = jsonEncode(containers);
    router = DockerRouter(
      linkFor: (_) => forwarding,
      emit: events.add,
      startTimer: clock.startTimer,
      now: () => clock.now,
    )..retain({_srv});
  }

  final clock = FakeClock();
  final daemon = EngineDaemon();
  final forwarding = ForwardingLink();
  late final DockerRouter router;
  final events = <EngineEvent>[];

  final missing = <String>{};
  String cli = _plugin;
  RemoteCommandResult hashes = const RemoteCommandResult(
    stdout: 'db feed02\nweb feed01\n',
    exitCode: 0,
  );

  /// Every answered run by kind, with its words.
  final runs = <(_Run, List<String>)>[];

  /// Holds every answer until completed, counting the runs at once.
  Completer<void>? hold;
  int inFlight = 0;
  int mostInFlight = 0;

  Future<RemoteCommandResult>? _answer(String command) {
    final argv = _argv(command);
    final kind = argv.first == 'docker'
        ? _Run.config
        : argv[2].contains('docker-compose')
        ? _Run.cli
        : _Run.test;
    runs.add((kind, argv));
    final result = switch (kind) {
      _Run.test => RemoteCommandResult(
        stdout: [
          for (final f in argv.sublist(4)) missing.contains(f) ? '1' : '0',
        ].join('\n'),
        exitCode: 0,
      ),
      _Run.cli => RemoteCommandResult(stdout: cli, exitCode: 0),
      _Run.config => hashes,
    };
    return () async {
      inFlight++;
      if (inFlight > mostInFlight) mostInFlight = inFlight;
      await hold?.future;
      inFlight--;
      return result;
    }();
  }

  List<_Run> get kinds => [for (final (kind, _) in runs) kind];

  Future<void> settle() => pumpEventQueue(times: 100);

  void watch() => router.watch(
    const DockerWatch(
      serverId: _srv,
      watchId: 'w-1',
      lists: {DockerWatchList.stacks},
    ),
  );

  /// The stacks lists sent so far.
  List<DockerStacksPayload> stacks() => [
    for (final e in events.whereType<DockerListChanged>())
      e.payload as DockerStacksPayload,
  ];

  /// Watches the stacks and lets every check finish; the last list.
  Future<DockerStacksPayload> verified() async {
    watch();
    router.probed(_srv, _profile);
    await settle();
    return stacks().last;
  }
}

List<Map<String, Object?>> _demo({String webHash = 'feed01'}) => [
  _container('w1', _labels(service: 'web', hash: webHash)),
  _container('d1', _labels(service: 'db', hash: 'feed02')),
];

TypeMatcher<StackUnverified> _unverified(StackUnverifiedReason reason) =>
    isA<StackUnverified>().having((v) => v.reason, 'reason', reason);

void main() {
  group('verification (STK-01, STK-05)', () {
    test('a project whose hashes match is verified once checked, after a '
        'list that says it is being checked', () async {
      final h = _Harness(_demo());
      final last = await h.verified();

      final sent = h.stacks();
      expect(sent, hasLength(2));
      expect(sent.first.verdicts['demo'], isA<StackVerifying>());
      expect(last.verdicts['demo'], isA<StackVerified>());
      expect(last.composeCli!.pluginVersion, '2.29.7');
      expect(last.composeCli!.standaloneVersion, isNull);
      expect(h.kinds, [_Run.test, _Run.cli, _Run.config]);

      expect(h.runs.first.$2.sublist(4), [_compose]);
      expect(h.runs.last.$2, [
        'docker',
        '--host',
        'unix://$_socket',
        'compose',
        '-p',
        'demo',
        '--project-directory',
        '/srv/demo',
        '-f',
        _compose,
        'config',
        '--hash',
        '*',
      ]);
    });

    test('a verdict holds for the same labels, and a view opening the '
        'stacks again checks again without detecting the CLI', () async {
      final h = _Harness(_demo());
      await h.verified();
      h.router.unwatch(const DockerUnwatch(serverId: _srv, watchId: 'w-1'));
      await h.settle();
      h.events.clear();

      h.watch();
      await h.settle();
      expect(h.stacks().last.verdicts['demo'], isA<StackVerified>());
      expect(h.kinds, [
        _Run.test,
        _Run.cli,
        _Run.config,
        _Run.test,
        _Run.config,
      ]);
    });

    test('a changed file is unverified: its hash differs', () async {
      final h = _Harness(_demo(webHash: 'dead00'));
      final last = await h.verified();
      expect(
        last.verdicts['demo'],
        _unverified(StackUnverifiedReason.hashMismatch),
      );
    });

    test('a missing file reads source not on host, deployed by the manager '
        'the labels mark, which also badges the stack', () async {
      final h = _Harness([
        _container(
          'w1',
          _labels(
            service: 'web',
            hash: 'feed01',
            files: '/data/compose/3/docker-compose.yml',
            extra: {'coolify.managed': 'true'},
          ),
        ),
      ])..missing.add('/data/compose/3/docker-compose.yml');
      final last = await h.verified();

      expect(
        last.verdicts['demo'],
        isA<StackSourceNotOnHost>().having(
          (v) => v.deployedBy,
          'deployedBy',
          ExternalManager.coolify,
        ),
      );
      final project = last.grouping.project('demo')!;
      expect(project.ownership.isOwned, isTrue);
      expect(project.ownership.badgeLabel, 'managed by Coolify');
      expect(h.kinds, [_Run.test]);
    });

    test('an unmarked project with a missing file names no manager', () async {
      final h = _Harness(_demo())..missing.add(_compose);
      final last = await h.verified();
      expect(
        last.verdicts['demo'],
        isA<StackSourceNotOnHost>().having((v) => v.deployedBy, 'by', isNull),
      );
    });

    test('a CLI that refuses the hash flag form falls back to unverified, '
        'as does output that is no service hashes', () async {
      final refused = _Harness(_demo())
        ..hashes = const RemoteCommandResult(
          stderr: 'unknown flag: --hash',
          exitCode: 1,
        );
      expect(
        (await refused.verified()).verdicts['demo'],
        _unverified(StackUnverifiedReason.cliCouldNotHash),
      );

      final garbled = _Harness(_demo())
        ..hashes = const RemoteCommandResult(stdout: 'feed01\n', exitCode: 0);
      expect(
        (await garbled.verified()).verdicts['demo'],
        _unverified(StackUnverifiedReason.cliCouldNotHash),
      );
    });

    test('a config that fails is unverified without keeping its error '
        'text', () async {
      final h = _Harness(_demo())
        ..hashes = const RemoteCommandResult(
          stderr: 'invalid interpolation format for DB_PASSWORD=hunter2',
          exitCode: 15,
        );
      final last = await h.verified();
      expect(
        last.verdicts['demo'],
        _unverified(StackUnverifiedReason.configFailed),
      );
      expect('${h.events}', isNot(contains('hunter2')));
    });

    test('only the legacy docker-compose is read-only and verifies '
        'nothing; the CLI is detected once for every project', () async {
      final h = _Harness([
        ..._demo(),
        _container(
          'o1',
          _labels(
            project: 'other',
            service: 'app',
            hash: 'feed03',
            files: '/srv/other/compose.yaml',
          ),
        ),
      ])..cli = '1 0\n\ndocker-compose version 1.29.2, build 5becea4c\n';
      final last = await h.verified();

      for (final project in ['demo', 'other']) {
        expect(
          last.verdicts[project],
          _unverified(StackUnverifiedReason.standaloneComposeOnly),
        );
      }
      expect(last.composeCli!.standaloneVersion, '1.29.2');
      expect(last.composeCli!.standaloneLegacy, isTrue);
      expect(last.composeCli!.pluginVersion, isNull);
      expect(h.kinds.where((k) => k == _Run.cli), hasLength(1));
      expect(h.kinds, isNot(contains(_Run.config)));
    });

    test('a standalone Compose v2 is not legacy', () {
      expect(
        const DockerComposeCli(standaloneVersion: '2.20.2').standaloneLegacy,
        isFalse,
      );
    });

    test('no compose CLI leaves the stack unverified with that '
        'reason', () async {
      final h = _Harness(_demo())..cli = '127 127\n\n\n';
      expect(
        (await h.verified()).verdicts['demo'],
        _unverified(StackUnverifiedReason.noComposeCli),
      );
    });

    test('labels without config files or hashes decide at once, with no '
        'exec and a single list', () async {
      final h = _Harness([
        _container('a1', _labels(project: 'bare', service: 'a', files: null)),
        _container('b1', _labels(project: 'nohash', service: 'b')),
        _container(
          'c1',
          _labels(
            project: 'odd',
            service: 'c',
            hash: 'feed04',
            files: 'rel.yml',
          ),
        ),
      ]);
      final last = await h.verified();

      expect(h.stacks(), hasLength(1));
      expect(
        last.verdicts['bare'],
        _unverified(StackUnverifiedReason.noSourceLabels),
      );
      expect(
        last.verdicts['nohash'],
        _unverified(StackUnverifiedReason.noHashLabels),
      );
      expect(
        last.verdicts['odd'],
        _unverified(StackUnverifiedReason.unsafeLabels),
      );
      expect(h.runs, isEmpty);
    });

    test('a link failure is unverified as a failed check', () async {
      final h = _Harness(_demo());
      h.forwarding.runFailures.add(const RemoteCommandException('gone'));
      expect(
        (await h.verified()).verdicts['demo'],
        _unverified(StackUnverifiedReason.checkFailed),
      );
    });

    test('checks take short-action slots: two at once', () async {
      final h = _Harness([
        for (final name in ['a', 'b', 'c'])
          _container(
            name,
            _labels(
              project: name,
              service: 's',
              hash: 'feed04',
              files: '/srv/$name/compose.yaml',
            ),
          ),
      ])..hold = Completer();
      h.watch();
      h.router.probed(_srv, _profile);
      await h.settle();
      expect(h.inFlight, ChannelShare.shortAction.limit);

      h.hold!.complete();
      await h.settle();
      expect(h.mostInFlight, ChannelShare.shortAction.limit);
      expect(
        h.stacks().last.verdicts.values,
        everyElement(isA<StackUnverified>()),
      );
    });
  });

  test('the file checks quote paths through a real sh', () async {
    final dir = await Directory.systemTemp.createTemp('klab stacks ');
    addTearDown(() => dir.delete(recursive: true));
    final present = File("${dir.path}/it's here/compose.yaml");
    await present.create(recursive: true);

    // Every command runs in the local `sh` but the CLI detection, which
    // finds no compose so no daemon is asked.
    final sources = StackSources(
      socketPath: _socket,
      run: (command, {required timeout, required maxOutputBytes}) async {
        if (command.contains('docker-compose')) {
          return const RemoteCommandResult(
            stdout: '127 127\n\n\n',
            exitCode: 0,
          );
        }
        final r = await Process.run('sh', ['-c', command]);
        return RemoteCommandResult(
          stdout: r.stdout as String,
          stderr: r.stderr as String,
          exitCode: r.exitCode,
        );
      },
    );
    ContainerSummary container(String project, String files) =>
        ContainerSummary(
          id: project,
          labels: maskedLabels({
            ComposeLabelKeys.project: project,
            ComposeLabelKeys.service: 's',
            ComposeLabelKeys.projectConfigFiles: files,
            ComposeLabelKeys.configHash: 'feed04',
          }),
        );
    final grouping = groupComposeProjects([
      container('found', present.path),
      container('gone', '${present.path},${dir.path}/missing \$HOME.yml'),
    ]);

    await sources.verify(grouping);
    final verdicts = sources.known(grouping);
    expect(verdicts['found'], _unverified(StackUnverifiedReason.noComposeCli));
    expect(verdicts['gone'], isA<StackSourceNotOnHost>());
  }, testOn: 'posix');
}
