import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import 'harness.dart';

Object? fixtureJson(String name) => jsonDecode(fixtureString(name));

List<ContainerSummary> webContainers() =>
    parseContainerSummaries(fixtureJson('containers-1.44.json')).value;

void main() {
  group('compose labels', () {
    test('reads the label model off a container', () {
      final web = webContainers().first;
      final labels = ComposeLabels.fromContainerLabels(web.labels)!;
      expect(labels.project, 'web');
      expect(labels.service, 'web');
      expect(labels.containerNumber, '1');
      expect(labels.workingDir, '/opt/web');
      expect(labels.configFiles, [
        '/opt/web/compose.yaml',
        '/opt/web/compose.override.yaml',
      ]);
      expect(labels.environmentFiles, ['/opt/web/.env']);
      expect(labels.configHash, 'abc123def456');
      expect(labels.dependsOnServices, ['db']);
      expect(labels.isOneOff, isFalse);
      expect(labels.version, '2.39.1');
    });

    test('returns null without a project label', () {
      final loose = webContainers().last;
      expect(ComposeLabels.fromContainerLabels(loose.labels), isNull);
    });
  });

  group('project grouping (03 §7.16 STK-01, STK-02)', () {
    test('groups services and keeps unmanaged containers aside', () {
      final grouping = groupComposeProjects(webContainers());
      expect(grouping.projects.map((p) => p.name), ['coolify-app', 'web']);
      expect(grouping.unmanaged.single.name, 'loose-db');

      final web = grouping.project('web')!;
      expect(web.services.map((s) => s.name), containsAll(['web', 'db']));
      expect(web.workingDir, '/opt/web');
      expect(web.configFiles, hasLength(2));
      expect(web.ownership.isOwned, isFalse);

      final coolify = grouping.project('coolify-app')!;
      expect(coolify.ownership.isOwned, isTrue);
      expect(coolify.ownership.primary!.manager, ExternalManager.coolify);
      expect(coolify.ownership.badgeLabel, 'managed by Coolify');
    });

    test('orders services by depends_on for start and reverse for stop', () {
      final web = groupComposeProjects(webContainers()).project('web')!;
      expect(web.startOrder.map((s) => s.name), ['db', 'web']);
      expect(web.stopOrder.map((s) => s.name), ['web', 'db']);
      expect(web.hasDependencyCycle, isFalse);
    });
  });

  group('ownership markers (03 §8.7)', () {
    test('detects Coolify, Portainer, Swarm and a Podman quadlet', () {
      expect(
        detectOwnership(
          maskedLabels({'coolify.managed': 'true'}),
        ).primary!.manager,
        ExternalManager.coolify,
      );
      expect(
        detectOwnership(
          maskedLabels({'io.portainer.stack.name': 'x'}),
        ).primary!.manager,
        ExternalManager.portainer,
      );
      expect(
        detectOwnership(
          maskedLabels({'com.docker.stack.namespace': 's'}),
        ).primary!.manager,
        ExternalManager.swarm,
      );
      expect(
        detectOwnership(
          maskedLabels({'io.podman.systemd_unit': 'web.service'}),
        ).primary!.manager,
        ExternalManager.systemd,
      );
    });

    test('an owned target is never made less read-only', () {
      final owned = detectOwnership(maskedLabels({'coolify.managed': 'true'}));
      expect(owned.isOwned, isTrue);
      expect(Ownership.none.isOwned, isFalse);
    });
  });

  group('compose command builders (03 §7.16 STK-06)', () {
    test('ps builds the documented argv with the socket', () {
      final inv = composePs(
        socketPath: '/var/run/docker.sock',
        project: 'web',
        projectDirectory: '/opt/web',
        configFiles: const ['/opt/web/compose.yaml'],
        envFile: '/opt/web/.env',
        all: true,
      );
      expect(inv.argv, [
        'docker',
        '--host',
        'unix:///var/run/docker.sock',
        'compose',
        '-p',
        'web',
        '--project-directory',
        '/opt/web',
        '-f',
        '/opt/web/compose.yaml',
        '--env-file',
        '/opt/web/.env',
        'ps',
        '--all',
        '--format',
        'json',
      ]);
    });

    test('config supports quiet and hash modes', () {
      final quiet = composeConfig(
        socketPath: '/run/docker.sock',
        project: 'web',
        quiet: true,
      );
      expect(quiet.argv.sublist(quiet.argv.length - 2), ['config', '-q']);
      final hash = composeConfig(
        socketPath: '/run/docker.sock',
        project: 'web',
        hash: '*',
      );
      expect(hash.argv.sublist(hash.argv.length - 2), ['--hash', '*']);
      final envs = composeConfig(
        socketPath: '/run/docker.sock',
        project: 'web',
        envFiles: const ['/opt/web/.env', '/opt/web/prod.env'],
        hash: '*',
      );
      expect(
        envs.argv,
        containsAllInOrder([
          '--env-file',
          '/opt/web/.env',
          '--env-file',
          '/opt/web/prod.env',
          'config',
        ]),
      );
    });

    test('up and pull carry the output flags and services', () {
      final up = composeUp(
        socketPath: '/run/docker.sock',
        project: 'web',
        removeOrphans: true,
        services: const ['web'],
      );
      expect(up.argv, containsAll(['--progress', 'plain', '--ansi', 'never']));
      expect(up.argv.sublist(up.argv.length - 3), [
        '-d',
        '--remove-orphans',
        'web',
      ]);
      final pull = composePull(socketPath: '/run/docker.sock', project: 'web');
      expect(pull.argv.last, 'pull');
    });

    test('config lists services, every profile with --profile *', () {
      final services = composeConfig(
        socketPath: '/run/docker.sock',
        project: 'web',
        profiles: const ['*'],
        services: true,
      );
      expect(services.argv.sublist(services.argv.length - 4), [
        '--profile',
        '*',
        'config',
        '--services',
      ]);
      expect(
        () => composeConfig(
          socketPath: '/run/docker.sock',
          project: 'web',
          profiles: const ['a b'],
          services: true,
        ),
        throwsArgumentError,
      );
      expect(parseComposeServiceNames('web\ndb.replica\n\n'), {
        'web',
        'db.replica',
      });
      expect(parseComposeServiceNames('no such file\n'), isNull);
    });

    test('up and pull repeat each recorded env file', () {
      for (final argv in [
        composeUp(
          socketPath: '/run/docker.sock',
          project: 'web',
          envFiles: const ['/opt/web/.env', '/opt/web/prod.env'],
        ).argv,
        composePull(
          socketPath: '/run/docker.sock',
          project: 'web',
          envFiles: const ['/opt/web/.env', '/opt/web/prod.env'],
        ).argv,
      ]) {
        expect(
          argv,
          containsAllInOrder([
            '--env-file',
            '/opt/web/.env',
            '--env-file',
            '/opt/web/prod.env',
          ]),
        );
      }
    });

    test('up recreates and scales only on request, within bounds', () {
      final up = composeUp(
        socketPath: '/run/docker.sock',
        project: 'web',
        forceRecreate: true,
        scale: {'api': 3},
        services: ['api'],
      );
      expect(up.argv.sublist(up.argv.indexOf('up')), [
        'up',
        '-d',
        '--force-recreate',
        '--scale',
        'api=3',
        'api',
      ]);
      for (final bad in [-1, kComposeMaxScale + 1]) {
        expect(
          () => composeUp(
            socketPath: '/run/docker.sock',
            project: 'web',
            scale: {'api': bad},
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => composeUp(
          socketPath: '/run/docker.sock',
          project: 'web',
          scale: {'a pi': 1},
        ),
        throwsArgumentError,
      );
    });

    test('down names every env file', () {
      final down = composeDown(
        socketPath: '/run/docker.sock',
        project: 'web',
        envFiles: ['/srv/a.env', '/srv/b.env'],
      );
      expect(
        down.argv,
        containsAllInOrder([
          '--env-file',
          '/srv/a.env',
          '--env-file',
          '/srv/b.env',
          'down',
        ]),
      );
    });

    test('down never adds -v', () {
      final down = composeDown(socketPath: '/run/docker.sock', project: 'web');
      expect(down.argv, isNot(contains('-v')));
      expect(down.argv.last, 'down');
    });

    test('validates project, service, path and socket', () {
      expect(() => validateComposeProjectName('Web'), throwsArgumentError);
      expect(() => validateComposeProjectName('web-1'), returnsNormally);
      expect(() => validateComposeServiceName('web.replica'), returnsNormally);
      expect(() => validateAbsolutePath('relative'), throwsArgumentError);
      expect(() => validateSocketPath('/run/docker.sock'), returnsNormally);
      expect(
        () => composeRestart(
          socketPath: '/run/docker.sock',
          project: 'web',
          services: const ['bad service'],
        ),
        throwsArgumentError,
      );
    });
  });

  group('compose output parsers (03 §7.16)', () {
    test('parses compose ps NDJSON', () {
      final r = parseComposePsJson(fixtureString('compose-ps-1.55.ndjson'));
      expect(r.warnings, isEmpty);
      expect(r.value, hasLength(3));
      expect(r.value.first.service, 'web');
      expect(r.value.first.health, 'healthy');
      expect(r.value.first.publishers.single.publishedPort, 8080);
    });

    test('parses compose ps as a JSON array', () {
      final r = parseComposePsJson('[{"ID":"a","Service":"web"}]');
      expect(r.value.single.id, 'a');
    });

    test('parses compose config and its hash output', () {
      final r = parseComposeConfig(fixtureJson('compose-config-1.55.json'));
      expect(r.warnings, isEmpty);
      expect(r.value.name, 'web');
      expect(r.value.services['web']!.dependsOn, ['db']);
      expect(r.value.services['db']!.profiles, ['debug']);
      expect(r.value.volumes, ['web_data']);
      expect(r.value.networks, ['default']);
      expect(parseComposeServiceHashes('db 0a1b\nweb.replica 2c3d\n'), {
        'db': '0a1b',
        'web.replica': '2c3d',
      });
      // A bare hash, an empty output and help text are not the shape.
      expect(parseComposeServiceHashes('0a1b\n'), isNull);
      expect(parseComposeServiceHashes(''), isNull);
      expect(parseComposeServiceHashes('Usage: docker compose config'), isNull);
    });

    test('parses compose version', () {
      final r = parseComposeVersion(fixtureJson('compose-version-1.55.json'));
      expect(r.value.version, 'v2.39.1');
      expect(r.value.gitCommit, 'abcdef1');
    });

    test('never throws on malformed parser input', () {
      expect(parseComposePsJson('not json').warnings, isNotEmpty);
      expect(parseComposeConfig(null).warnings, isNotEmpty);
      expect(parseComposeVersion(null).warnings, isNotEmpty);
    });
  });
}
