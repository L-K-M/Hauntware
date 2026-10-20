// Stack source verification and file reads (03 §7.16 STK-01, STK-04,
// STK-05, STK-10; M11) over a forwarding link double whose execs the test
// answers and a fake SFTP file system: each verdict, the hash flag
// fallback, the legacy CLI, the short-action slots, masked and capped
// reads, refusals, and the quoting through a real `sh`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:klabautermann_core/src/docker/docker_router.dart';
import 'package:klabautermann_core/src/docker/docker_watch.dart'
    show kDockerEventBatch;
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

/// An SFTP file system over a map of files, which reads in 32 KiB chunks
/// and stops with `cancelled` once asked, as the real one does.
final class _Files implements RemoteFileSystem {
  final files = <String, List<int>>{};
  final failures = <String, RemoteFileErrorKind>{};
  final types = <String, RemoteFileType>{};
  final calls = <String>[];
  bool cancelled = false;

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    calls.add('stat $path');
    final kind = failures[path] ?? (files[path] == null ? _notFound : null);
    if (kind != null) {
      throw RemoteFileException(kind: kind, operation: 'stat', message: '');
    }
    return RemoteFileEntry(
      path: path,
      name: path.split('/').last,
      type: types[path] ?? RemoteFileType.file,
      size: files[path]!.length,
    );
  }

  static const _notFound = RemoteFileErrorKind.notFound;

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    calls.add('download $path');
    final bytes = files[path]!;
    final chunks = [
      for (var at = 0; at < bytes.length; at += 32 * 1024)
        bytes.sublist(at, (at + 32 * 1024).clamp(0, bytes.length)),
    ];
    await destination.addStream(
      Stream.fromIterable(
        chunks,
      ).takeWhile((_) => !(cancellation?.isCancelled ?? false)),
    );
    if (cancellation?.isCancelled ?? false) {
      cancelled = true;
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.cancelled,
        operation: 'download',
        message: 'Transfer cancelled.',
      );
    }
    return RemoteFileEntry(
      path: path,
      name: path.split('/').last,
      type: RemoteFileType.file,
      size: bytes.length,
    );
  }

  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

/// A router over one server whose execs the test answers: which config
/// files exist, the CLI detection's output and `config --hash`'s.
final class _Harness {
  _Harness(List<Map<String, Object?>> containers) {
    forwarding
      ..daemons[_socket] = daemon
      ..fileSystem = files
      ..answer = _answer;
    daemon.routes[_containersPath] = jsonEncode(containers);
    router = DockerRouter(
      linkFor: (_) => forwarding,
      emit: events.add,
      samplerSessions: (_) => samplers,
      startTimer: clock.startTimer,
      now: () => clock.now,
    )..retain({_srv});
  }

  final clock = FakeClock();
  final daemon = EngineDaemon();
  final forwarding = ForwardingLink();
  final files = _Files();
  late final DockerRouter router;
  final events = <EngineEvent>[];

  /// The session channels the server's samplers hold (M4 E13).
  int samplers = 0;

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

  Future<DockerPayload> read(String project, String path) async {
    router.probed(_srv, _profile);
    final id = 'q-${events.length}';
    router.query(
      DockerQuery(
        serverId: _srv,
        queryId: id,
        query: DockerStackFileQuery(project: project, path: path),
      ),
    );
    await settle();
    return events
        .whereType<DockerResult>()
        .singleWhere((r) => r.queryId == id)
        .payload;
  }
}

List<Map<String, Object?>> _demo({String webHash = 'feed01'}) => [
  _container('w1', _labels(service: 'web', hash: webHash)),
  _container('d1', _labels(service: 'db', hash: 'feed02')),
];

TypeMatcher<StackUnverified> _unverified(StackUnverifiedReason reason) =>
    isA<StackUnverified>().having((v) => v.reason, 'reason', reason);

