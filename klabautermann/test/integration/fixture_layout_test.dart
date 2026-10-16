// Contract tests of the sshd fixture's files (03 §11.3, D53), so a change
// that would break the fixture fails here, without Docker, before the
// integration job runs it.
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// Poltergeist's files the fixture builds on, from the repository root.
const _poltergeistDockerfile =
    'poltergeist/test/integration/sshd-modern/Dockerfile';
const _commonConfig =
    'poltergeist/test/integration/sshd-common/config/sshd_config.common';
const _safetyChecker = 'poltergeist/test/integration/check_config.dart';

/// The common config's mount, relative to docker-compose.yml.
const _commonMount =
    '../../../poltergeist/test/integration/sshd-common/config:'
    '/etc/ssh/fixture:ro';

final _digestPinned = RegExp(r'^FROM \S+@sha256:[0-9a-f]{64}$');

void main() {
  late Directory root;

  setUpAll(() async {
    final workspace = await Isolate.resolvePackageUri(
      Uri.parse('package:_klabautermann_workspace/'),
    );
    if (workspace == null) throw StateError('Workspace package is unresolved.');
    root = Directory.fromUri(workspace.resolve('../../'));
  });

  String read(String path) => File('${root.path}$path').readAsStringSync();

  /// [text]'s lines without comments and blank lines.
  List<String> directives(String text) => [
    for (final line in text.split('\n'))
      if (line.trim() case final line when line.isNotEmpty)
        if (!line.startsWith('#')) line,
  ];

  test('the image builds on the digest Poltergeist pins', () {
    final ours = read(
      'klabautermann/test/integration/sshd/Dockerfile',
    ).split('\n').first;
    expect(ours, matches(_digestPinned));
    expect(ours, read(_poltergeistDockerfile).split('\n').first);
  });

  test('the jump host forwards ahead of the common config', () {
    // sshd keeps the first value it reads (sshd_config(5)): the common
    // config's refusal would win over a later line.
    expect(directives(read(_commonConfig)), contains('AllowTcpForwarding no'));
    expect(
      directives(read('klabautermann/test/integration/sshd/sshd_config.jump')),
      [
        'AllowTcpForwarding local',
        'Include /etc/ssh/fixture/sshd_config.common',
      ],
    );
    expect(
      directives(
        read('klabautermann/test/integration/sshd/sshd_config.target'),
      ),
      ['Include /etc/ssh/fixture/sshd_config.common'],
    );
  });

  test('every service mounts the common config and publishes on loopback '
      'only', () {
    final compose =
        loadYaml(read('klabautermann/test/integration/docker-compose.yml'))
            as YamlMap;
    final services = compose['services'] as YamlMap;
    expect(services.keys, unorderedEquals(['sshd', 'jump']));
    for (final MapEntry(key: String name, value: YamlMap entry)
        in services.entries) {
      // package:yaml keeps a merge key as an ordinary one.
      final service = {...?entry['<<'] as YamlMap?, ...entry};
      expect(service['build']['context'], 'sshd', reason: name);
      expect(service['volumes'], contains(_commonMount), reason: name);
      expect(service['network_mode'], isNull, reason: name);
      expect(service['privileged'], isNull, reason: name);
      for (final port in service['ports'] as YamlList) {
        expect(port['host_ip'], '127.0.0.1', reason: name);
      }
    }
  });

  test("run.sh checks the config with Poltergeist's checker, not a copy", () {
    expect(File('${root.path}$_safetyChecker').existsSync(), isTrue);
    final run = read('klabautermann/test/integration/run.sh');
    expect(run, contains('/../$_safetyChecker'));
    expect(
      run.replaceAll(RegExp(r'\s*\\\n\s*'), ' '),
      contains(
        'compose config --format json | "\$dart_binary" run "\$safety_checker"',
      ),
    );
    final copies = Directory('${root.path}klabautermann/test')
        .listSync(recursive: true)
        .where((entity) => entity.path.endsWith('/check_config.dart'));
    expect(copies, isEmpty);
  });

  test('run.sh locks, checks and arms teardown before it starts the '
      'fixture', () {
    final run = read('klabautermann/test/integration/run.sh');
    final lines = run.split('\n');
    int at(String line) {
      final index = lines.indexOf(line);
      expect(index, isNonNegative, reason: 'run.sh has no line "$line"');
      return index;
    }

    // Whole unindented lines: the script's own steps, not a function's.
    final firstCompose = at('compose down --volumes --remove-orphans');
    expect(at('if ! flock --nonblock 9; then'), lessThan(firstCompose));
    expect(at('trap on_exit EXIT'), lessThan(firstCompose));
    final up = at('compose up --detach --build');
    expect(
      at('check_rendered_config'),
      allOf(greaterThan(firstCompose), lessThan(up)),
    );
    expect(run, contains('compose down --volumes --remove-orphans || '));
  });

  test('run.sh exports every variable the engine suites read', () {
    // The suites skip when run.sh exported none of these, so renaming
    // them all would pass the job with no engine test run.
    final support = read(
      'klabautermann/packages/klabautermann_core/test/integration/support/'
      'fixture.dart',
    );
    final variables = {
      for (final match in RegExp(r"_variable\('(\w+)'\)").allMatches(support))
        'KLABAUTERMANN_FIXTURE_${match[1]}',
    };
    expect(variables, isNotEmpty);
    final run = read('klabautermann/test/integration/run.sh');
    final exported = {
      for (final line in run.replaceAll('\\\n', ' ').split('\n'))
        if (line.trim().split(RegExp(r'\s+')) case ['export', ...final names])
          for (final name in names) name.split('=').first,
    };
    expect(exported, containsAll(variables));
  });

  test('run.sh runs the tagged engine suites one at a time', () {
    final run = read('klabautermann/test/integration/run.sh');
    expect(run, contains('test --concurrency=1 --tags integration'));
    expect(run, contains('packages/klabautermann_core/test/integration'));
    final tags = loadYaml(read('klabautermann/dart_test.yaml'))['tags'];
    expect((tags as YamlMap).containsKey('integration'), isTrue);
  });
}
