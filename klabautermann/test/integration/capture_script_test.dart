// Contract tests for test/integration/capture.sh, the container shell
// and userland captures (03 §6.5, §11.3; K28c), and the recorded Docker
// API corpora of its sourced capture_docker_api.sh (03 §11.1, D21). CI
// runs the script in `klabautermann_integration` with Docker; these
// tests read both files and run the `--list` mode, which needs neither
// Docker nor the network, so the pins, the teardown, where it writes
// and the committed fixture set are checked on every package run.
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

/// Registries that serve Docker Hub's rate-limited content without the
/// limit, or other content entirely; a bare or docker.io reference
/// would pull from Docker Hub itself.
const _registries = {'mirror.gcr.io', 'quay.io', 'registry.access.redhat.com'};

final _pinnedImage = RegExp(
  r'^([a-z0-9.-]+)/[a-z0-9._/-]+:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$',
);
final _pinnedDeb = RegExp(r'^pool/main/\S+\.deb [0-9a-f]{64}$');

/// A command that pulls an image or starts a container from one.
final _startsContainer = RegExp(r'\bdocker (create|run|pull)\b');

/// One `declare -rA <name>=( [key]='value' ... )` entry.
final _arrayEntry = RegExp(r"^\s+\[([a-z0-9.-]+)\]='([^']*)'$");

typedef _Capture = ({
  String name,
  String image,
  String launch,
  String shell,
  List<String> packages,
});