String _shown(List<MaskedValue> spans) => spans.map((s) => s.display).join();

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

    /// Has [h]'s next runs refused at sshd's `MaxSessions`, each one
    /// teaching the link the limit in [limits], in order.
    void refuseAt(_Harness h, List<int> limits) {
      final answer = h.forwarding.answer!;
      h.forwarding.answer = (command) {
        if (limits.isEmpty) return answer(command);
        h.forwarding.seen = SshLinkSeen(
          learnedSessionLimit: limits.removeAt(0),
        );
        return Future.error(
          const ChannelOpenException(ChannelRefusal.sessionLimit, 'refused'),
        );
      };
    }

    test('a check sshd refuses at its MaxSessions runs again at the limit '
        'the link learned (M3 D22)', () async {
      // The link queues an open at the limit it learned rather than
      // sending it (03 §5.2). It counts the opens in flight, so a check
      // refused beside another can learn one too many first.
      final h = _Harness(_demo());
      refuseAt(h, [3, 2]);

      expect((await h.verified()).verdicts['demo'], isA<StackVerified>());
      expect(h.kinds, [_Run.test, _Run.cli, _Run.config]);
      expect(h.forwarding.commands, hasLength(5));
    });

    test('a refusal that teaches nothing new is unverified as a failed '
        'check', () async {
      final h = _Harness(_demo());
      refuseAt(h, [2, 2]);

      expect(
        (await h.verified()).verdicts['demo'],
        _unverified(StackUnverifiedReason.checkFailed),
      );
      expect(h.forwarding.commands, hasLength(2));
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

  group('at the learned session limit (M4 E13, plan M6)', () {
    test('a check the samplers leave no session for reads waiting for a '
        'channel, runs nothing, and checks with the next list once one '
        'is free', () async {
      final h = _Harness(_demo())..samplers = kSamplerChannels;
      h.forwarding.seen = const SshLinkSeen(learnedSessionLimit: 2);
      final waiting = await h.verified();
      expect(
        waiting.verdicts['demo'],
        isA<StackVerifying>().having(
          (v) => v.waiting,
          'waiting',
          StackWait.channel,
        ),
      );
      expect(h.runs, isEmpty);

      // A step borrowed the slow sampler's session: the next list, here
      // after a container event, checks the stack and verifies it.
      h.samplers = kSamplerChannels - 1;
      h.daemon.emit({
        'Type': 'container',
        'Action': 'start',
        'Actor': {'ID': 'w1', 'Attributes': <String, String>{}},
        'time': 1760702400,
        'timeNano': 1760702400 * 1000000000,
      });
      await h.clock.elapse(kDockerEventBatch);
      await h.settle();
      expect(h.stacks().last.verdicts['demo'], isA<StackVerified>());
      expect(h.kinds, [_Run.test, _Run.cli, _Run.config]);
    });

    test(
      'at a learned limit of 3 the check runs beside the samplers',
      () async {
        final h = _Harness(_demo())..samplers = kSamplerChannels;
        h.forwarding.seen = const SshLinkSeen(learnedSessionLimit: 3);
        final last = await h.verified();
        expect(last.verdicts['demo'], isA<StackVerified>());
        expect(h.mostInFlight, 1);
      },
    );
  });

  group('file reads (STK-04, M11)', () {
    test('a verified compose file arrives masked, with its size', () async {
      const text =
          'services:\n'
          '  db:\n'
          '    environment:\n'
          '      POSTGRES_PASSWORD: hunter2\n'
          '      - API_TOKEN=tok\n'
          '      DATABASE_HOST: postgres://app:pw@db/app\n';
      final h = _Harness(_demo());
      h.files.files[_compose] = utf8.encode(text);

      final payload = await h.read('demo', _compose) as DockerStackFilePayload;
      expect(payload.project, 'demo');
      expect(payload.path, _compose);
      expect(payload.size, text.length);
      expect(payload.truncated, isFalse);
      expect(
        _shown(payload.text),
        'services:\n'
        '  db:\n'
        '    environment:\n'
        '      POSTGRES_PASSWORD: ${MaskedValue.maskToken}\n'
        '      - API_TOKEN=${MaskedValue.maskToken}\n'
        '      DATABASE_HOST: postgres://app:${MaskedValue.maskToken}@db/app\n',
      );
      expect(
        [for (final s in payload.text) ?s.reveal()],
        ['hunter2', 'tok', 'pw'],
      );
      expect(h.files.calls, ['stat $_compose', 'download $_compose']);
    });

    test("the working directory's .env and a recorded env file read with "
        'every value masked', () async {
      final h = _Harness([
        _container(
          'w1',
          _labels(service: 'web', hash: 'feed01', envFile: '/srv/env/prod.env'),
        ),
        _container('d1', _labels(service: 'db', hash: 'feed02')),
      ]);
      h.files.files['/srv/demo/.env'] = utf8.encode('TAG=1.2\n');
      h.files.files['/srv/env/prod.env'] = utf8.encode('MODE=prod\n');

      for (final path in ['/srv/demo/.env', '/srv/env/prod.env']) {
        final payload = await h.read('demo', path) as DockerStackFilePayload;
        expect(_shown(payload.text), endsWith('=${MaskedValue.maskToken}\n'));
      }
      expect(
        h.runs.last.$2,
        containsAllInOrder(['--env-file', '/srv/env/prod.env', 'config']),
      );
    });

    test('a file over the cap is read to it and cancelled, keeping its '
        'complete lines', () async {
      final line = '${'x' * 99}\n';
      final big = StringBuffer();
      while (big.length <= kStackFileMaxBytes + 4096) {
        big.write(line);
      }
      big.write('DB_PASSWORD: tail\n');
      final h = _Harness(_demo());
      h.files.files[_compose] = utf8.encode(big.toString());

      final payload = await h.read('demo', _compose) as DockerStackFilePayload;
      expect(payload.truncated, isTrue);
      expect(payload.size, big.length);
      expect(h.files.cancelled, isTrue);
      final shown = _shown(payload.text);
      expect(shown.length, lessThanOrEqualTo(kStackFileMaxBytes));
      expect(shown.length % line.length, 0);
      expect(shown, isNot(contains('tail')));
    });

    test('SFTP refusals arrive typed', () async {
      final h = _Harness(_demo());
      h.files
        ..failures[_compose] = RemoteFileErrorKind.permissionDenied
        ..failures['/srv/demo/.env'] = RemoteFileErrorKind.disconnected;
      expect(
        await h.read('demo', _compose),
        isA<DockerStackFileFailed>().having(
          (f) => f.failure,
          'failure',
          StackFileFailure.permissionDenied,
        ),
      );
      expect(
        (await h.read('demo', '/srv/demo/.env') as DockerStackFileFailed)
            .failure,
        StackFileFailure.readFailed,
      );

      h.files
        ..failures.clear()
        ..files[_compose] = const []
        ..types[_compose] = RemoteFileType.symbolicLink;
      expect(
        (await h.read('demo', _compose) as DockerStackFileFailed).failure,
        StackFileFailure.notRegularFile,
      );
      h.files.files.remove(_compose);
      expect(
        (await h.read('demo', _compose) as DockerStackFileFailed).failure,
        StackFileFailure.notFound,
      );
    });

    test('an unverified stack, a path that is none of its files and an '
        'unknown stack are refused without SFTP', () async {
      final h = _Harness(_demo(webHash: 'dead00'));
      h.files.files[_compose] = utf8.encode('services: {}\n');

      expect(
        (await h.read('demo', _compose) as DockerStackFileFailed).failure,
        StackFileFailure.notVerified,
      );
      expect(
        (await h.read('demo', '/etc/shadow') as DockerStackFileFailed).failure,
        StackFileFailure.notStackFile,
      );
      expect(
        (await h.read('nope', _compose) as DockerStackFileFailed).failure,
        StackFileFailure.unknownStack,
      );
      expect(h.files.calls, isEmpty);
    });

    test('a query with a relative path or a bad project name is '
        'invalid', () async {
      final h = _Harness(_demo());
      for (final (project, path) in [
        ('demo', 'compose.yaml'),
        ('Demo', _compose),
      ]) {
        expect(
          await h.read(project, path),
          isA<DockerQueryFailed>().having(
            (f) => f.failure,
            'failure',
            DockerQueryFailure.invalidQuery,
          ),
        );
      }
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
      openFileSystem: () => throw UnimplementedError(),
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
