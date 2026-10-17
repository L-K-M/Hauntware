import 'dart:convert';

import 'package:klabautermann_docker/klabautermann_docker.dart';
import 'package:test/test.dart';

import '../harness.dart';

Object? fixtureJson(String name) => jsonDecode(fixtureString(name));

void main() {
  group('container list', () {
    test('parses the 1.44 shape with health, ports and mounts', () {
      final r = parseContainerSummaries(fixtureJson('containers-1.44.json'));
      expect(r.warnings, isEmpty);
      expect(r.value, hasLength(4));

      final web = r.value.first;
      expect(web.name, 'web-1');
      expect(web.state, 'running');
      expect(web.health, HealthStatus.healthy);
      expect(web.image, 'nginx:1.27');
      expect(web.ports, hasLength(2));
      expect(web.ports.first.label, '0.0.0.0:8080->80/tcp');
      expect(web.ports[1].label, '443/tcp');
      expect(web.mounts, hasLength(1));
      expect(web.mounts.first.name, 'web_data');
      expect(web.mounts.first.rw, isTrue);
      expect(web.networks['web_default'], '172.18.0.2');
      expect(web.networkMode, 'web_default');

      final labels = web.labels;
      expect(labels['com.docker.compose.project']!.display, 'web');
      expect(labels['com.docker.compose.project']!.isMasked, isFalse);

      expect(r.value[1].health, isNull);
      expect(r.value[2].health, HealthStatus.unhealthy);
      expect(r.value[3].name, 'loose-db');
    });

    test('parses the 1.41 shape without mounts', () {
      final r = parseContainerSummaries(fixtureJson('containers-1.41.json'));
      expect(r.warnings, isEmpty);
      expect(r.value, hasLength(1));
      expect(r.value.first.mounts, isEmpty);
      expect(r.value.first.health, isNull);
      expect(r.value.first.name, 'old-web');
    });

    test('reads the 1.52 Health object before the status text', () {
      final r = parseContainerSummaries(fixtureJson('containers-1.52.json'));
      expect(r.warnings, isEmpty);
      expect(r.value.map((c) => c.health), [
        HealthStatus.healthy,
        HealthStatus.unhealthy,
        HealthStatus.none,
        HealthStatus.none,
        HealthStatus.none,
      ]);

      final disagreeing = parseContainerSummaries([
        {
          'Id': 'a',
          'Status': 'Up 1 minute (healthy)',
          'Health': {'Status': 'unhealthy'},
        },
        {
          'Id': 'b',
          'Status': 'Up 1 minute (unhealthy)',
          'Health': {'Status': 'bogus'},
        },
      ]);
      expect(disagreeing.value.first.health, HealthStatus.unhealthy);
      // An unknown Health.Status falls back to the status text.
      expect(disagreeing.value.last.health, HealthStatus.unhealthy);
    });

    test('parses the Podman compat shape', () {
      final r = parseContainerSummaries(
        fixtureJson('containers-podman-1.44.json'),
      );
      expect(r.warnings, isEmpty);
      expect(r.value, hasLength(1));
      expect(r.value.first.ports.first.publicPort, 9090);
      expect(
        r.value.first.labels['io.podman.systemd_unit']!.display,
        'podweb.service',
      );
    });

    test('never throws on malformed daemon input', () {
      expect(parseContainerSummaries(null).warnings, isNotEmpty);
      expect(parseContainerSummaries(const <Object?>[42]).warnings, isNotEmpty);
      final wrongTypes = parseContainerSummaries([
        {'Id': 7, 'Ports': 'nope', 'Labels': []},
      ]);
      expect(wrongTypes.value.single.id, '');
      expect(wrongTypes.warnings, isNotEmpty);
    });
  });

  group('container inspect', () {
    test('parses state, health and masked env and labels', () {
      final r = parseContainerInspect(
        fixtureJson('container-inspect-1.44.json'),
      );
      expect(r.warnings, isEmpty);
      final c = r.value;
      expect(c.id, startsWith('9f8e'));
      expect(c.name, 'web-1');
      expect(c.tty, isFalse);
      expect(c.state!.running, isTrue);
      expect(c.state!.pid, 4242);
      expect(c.state!.health!.status, HealthStatus.healthy);
      expect(c.state!.health!.log, hasLength(1));
      expect(c.state!.health!.log.first.exitCode, 0);
      expect(c.restartCount, 0);
      expect(c.hostConfig!.logConfig!.type, 'json-file');
      expect(c.hostConfig!.restartPolicy!.name, 'unless-stopped');
      expect(c.hostConfig!.memory, 536870912);
      expect(c.mounts.single.destination, '/data');
      expect(
        c.networkSettings!.networks['web_default']!.ipAddress,
        '172.18.0.2',
      );

      final env = {for (final e in c.config!.env) e.name: e.value};
      expect(env['POSTGRES_PASSWORD']!.isMasked, isTrue);
      expect(env['POSTGRES_PASSWORD']!.reveal(), 'hunter2');
      expect(env['POSTGRES_PASSWORD']!.toString(), MaskedValue.maskToken);
      expect(env['APP_MODE']!.isMasked, isFalse);
      expect(env['APP_MODE']!.display, 'production');
      expect(env['DATABASE_URL']!.isMasked, isTrue);

      final labels = c.config!.labels;
      expect(labels['API_TOKEN=not-a-key-name']!.isMasked, isTrue);
      expect(labels['API_TOKEN=not-a-key-name']!.reveal(), 'value');
      expect(labels['org.opencontainers.image.title']!.display, 'web');
    });

    test('never throws on a non-object inspect', () {
      expect(parseContainerInspect(null).warnings, isNotEmpty);
      expect(parseContainerInspect('nope').value.id, '');
    });
  });

  group('helpers', () {
    test('healthFromStatus reads the list status text', () {
      expect(healthFromStatus('Up 2 hours (healthy)'), HealthStatus.healthy);
      expect(
        healthFromStatus('Up 2 hours (unhealthy)'),
        HealthStatus.unhealthy,
      );
      expect(
        healthFromStatus('Up 2 seconds (health: starting)'),
        HealthStatus.starting,
      );
      expect(healthFromStatus('Up 2 hours'), isNull);
      expect(healthFromStatus(null), isNull);
    });

    test('swarmServiceNameHint parses dotted task names defensively', () {
      expect(swarmServiceNameHint('web.1.abcdefghijklmnopqrstuvwxy'), 'web');
      expect(swarmServiceNameHint('web.3'), 'web');
      expect(swarmServiceNameHint('plain-name'), isNull);
      expect(swarmServiceNameHint(null), isNull);
    });

    test('parseEnv masks secrets and handles bare keys', () {
      final env = parseEnv(['A=1', 'MY_TOKEN=x', 'BARE']);
      expect(env[0].name, 'A');
      expect(env[0].value.isMasked, isFalse);
      expect(env[1].value.isMasked, isTrue);
      expect(env[2].name, 'BARE');
      expect(env[2].value.display, '');
    });

    test('parseEnv redacts URL credentials under a plain key', () {
      final env = parseEnv(['ENDPOINT=https://user:pw@example.test/x']);
      expect(env.single.value.isMasked, isTrue);
      expect(env.single.value.display, contains(MaskedValue.maskToken));
      expect(env.single.value.reveal(), 'https://user:pw@example.test/x');
    });
  });
}
