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

/// An image reference pinned by digest.
final _pinnedImage = RegExp(r'^\S+@sha256:[0-9a-f]{64}$');

/// The Docker host's negative variants (M3 D11): each one's config lines
/// ahead of the common config's Include, and its loopback port.
const _negativeVariants = {
  'neg-nostreamlocal': (
    ['AllowTcpForwarding local', 'AllowStreamLocalForwarding no'],
    2245,
  ),
  'neg-disableforwarding': (
    ['AllowTcpForwarding local', 'DisableForwarding yes'],
    2246,
  ),
  'neg-notcp': (['AllowTcpForwarding no'], 2247),
  'neg-permitopen': (
    ['AllowTcpForwarding local', 'PermitOpen 127.0.0.1:1'],
    2248,
  ),
  'neg-maxsessions2': (['AllowTcpForwarding local', 'MaxSessions 2'], 2249),
};

/// The variant that refuses with a key option over the Docker host's own
/// config, and its loopback port.
const _restrictVariant = 'neg-restrict';
const _restrictPort = 2250;

/// The Compose services that are sshd hosts, and the Docker engine.
final _sshdServices = [
  'sshd',
  'jump',
  'docker-sshd',
  ..._negativeVariants.keys,
  _restrictVariant,
];
const _dind = 'dind';
const _registry = 'registry';

