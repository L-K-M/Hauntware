// Contract tests for test/integration/check_image_pins.sh, the weekly
// check that every digest-pinned fixture and capture image still
// resolves (#259, #313), and the root `Image pins` workflow that runs
// it. The script runs with a stand-in for docker, so nothing here
// reaches a registry.
@TestOn('linux')
library;

import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Any registry image pinned by digest, with or without a port or tag.
final _pinnedImage = RegExp(
  r'[a-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?'
  r'@sha256:[0-9a-f]{64}',
);

/// The files whose pins the user-facing request names, by how their
/// images are found independently of the script.
const _scripts = ['capture.sh', 'capture_docker_api.sh'];
const _compose = 'docker-compose.yml';

/// The stand-in docker: `buildx imagetools inspect <ref>` fails with a
/// registry-style error for each ref listed in `$STUB_DEAD`, and once
/// for each ref in `$STUB_FLAKY` (keeping that state in `$STUB_STATE`).
/// Every call is logged to `$STUB_LOG`.
const _dockerStub = r'''#!/usr/bin/env bash
set -euo pipefail
echo "$*" >>"$STUB_LOG"
[[ "$1 $2 $3" == 'buildx imagetools inspect' ]] || exit 64
ref="$4"
if grep -qxF -- "$ref" "$STUB_DEAD"; then
  echo "ERROR: $ref: not found" >&2
  exit 1
fi
marker="$STUB_STATE/$(printf '%s' "$ref" | md5sum | cut -c1-32)"
if grep -qxF -- "$ref" "$STUB_FLAKY" && [[ ! -e "$marker" ]]; then
  touch "$marker"
  echo "ERROR: $ref: connection reset by peer" >&2
  exit 1
fi
echo "Name: $ref"
''';