void main() {
  late Directory klab;
  late String script;
  late String scriptPath;
  late String fixturesRoot;
  late String api;

  setUpAll(() async {
    final workspace = await Isolate.resolvePackageUri(
      Uri.parse('package:_klabautermann_workspace/'),
    );
    if (workspace == null) throw StateError('Workspace package is unresolved.');

    klab = Directory.fromUri(workspace.resolve('../'));
    scriptPath = '${klab.path}test/integration/capture.sh';
    script = await File(scriptPath).readAsString();
    fixturesRoot = '${klab.path}packages/klabautermann_host/test/fixtures';
    api = await File(
      '${klab.path}test/integration/capture_docker_api.sh',
    ).readAsString();
  });

  /// Runs `capture.sh --list` (plus [extra]) from [workingDirectory] with
  /// only PATH, HOME and, when given, KLABAUTERMANN_EVIDENCE_DIR set.
  Future<ProcessResult> list({
    String? evidenceDir,
    String? workingDirectory,
    List<String> extra = const [],
  }) => Process.run(
    'bash',
    [scriptPath, '--list', ...extra],
    workingDirectory: workingDirectory ?? klab.path,
    includeParentEnvironment: false,
    environment: {
      'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      'HOME': Directory.systemTemp.path,
      'KLABAUTERMANN_EVIDENCE_DIR': ?evidenceDir,
    },
  );

  Future<List<_Capture>> captures() async {
    final result = await list();
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return [
      for (final line in '${result.stdout}'.split('\n'))
        if (line.startsWith('capture '))
          switch (line.split(' ')) {
            [_, final name, final image, final launch, final shell, ...] &&
                final words =>
              (
                name: name,
                image: image,
                launch: launch,
                shell: shell,
                packages: words.sublist(5),
              ),
            _ => throw FormatException('bad capture line', line),
          },
    ];
  }

  group('script', () {
    test('runs under bash in strict mode before any command', () {
      final lines = script.split('\n');
      expect(lines.first, '#!/usr/bin/env bash');
      final firstCommand = lines.firstWhere(
        (l) => l.trim().isNotEmpty && !l.startsWith('#'),
      );
      expect(firstCommand, 'set -euo pipefail');
      expect(
        File(scriptPath).statSync().modeString(),
        startsWith('rwx'),
        reason: 'CI runs it as test/integration/capture.sh',
      );
    });

    test('pins every image by digest outside Docker Hub', () {
      final images = _array(script, 'images');
      expect(images, isNotEmpty);
      for (final MapEntry(key: key, value: ref) in images.entries) {
        final match = _pinnedImage.firstMatch(ref);
        expect(match, isNotNull, reason: '$key: $ref');
        expect(_registries, contains(match![1]), reason: '$key: $ref');
      }
      // Containers start only from the pinned table.
      for (final command in _commands(script)) {
        if (!_startsContainer.hasMatch(command)) continue;
        expect(
          command,
          anyOf(contains(r'"${images['), contains(r'"$ref"')),
          reason: command,
        );
      }
    });

    test('pins every Debian package by SHA-256 on a fixed snapshot', () {
      expect(
        script,
        matches(
          RegExp(
            r"deb_snapshot='https://snapshot\.debian\.org/archive/debian/"
            r"\d{8}T\d{6}Z'",
          ),
        ),
      );
      final debs = _array(script, 'debs');
      expect(debs, isNotEmpty);
      for (final MapEntry(key: key, value: pin) in debs.entries) {
        expect(pin, matches(_pinnedDeb), reason: key);
      }
      expect(script, contains('sha256sum --check'));
    });

    test('labels every container and removes them on every exit', () {
      expect(script, contains('trap teardown EXIT'));
      expect(script, contains("trap 'exit 130' INT"));
      expect(script, contains("trap 'exit 143' TERM"));
      final teardown = _function(script, 'teardown');
      expect(teardown, contains(r'docker ps -aq --filter "label=$run_label"'));
      expect(teardown, contains('docker rm -f'));
      expect(teardown, contains(r'rm -rf -- "$work"'));
      expect(teardown, contains(r'exit "$status"'));

      final starts = [
        for (final command in _commands(script))
          if (_startsContainer.hasMatch(command) &&
              !command.contains('docker pull'))
            command,
      ];
      expect(starts, isNotEmpty);
      for (final command in starts) {
        expect(command, contains(r'--label "$run_label"'), reason: command);
        expect(command, isNot(contains('--privileged')), reason: command);
        expect(command, isNot(matches(RegExp(r'\s(-p|--publish)\b'))));
        expect(command, isNot(matches(RegExp(r'\s(-v|--volume|--mount)\b'))));
      }
    });

    test('writes only to the evidence and work directories', () {
      // Variables that name a path below one of them.
      final below = {
        for (final m in RegExp(
          r'\b(\w+)="\$(evidence|work)/[^"]*"',
        ).allMatches(script))
          m[1]!,
      };
      final targets = <String>[];
      for (final command in _commands(script)) {
        // Redirections to files, not to descriptors (`>&2`, `2>&1`).
        for (final m in RegExp(
          r'(?<![<&\d])>>?(?!&)\s*("[^"]*"|[^\s;|)]+)',
        ).allMatches(command)) {
          targets.add(m[1]!);
        }
        if (RegExp(r'^(curl|dart compile)\b').hasMatch(command)) {
          targets.add(RegExp(r'\s-o\s+(\S+)').firstMatch(command)![1]!);
        }
        if (command.startsWith('mkdir ')) {
          targets.addAll(command.split(' ').skip(2));
        }
        if (command.startsWith('docker cp ')) {
          final words = command.split(' ||').first.trim().split(' ');
          // Into a container, or out of one into the evidence.
          if (!words.last.startsWith(r'"$cid:')) targets.add(words.last);
        }
      }
      expect(targets, isNotEmpty);
      for (final target in targets) {
        expect(
          target,
          anyOf(
            startsWith(r'"$evidence'),
            startsWith(r'"$work'),
            isIn([for (final v in below) '"\$$v"']),
            '/dev/null',
          ),
          reason: target,
        );
      }

      // Only --update copies into the repository, and only fixtures.
      final copies = [
        for (final command in _commands(script))
          if (command.startsWith('cp ')) command,
      ];
      expect(copies, [
        r'cp -R -- "$evidence/fixtures/$name" "$fixtures_root/$name"',
      ]);
      expect(
        script.substring(script.indexOf(r'if [[ "$mode" == update ]]; then')),
        contains(copies.single),
      );
    });

    test('compiles the tool and runs its capture command', () {
      expect(script, contains('dart compile exe'));
      expect(script, contains('tool/capture_fixtures.dart'));
      expect(
        _function(script, 'capture_in'),
        allOf(
          contains('/opt/klab/capture_fixtures capture --out /opt/klab/out'),
          contains(r'--platform "$name" "$flag" "$shell"'),
          contains('timeout '),
        ),
      );
    });
  });

  group('evidence directory', () {
    test('defaults to klabautermann/build/ci-evidence', () async {
      final result = await list();
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        '${result.stdout}'.split('\n').first,
        'evidence ${klab.path}build/ci-evidence/capture',
      );
    }, testOn: 'linux');

    test('resolves a relative path against the working directory', () async {
      final cwd = await Directory.systemTemp.createTemp('klab-capture-');
      addTearDown(() => cwd.delete(recursive: true));
      final real = cwd.resolveSymbolicLinksSync();

      final result = await list(evidenceDir: 'out', workingDirectory: real);

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(
        '${result.stdout}'.split('\n').first,
        'evidence $real/out/capture',
      );
    }, testOn: 'linux');

    test('accepts a build/ directory inside the repository', () async {
      final result = await list(evidenceDir: '${klab.path}build/elsewhere');
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }, testOn: 'linux');

    for (final inside in ['test/integration', 'packages/klabautermann_host']) {
      test('refuses $inside, inside the repository', () async {
        final result = await list(evidenceDir: '${klab.path}$inside');
        expect(result.exitCode, 1);
        expect('${result.stderr}', contains('not under a build/ directory'));
        expect(result.stdout, isEmpty);
      }, testOn: 'linux');
    }
  });

  group('capture list', () {
    test('matches the committed container fixtures', () async {
      final committed = [
        for (final dir in Directory(fixturesRoot).listSync())
          if (dir is Directory && dir.path.contains('-docker-'))
            dir.uri.pathSegments[dir.uri.pathSegments.length - 2],
      ];
      final names = [for (final c in await captures()) c.name];
      expect(names.toSet(), hasLength(names.length), reason: 'duplicates');
      expect(names, unorderedEquals(committed));
    }, testOn: 'linux');

    test('uses every image and package it pins', () async {
      final list = await captures();
      final images = _array(script, 'images').values.toSet();
      expect({for (final c in list) c.image}, images);
      final debs = _array(script, 'debs').keys.toSet();
      expect({for (final c in list) ...c.packages}, debs);
      for (final c in list) {
        expect(c.launch, anyOf('sh', 'login'), reason: c.name);
        expect(
          c.name,
          endsWith(
            '-${c.launch == 'login' ? 'login-' : ''}'
            '${c.shell}',
          ),
          reason: c.name,
        );
      }
    }, testOn: 'linux');

    test('each fixture records its image, shell and packages', () async {
      for (final c in await captures()) {
        final source = await File(
          '$fixturesRoot/${c.name}/SOURCE.md',
        ).readAsString();
        // The tool's launch label: `<path> -s` or `<path> -c '...'`.
        final label = c.launch == 'sh' ? ' -s`' : " -c 'exec env ";
        expect(source, contains('(local mode, `/'), reason: c.name);
        expect(
          source,
          matches(
            RegExp(
              'local mode, `/\\S*/${RegExp.escape(c.shell)}'
              '${RegExp.escape(label)}',
            ),
          ),
          reason: c.name,
        );
        expect(source, contains('`${c.image}`'), reason: c.name);
        for (final package in c.packages) {
          final pool = _array(script, 'debs')[package]!.split(' ').first;
          expect(source, contains('`${pool.split('/').last}`'), reason: c.name);
        }
        // Raw captures never reach the repository: each fixture is the
        // tool's reviewed output.
        expect(
          source,
          contains('The review found nothing left'),
          reason: c.name,
        );
      }
    }, testOn: 'linux');
  });
  group('docker api', () {
    /// The `api <corpus> <image> <runtime> <api>` lines of `--list`.
    Future<List<List<String>>> targets() async {
      final result = await list(extra: ['--docker-api-only']);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return [
        for (final line in '${result.stdout}'.split('\n'))
          if (line.startsWith('api ')) line.split(' ').sublist(1),
      ];
    }

    test('is sourced and selected with --docker-api-only', () async {
      expect(
        script,
        contains(r'source "$klab_dir/test/integration/capture_docker_api.sh"'),
      );
      expect(api.split('\n').first, '# shellcheck shell=bash');

      final all = await list();
      expect(all.exitCode, 0, reason: '${all.stderr}');
      final kinds = {
        for (final line in '${all.stdout}'.split('\n').skip(1))
          if (line.isNotEmpty) line.split(' ').first,
      };
      expect(kinds, {'capture', 'api'}, reason: 'check mode runs both');

      final only = await list(extra: ['--docker-api-only']);
      expect(only.exitCode, 0, reason: '${only.stderr}');
      final lines = '${only.stdout}'.trim().split('\n');
      expect(lines.first, startsWith('evidence '));
      expect(lines.skip(1), everyElement(startsWith('api ')));
      expect(lines.skip(1), hasLength(5));

      for (final bad in [
        ['--update', '--list'],
        ['--docker-api-only', '--docker-api-only'],
        ['--docker-api'],
      ]) {
        final result = await Process.run('bash', [scriptPath, ...bad]);
        expect(result.exitCode, 2, reason: '$bad');
        expect('${result.stderr}', contains('--docker-api-only'));
      }
    }, testOn: 'linux');

    test('pins every daemon and the seed image by digest', () async {
      final images = _array(api, 'api_images');
      expect(images, hasLength(5));
      for (final MapEntry(key: key, value: ref) in images.entries) {
        final match = _pinnedImage.firstMatch(ref);
        expect(match, isNotNull, reason: '$key: $ref');
        expect(_registries, contains(match![1]), reason: '$key: $ref');
      }
      final seed = RegExp(
        r"^readonly api_seed_image='([^']+)'$",
        multiLine: true,
      ).firstMatch(api);
      expect(seed, isNotNull);
      expect(seed![1], matches(_pinnedImage));
      expect(seed[1], startsWith('mirror.gcr.io/library/busybox:'));

      final listed = await targets();
      expect({for (final t in listed) t[1]}, images.values.toSet());
      for (final t in listed) {
        expect(t[2], anyOf('docker', 'podman'), reason: t[0]);
        expect(t[3], matches(RegExp(r'^1\.\d+$')), reason: t[0]);
        if (t[2] == 'docker') expect(t[0], 'api-${t[3]}');
      }
    }, testOn: 'linux');

    test('starts daemons unix-only and publishes nothing', () {
      final starts = [
        for (final command in _commands(api))
          if (_startsContainer.hasMatch(command) &&
              !command.contains('docker pull'))
            command,
      ];
      expect(starts, hasLength(3), reason: 'dockerd, podman, the tool');
      for (final command in starts) {
        expect(command, contains(r'--label "$run_label"'), reason: command);
        expect(command, isNot(matches(RegExp(r'\s(-p|--publish)\b'))));
        expect(command, isNot(contains('tcp://')));
        expect(
          command,
          anyOf(
            contains(r'"${api_images[$key]}"'),
            contains(r'"${images[debian-13]}"'),
          ),
          reason: command,
        );
        final volumes = [
          for (final m in RegExp(r'\s-v (\S+)').allMatches(command)) m[1]!,
        ];
        expect(volumes.first, r'"$sock_volume:/run/capture"');
        final daemon = command.contains('--privileged');
        if (daemon) {
          expect(
            command,
            anyOf(
              endsWith('dockerd --host=unix:///run/capture/docker.sock)" ||'),
              endsWith(
                'podman system service --time=0 '
                'unix:///run/capture/podman.sock)" ||',
              ),
            ),
          );
          expect(volumes, hasLength(2));
          expect(volumes.last, startsWith(r'"$data_volume:/var/lib/'));
          expect(command, contains('--cgroupns private'));
        } else {
          expect(command, contains('--network none'));
          expect(volumes, hasLength(1));
        }
      }
      expect([
        for (final c in starts)
          if (c.contains('--privileged')) c,
      ], hasLength(2));
      // The dind entrypoint adds tcp://0.0.0.0:2375 unless dockerd gets
      // its listeners explicitly.
      expect(api, contains('dockerd --host=unix://'));
      expect(api, isNot(contains('DOCKER_HOST')));
    });

    test('labels its volumes and removes everything on every exit', () {
      expect(
        _commands(api).where((c) => c.contains('docker volume create')),
        everyElement(contains(r'docker volume create --label "$run_label"')),
      );
      final teardown = _function(script, 'teardown');
      expect(
        teardown,
        contains(r'docker volume ls -q --filter "label=$run_label"'),
      );
      expect(teardown, contains('docker volume rm -f'));
      expect(teardown, contains('docker rm -fv'));
      final one = _function(api, 'api_capture_one');
      expect(one, contains(r'docker rm -fv $ids'));
      expect(one, contains(r'docker volume rm "$sock_volume" "$data_volume"'));
    });

    test('writes only to the evidence and work directories', () {
      final targets = <String>[];
      for (final command in _commands(api)) {
        for (final m in RegExp(
          r'(?<![<&\d])>>?(?!&)\s*("[^"]*"|[^\s;|)]+)',
        ).allMatches(command)) {
          targets.add(m[1]!);
        }
        if (command.startsWith('mkdir ')) {
          targets.addAll(command.split(' ').skip(2));
        }
      }
      expect(targets, isNotEmpty);
      for (final target in targets) {
        expect(
          target,
          anyOf(
            startsWith(r'"$evidence'),
            startsWith(r'"$work'),
            r'"$log"',
            '/dev/null',
          ),
          reason: target,
        );
      }
      expect(
        _function(api, 'api_capture_in'),
        contains(
          r'docker cp "$tool:/opt/klab/out/$name" "$evidence/docker-api/$name"',
        ),
      );

      // Only --update copies into the repository, and only corpora.
      final copies = [
        for (final command in _commands(api))
          if (command.startsWith('cp ')) command,
      ];
      expect(copies, [
        r'cp -R -- "$evidence/docker-api/$name" "$api_fixtures_root/$name"',
      ]);
      expect(_function(api, 'api_update'), contains(copies.single));
      expect(
        script,
        contains(
          'if [[ "\$mode" == update ]]; then\n'
          "  echo '== Replacing the committed Docker API corpora'\n"
          '  api_update\n',
        ),
      );
    });

    test('compiles the tool, captures and checks each corpus', () {
      final prepare = _function(api, 'api_prepare');
      expect(prepare, contains('dart compile exe'));
      expect(prepare, contains('tool/capture_api.dart'));
      expect(
        _function(api, 'api_capture_in'),
        allOf(
          contains('/opt/klab/capture_api capture --socket "\$socket"'),
          contains(r'--expect-api "$api"'),
          contains(r'--seed-image "$api_seed_image"'),
          contains(r'timeout "$api_capture_timeout_seconds"'),
        ),
      );
      expect(
        _function(api, 'api_captures'),
        contains(r'"$work/api-stage/capture_api" check "$committed"'),
      );
    });
  });
}

/// The entries of the associative array [name] in [script].
Map<String, String> _array(String script, String name) {
  final start = script.indexOf('declare -rA $name=(');
  if (start < 0) throw StateError('no array $name');
  final end = script.indexOf('\n)', start);
  return {
    for (final line in script.substring(start, end).split('\n').skip(1))
      if (_arrayEntry.firstMatch(line) case final m?) m[1]!: m[2]!,
  };
}

/// The body of the shell function [name] in [script].
String _function(String script, String name) {
  final start = script.indexOf('\n$name() {\n');
  if (start < 0) throw StateError('no function $name');
  return script.substring(start, script.indexOf('\n}\n', start));
}

/// [script]'s commands, one per logical line: continuation lines joined,
/// comments and leading whitespace dropped.
List<String> _commands(String script) => [
  for (final line
      in script
          .replaceAll(RegExp(r'\\\n\s*'), '')
          .split('\n')
          .map((l) => l.trim()))
    if (line.isNotEmpty && !line.startsWith('#')) line,
];