/// The dind socket's directory, on the volume the Docker host shares.
const _socketVolume = 'docker-run:/run/docker-fixture';

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

  /// docker-compose.yml's services, merge keys resolved.
  Map<String, Map<Object?, Object?>> services() {
    final compose =
        loadYaml(read('klabautermann/test/integration/docker-compose.yml'))
            as YamlMap;
    return {
      for (final MapEntry(key: String name, value: YamlMap entry)
          in (compose['services'] as YamlMap).entries)
        // package:yaml keeps a merge key as an ordinary one.
        name: {...?entry['<<'] as YamlMap?, ...entry},
    };
  }

  test('the images build on the digest Poltergeist pins', () {
    for (final dockerfile in ['Dockerfile', 'Dockerfile.docker']) {
      final ours = read(
        'klabautermann/test/integration/sshd/$dockerfile',
      ).split('\n').first;
      expect(ours, matches(_digestPinned), reason: dockerfile);
      expect(
        ours,
        read(_poltergeistDockerfile).split('\n').first,
        reason: dockerfile,
      );
    }
  });

  test('the Docker host copies the CLI from one digest-pinned image', () {
    // A stage, not a frozen base: a new GHCR package starts private (06).
    final dockerfile = read(
      'klabautermann/test/integration/sshd/Dockerfile.docker',
    ).replaceAll(RegExp(r'\s*\\\n\s*'), ' ');
    final sources = {
      for (final match in RegExp(r'--from=(\S+)').allMatches(dockerfile))
        match[1]!,
    };
    expect(sources, hasLength(1));
    expect(sources.single, matches(_pinnedImage));
    expect(dockerfile, contains('/usr/local/bin/docker'));
    expect(dockerfile, contains('cli-plugins/docker-compose'));
    expect(RegExp(r'^FROM ', multiLine: true).allMatches(dockerfile), [
      anything,
    ]);
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

  test('the Docker host forwards ahead of the common config', () {
    // The common config's AllowTcpForwarding no refuses streamlocal too
    // (03 §5.3), and the first value sshd reads wins.
    expect(
      directives(
        read('klabautermann/test/integration/sshd/sshd_config.docker'),
      ),
      [
        'AllowTcpForwarding local',
        'Include /etc/ssh/fixture/sshd_config.common',
      ],
    );
    expect(
      services()['docker-sshd']!['command'],
      '/etc/klabautermann/sshd_config.docker',
    );
  });

  test('the negative variants refuse ahead of the common config, on '
      'the Docker host with its socket', () {
    final all = services();
    final dockerfile = read(
      'klabautermann/test/integration/sshd/Dockerfile.docker',
    );
    expect(
      dockerfile,
      contains('COPY sshd_config.docker sshd_config.neg-* /etc/klabautermann/'),
    );
    for (final MapEntry(key: name, value: (lines, port))
        in _negativeVariants.entries) {
      // sshd keeps the first value it reads (sshd_config(5)).
      expect(
        directives(
          read('klabautermann/test/integration/sshd/sshd_config.$name'),
        ),
        [...lines, 'Include /etc/ssh/fixture/sshd_config.common'],
        reason: name,
      );
      final service = all[name]!;
      expect(service['command'], '/etc/klabautermann/sshd_config.$name');
      expect(service['image'], all['docker-sshd']!['image'], reason: name);
      expect(service['volumes'], all['docker-sshd']!['volumes'], reason: name);
      expect(service['ports'], [
        {
          'target': 22,
          'host_ip': '127.0.0.1',
          'published': '$port',
          'protocol': 'tcp',
        },
      ], reason: name);
    }
  });

  test('neg-restrict signs in with restrict keys over the Docker host '
      'config', () {
    final restrict = services()[_restrictVariant]!;
    expect(restrict['command'], '/etc/klabautermann/sshd_config.docker');
    expect(restrict['image'], services()['docker-sshd']!['image']);
    expect(restrict['volumes'], contains(_socketVolume));
    expect(
      restrict['volumes'],
      contains(
        endsWith('/authorized_keys.restrict:/run/fixture/authorized_keys:ro'),
      ),
    );
    expect(restrict['ports'], [
      {
        'target': 22,
        'host_ip': '127.0.0.1',
        'published': '$_restrictPort',
        'protocol': 'tcp',
      },
    ]);

    final lines = read(
      'klabautermann/test/integration/run.sh',
    ).replaceAll(RegExp(r'\s*\\\n\s*'), ' ').split('\n');
    int at(String line) {
      final index = lines.indexOf(line);
      expect(index, isNonNegative, reason: 'run.sh has no line "$line"');
      return index;
    }

    final written = at(
      'sed \'s/^/restrict /\' "\$runtime_dir/authorized_keys" '
      '>"\$runtime_dir/authorized_keys.restrict"',
    );
    expect(
      written,
      greaterThan(
        lines.indexWhere(
          (line) => line.endsWith('>"\$runtime_dir/authorized_keys"'),
        ),
      ),
    );
    expect(written, lessThan(at('compose up --detach --build')));
  });

  test('every sshd service mounts the common config and publishes on '
      'loopback only', () {
    final all = services();
    expect(all.keys, unorderedEquals([..._sshdServices, _dind, _registry]));
    for (final name in _sshdServices) {
      final service = all[name]!;
      expect((service['build'] as Map)['context'], 'sshd', reason: name);
      expect(service['volumes'], contains(_commonMount), reason: name);
      expect(service['network_mode'], isNull, reason: name);
      expect(service['privileged'], isNull, reason: name);
      for (final port in service['ports'] as YamlList) {
        expect(port['host_ip'], '127.0.0.1', reason: name);
      }
    }
  });

  test('only dind runs privileged, and it publishes nothing', () {
    final all = services();
    final dind = all[_dind]!;
    expect(dind['privileged'], isTrue);
    expect(dind['image'], matches(_pinnedImage));
    expect(dind['ports'], isNull);
    expect(dind['expose'], isNull);
    expect(dind['network_mode'], isNull);
    for (final MapEntry(:key, :value) in all.entries) {
      if (key != _dind) expect(value['privileged'], isNull, reason: key);
    }
  });

  test('the registry is pinned, publishes nothing, and is the one dind '
      'trusts over plain HTTP (M4 E27)', () {
    final all = services();
    final registry = all[_registry]!;
    expect(registry['image'], matches(_pinnedImage));
    expect(registry['ports'], isNull);
    expect(registry['expose'], isNull);
    expect(registry['network_mode'], isNull);
    final command = (all[_dind]!['command'] as YamlList).cast<String>();
    expect(command.where((a) => a.startsWith('--insecure-registry')), [
      '--insecure-registry=registry:5000',
    ]);
    final seed = read('klabautermann/test/integration/seed_docker.sh');
    expect(seed, contains("app_image='registry:5000/klab/app:1'"));
    expect(seed, contains(r'docker push --quiet "$app_image"'));
    for (final stack in ['redeploy', 'orphans', 'managed']) {
      expect(seed, contains('"\$stacks/$stack/compose.yaml"'), reason: stack);
    }
    expect(seed, contains('--name ssh-port --publish 22:22'));
  });

  test('dind listens on its Unix socket only, on the shared volume', () {
    // A command that names dockerd keeps the image's entrypoint from
    // adding its TCP listener (check_docker_exposure.dart).
    final all = services();
    final command = (all[_dind]!['command'] as YamlList).cast<String>();
    expect(command.first, 'dockerd');
    final hosts = [
      for (final argument in command)
        if (argument.startsWith('--host') || argument.startsWith('-H'))
          argument,
    ];
    expect(hosts, ['--host=unix:///run/docker-fixture/docker.sock']);
    expect(command, contains('--group=990'));
    expect(all[_dind]!['volumes'], [_socketVolume]);
    expect(all['docker-sshd']!['volumes'], contains(_socketVolume));
    final compose =
        loadYaml(read('klabautermann/test/integration/docker-compose.yml'))
            as YamlMap;
    expect((compose['volumes'] as YamlMap).keys, ['docker-run']);
  });

  test('no service publishes an engine port or binds a host socket', () {
    for (final MapEntry(key: name, value: service) in services().entries) {
      for (final port in (service['ports'] as YamlList?) ?? YamlList()) {
        // YAML reads 2375 as an int and "2375" as a string; reject both.
        for (final key in ['target', 'published']) {
          expect('${port[key]}', isNot(anyOf('2375', '2376')), reason: name);
        }
      }
      for (final volume in (service['volumes'] as YamlList?) ?? YamlList()) {
        expect('$volume', isNot(contains('docker.sock')), reason: name);
        expect('$volume', isNot(matches(r':/(var/)?run(:|$)')), reason: name);
        // The host's run directory holds its socket wherever it is mounted.
        final source = volume is YamlMap
            ? '${volume['source']}'
            : '$volume'.split(':').first;
        expect(source, isNot(matches(r'^/(var/)?run/?$')), reason: name);
      }
    }
  });

  test("run.sh checks the Docker exposure rules after Poltergeist's "
      'checker', () {
    final run = read(
      'klabautermann/test/integration/run.sh',
    ).replaceAll(RegExp(r'\s*\\\n\s*'), ' ');
    final poltergeist = run.indexOf('| "\$dart_binary" run "\$safety_checker"');
    final docker = run.indexOf(
      'compose config --format json | "\$dart_binary" run '
      '"\$docker_exposure_checker"',
    );
    expect(poltergeist, isNonNegative);
    expect(docker, greaterThan(poltergeist));
    expect(
      run,
      contains(
        'docker_exposure_checker="\$integration_dir/'
        'check_docker_exposure.dart"',
      ),
    );
  });

  test('run.sh seeds the Docker host after readiness and before the '
      'suites', () {
    final lines = read('klabautermann/test/integration/run.sh').split('\n');
    int at(String line) {
      final index = lines.indexOf(line);
      expect(index, isNonNegative, reason: 'run.sh has no line "$line"');
      return index;
    }

    final waited = RegExp(
      r'^readonly services=\(([^)]*)\)',
      multiLine: true,
    ).firstMatch(lines.join('\n'))![1]!.trim().split(RegExp(r'\s+'));
    expect(waited, _sshdServices);
    final seed = at('seed_docker_host');
    expect(seed, greaterThan(at('  wait_for_sshd "\$port"')));
    expect(
      seed,
      lessThan(
        lines.indexWhere(
          (line) => line.contains('test --concurrency=1 --tags integration'),
        ),
      ),
    );
    final run = lines.join('\n');
    expect(
      run,
      contains('docker_host_ssh sh -s -- "\$image_id" <"\$seed_script"'),
    );
    expect(
      run,
      contains("readonly seed_image='mirror.gcr.io/library/busybox:"),
    );
    expect(
      RegExp(r"readonly seed_image='(\S+)'").firstMatch(run)![1],
      matches(_pinnedImage),
    );
  });

  test('the Docker suite runs with the engine suites under its own '
      'tag', () {
    final suite = read(
      'klabautermann/packages/klabautermann_core/test/integration/'
      'docker_link_test.dart',
    );
    expect(suite, contains("@Tags(['integration', 'docker'])"));
    for (final path in [
      'klabautermann/dart_test.yaml',
      'klabautermann/packages/klabautermann_core/dart_test.yaml',
    ]) {
      final tags = loadYaml(read(path))['tags'] as YamlMap?;
      expect(tags?.containsKey('docker'), isTrue, reason: path);
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

  test('run.sh runs the tagged soak alone with the variables it reads', () {
    // The soak skips without them, and run.sh's soak.json check is what
    // keeps a renamed one from passing the job.
    final support = read(
      'klabautermann/packages/klabautermann_core/test/integration/support/'
      'soak.dart',
    );
    final variables = {
      for (final match in RegExp(
        r"environment\['(KLABAUTERMANN_SOAK_\w+)'\]",
      ).allMatches(support))
        match[1]!,
    };
    expect(variables, {'KLABAUTERMANN_SOAK_SECONDS', 'KLABAUTERMANN_SOAK_DIR'});
    final run = read('klabautermann/test/integration/run.sh');
    for (final name in variables) {
      expect(run, contains('$name="\$'), reason: name);
    }
    expect(run, contains('test --concurrency=1 --tags soak'));
    expect(
      run,
      contains('packages/klabautermann_core/test/integration/soak_test.dart'),
    );
    expect(
      read(
        'klabautermann/packages/klabautermann_core/test/integration/'
        'soak_test.dart',
      ),
      contains("@Tags(['soak'])"),
    );
    final tags = loadYaml(read('klabautermann/dart_test.yaml'))['tags'];
    expect((tags as YamlMap).containsKey('soak'), isTrue);
  });
}