void main() {
  late String integration;
  late String scriptPath;
  late YamlMap workflow;

  setUpAll(() async {
    final workspace = await Isolate.resolvePackageUri(
      Uri.parse('package:_klabautermann_workspace/'),
    );
    if (workspace == null) throw StateError('Workspace package is unresolved.');

    integration = Directory.fromUri(
      workspace.resolve('../test/integration/'),
    ).path;
    scriptPath = '${integration}check_image_pins.sh';
    workflow =
        loadYaml(
              await File.fromUri(
                workspace.resolve('../../.github/workflows/image-pins.yml'),
              ).readAsString(),
            )
            as YamlMap;
  });

  /// The `--list` output as pin -> the files that pin it.
  Future<Map<String, List<String>>> listed() async {
    final result = await Process.run('bash', [scriptPath, '--list']);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return {
      for (final line in (result.stdout as String).trim().split('\n'))
        line.split('\t').first: line.split('\t').last.split(' '),
    };
  }

  group('--list', () {
    test('covers every pin of the capture scripts and Compose file', () async {
      final pins = await listed();

      for (final name in _scripts) {
        final text = await File('$integration$name').readAsString();
        final found = _pinnedImage.allMatches(text).map((m) => m[0]!).toSet();
        expect(found, isNotEmpty, reason: name);
        for (final pin in found) {
          expect(pins[pin], contains(name), reason: pin);
        }
      }

      final compose =
          loadYaml(await File('$integration$_compose').readAsString())
              as YamlMap;
      final images = [
        for (final service in (compose['services'] as YamlMap).values)
          if ((service as YamlMap)['image'] case final String image
              when image.contains('@sha256:'))
            image,
      ];
      expect(images, isNotEmpty);
      for (final image in images) {
        expect(pins[image], contains(_compose), reason: image);
      }
    });

    test('names only real pins, each once, in files it read', () async {
      final pins = await listed();
      for (final MapEntry(key: pin, value: files) in pins.entries) {
        expect(pin, matches(RegExp(r'@sha256:[0-9a-f]{64}$')));
        for (final file in files) {
          expect(await File('$integration$file').readAsString(), contains(pin));
        }
      }
      // The exposure tests' placeholder digests are not pins.
      expect(pins.keys, everyElement(isNot(endsWith('@sha256:0'))));
    });
  });

  group('check', () {
    late Directory sandbox;
    late File log;
    late File dead;
    late File flaky;

    setUp(() async {
      sandbox = await Directory.systemTemp.createTemp('klab-image-pins-');
      final bin = await Directory('${sandbox.path}/bin').create();
      await Directory('${sandbox.path}/state').create();
      for (final (name, body) in [
        ('docker', _dockerStub),
        // The retry delay, which the tests do not wait out.
        ('sleep', '#!/bin/sh\nexit 0\n'),
      ]) {
        final file = File('${bin.path}/$name');
        await file.writeAsString(body);
        await Process.run('chmod', ['+x', file.path]);
      }
      log = File('${sandbox.path}/log')..createSync();
      dead = File('${sandbox.path}/dead')..createSync();
      flaky = File('${sandbox.path}/flaky')..createSync();
    });

    tearDown(() => sandbox.delete(recursive: true));

    Future<ProcessResult> check({Map<String, String> env = const {}}) =>
        Process.run(
          'bash',
          [scriptPath],
          environment: {
            'PATH': '${sandbox.path}/bin:${Platform.environment['PATH']}',
            'STUB_LOG': log.path,
            'STUB_DEAD': dead.path,
            'STUB_FLAKY': flaky.path,
            'STUB_STATE': '${sandbox.path}/state',
            'GITHUB_ACTIONS': '',
            'GITHUB_STEP_SUMMARY': '',
            ...env,
          },
        );

    List<String> inspected() =>
        log.readAsLinesSync().map((line) => line.split(' ').last).toList();

    test('passes once every pin resolves, inspecting each once', () async {
      final pins = await listed();
      final result = await check();

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(inspected(), unorderedEquals(pins.keys));
      expect(
        log.readAsLinesSync(),
        everyElement(startsWith('buildx imagetools inspect ')),
      );
      expect(result.stdout, contains('all ${pins.length} digest-pinned'));
    });

    test('fails naming each dead pin and the files that pin it', () async {
      final pins = await listed();
      final fedora = pins.keys.singleWhere((pin) => pin.contains('/fedora:'));
      final compose = pins.entries
          .firstWhere((entry) => entry.value.contains(_compose))
          .key;
      dead.writeAsStringSync('$fedora\n$compose\n');
      final summary = File('${sandbox.path}/summary');

      final result = await check(
        env: {'GITHUB_ACTIONS': 'true', 'GITHUB_STEP_SUMMARY': summary.path},
      );

      expect(result.exitCode, 1);
      // Each dead pin was retried before it counted.
      expect(inspected().where((ref) => ref == fedora), hasLength(3));
      expect(inspected().where((ref) => ref == compose), hasLength(3));
      expect(
        result.stderr,
        allOf(
          contains('2 of ${pins.length} digest-pinned images'),
          contains('$fedora (capture.sh)'),
          contains('$compose ($_compose)'),
        ),
      );
      expect(
        result.stdout,
        allOf(
          contains('::error title=Dead image pin::$fedora no longer'),
          contains('$fedora: not found'),
        ),
      );
      expect(
        summary.readAsStringSync(),
        allOf(contains('`$fedora` (capture.sh)'), contains('`$compose`')),
      );
    });

    test('a pin that fails once and then resolves passes', () async {
      final pins = await listed();
      final first = pins.keys.first;
      flaky.writeAsStringSync('$first\n');

      final result = await check();

      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(inspected().where((ref) => ref == first), hasLength(2));
    });
  });

  group('workflow', () {
    test('runs weekly and by hand', () {
      final on = workflow['on'] as YamlMap;
      expect(on.containsKey('workflow_dispatch'), isTrue);
      final schedule = on['schedule'] as YamlList;
      expect(schedule, hasLength(1));
      // Minute, hour and one weekday: once a week.
      expect(
        (schedule.single as YamlMap)['cron'],
        matches(RegExp(r'^\d+ \d+ \* \* [0-6]$')),
      );
    });

    test('runs the check on pull requests that change what it reads', () {
      final paths = (workflow['on'] as YamlMap)['pull_request']['paths'];
      expect(
        paths,
        containsAll([
          'klabautermann/test/integration/*.sh',
          'klabautermann/test/integration/docker-compose*.yml',
          'klabautermann/test/integration/sshd/Dockerfile*',
          '.github/workflows/image-pins.yml',
        ]),
      );
    });

    test('runs the script, with read-only contents', () {
      expect(workflow['permissions'], {'contents': 'read'});
      final steps = (workflow['jobs'] as YamlMap)['check']['steps'] as YamlList;
      expect(
        steps.map((step) => (step as YamlMap)['run']),
        contains('klabautermann/test/integration/check_image_pins.sh'),
      );
    });
  });
}
