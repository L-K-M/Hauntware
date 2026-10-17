// The Docker exposure rules (check_docker_exposure.dart; M3 decision M6)
// on rendered Compose JSON, without Docker.
import 'package:test/test.dart';

import 'check_docker_exposure.dart';

const _socket = 'unix:///run/docker-fixture/docker.sock';

/// The fixture's shape as `docker compose config --format json` renders
/// it: dind, and an sshd service sharing its socket volume.
Map<String, Object?> _config({
  Map<String, Object?> dind = const {},
  Map<String, Object?> sshd = const {},
  Map<String, Map<String, Object?>> extra = const {},
}) => {
  'services': {
    'dind': {
      'image': 'mirror.gcr.io/library/docker:29.9.1-dind@sha256:0',
      'privileged': true,
      'command': ['dockerd', '--host=$_socket', '--group=990'],
      'volumes': [
        {
          'type': 'volume',
          'source': 'docker-run',
          'target': '/run/docker-fixture',
        },
      ],
      ...dind,
    },
    'docker-sshd': {
      'image': 'klabautermann-docker-sshd:fixture',
      'volumes': [
        {'type': 'bind', 'source': '/repo/config', 'target': '/etc/ssh/x'},
        {
          'type': 'volume',
          'source': 'docker-run',
          'target': '/run/docker-fixture',
        },
      ],
      'ports': [
        {'target': 22, 'host_ip': '127.0.0.1', 'published': '2244'},
      ],
      ...sshd,
    },
    ...extra,
  },
};

Map<String, Object?> _bind(String source) => {
  'volumes': [
    {'type': 'bind', 'source': source, 'target': '/mnt'},
  ],
};

void main() {
  test('the fixture shape passes', () {
    expect(findDockerExposureErrors(_config()), isEmpty);
  });

  test("the Docker host's negative variants pass", () {
    // Same image and socket volume as the Docker host, ports 2245 to 2250
    // on loopback, neg-restrict's keys bound from the run's directory.
    final variant = {
      'image': 'klabautermann-docker-sshd:fixture',
      'volumes': [
        {
          'type': 'bind',
          'source': '/tmp/klabautermann-fixture.x/authorized_keys.restrict',
          'target': '/run/fixture/authorized_keys',
        },
        {
          'type': 'volume',
          'source': 'docker-run',
          'target': '/run/docker-fixture',
        },
      ],
    };
    expect(
      findDockerExposureErrors(
        _config(
          extra: {
            for (final (name, port) in [
              ('neg-nostreamlocal', 2245),
              ('neg-restrict', 2250),
            ])
              name: {
                ...variant,
                'ports': [
                  {'target': 22, 'host_ip': '127.0.0.1', 'published': '$port'},
                ],
              },
          },
        ),
      ),
      isEmpty,
    );
  });

  test('a config without services fails', () {
    expect(findDockerExposureErrors({}), [
      'rendered config has no services map',
    ]);
  });

  group('engine ports', () {
    for (final port in [2375, 2376]) {
      test('rejects container port $port on loopback too', () {
        final errors = findDockerExposureErrors(
          _config(
            sshd: {
              'ports': [
                {'target': port, 'host_ip': '127.0.0.1', 'published': '9000'},
              ],
            },
          ),
        );
        expect(errors, ['docker-sshd publishes container port $port']);
      });

      test('rejects host port $port', () {
        final errors = findDockerExposureErrors(
          _config(
            sshd: {
              'ports': [
                {'target': 22, 'host_ip': '127.0.0.1', 'published': '$port'},
              ],
            },
          ),
        );
        expect(errors, ['docker-sshd publishes host port $port']);
      });
    }

    test('rejects a host port range that covers one', () {
      final errors = findDockerExposureErrors(
        _config(
          sshd: {
            'ports': [
              {'target': 22, 'host_ip': '127.0.0.1', 'published': '2370-2375'},
            ],
          },
        ),
      );
      expect(errors, ['docker-sshd publishes host port 2375']);
    });
  });

  group('host sockets', () {
    for (final source in [
      '/var/run/docker.sock',
      '/run/docker.sock',
      '/home/user/.docker/run/docker.sock',
      '/var/run',
      '/run/',
      '/var',
      '/',
      '/run/user',
      '/run/user/',
      '/run/user/1000',
      '/run/user/1000/tmp',
      '/var/run/user/1000',
    ]) {
      test('rejects a bind of $source', () {
        final errors = findDockerExposureErrors(_config(sshd: _bind(source)));
        expect(errors, [
          'docker-sshd binds the host path $source, which is or holds '
              'docker.sock',
        ]);
      });
    }

    test('accepts other binds and a named volume at /var/run', () {
      final config = _config(
        sshd: {
          'volumes': [
            {'type': 'bind', 'source': '/var/runner', 'target': '/a'},
            {'type': 'bind', 'source': '/run/fixture/keys', 'target': '/b'},
            {'type': 'volume', 'source': 'docker-run', 'target': '/var/run'},
          ],
        },
      );
      expect(findDockerExposureErrors(config), isEmpty);
    });

    for (final device in <Object>[
      {
        'source': '/var/run/docker.sock',
        'target': '/var/run/docker.sock',
        'permissions': 'rwm',
      },
      {'source': '/run/user/1000/docker.sock', 'target': '/y'},
      '/run/docker.sock:/run/docker.sock:rwm',
    ]) {
      test('rejects a device mapping of $device', () {
        final errors = findDockerExposureErrors(
          _config(
            sshd: {
              'devices': [device],
            },
          ),
        );
        expect(errors, hasLength(1));
        expect(errors.single, startsWith('docker-sshd maps the host device '));
      });
    }

    test('accepts other devices', () {
      final config = _config(
        sshd: {
          'devices': [
            {
              'source': '/dev/fuse',
              'target': '/dev/fuse',
              'permissions': 'rwm',
            },
            '/dev/null:/dev/x',
          ],
        },
      );
      expect(findDockerExposureErrors(config), isEmpty);
    });
  });

  group('privileged', () {
    test('rejects it outside dind', () {
      final errors = findDockerExposureErrors(
        _config(sshd: {'privileged': true}),
      );
      expect(errors, ['docker-sshd runs privileged outside dind']);
    });

    test('accepts a Podman service', () {
      final config = _config(
        extra: {
          'podman': {'image': 'quay.io/podman/stable', 'privileged': true},
        },
      );
      expect(findDockerExposureErrors(config), isEmpty);
    });
  });

  group('the dind command', () {
    test('rejects none, which leaves the entrypoint its TCP default', () {
      final errors = findDockerExposureErrors(_config(dind: {'command': null}));
      expect(errors, [
        'dind does not name dockerd as its command, so the dind entrypoint '
            'adds a TCP listener',
      ]);
    });

    test('rejects options only, which the entrypoint extends', () {
      final errors = findDockerExposureErrors(
        _config(
          dind: {
            'command': ['--host=$_socket'],
          },
        ),
      );
      expect(errors, hasLength(1));
      expect(errors.single, contains('does not name dockerd'));
    });

    test('rejects dockerd without --host', () {
      final errors = findDockerExposureErrors(
        _config(
          dind: {
            'command': ['dockerd', '--group=990'],
          },
        ),
      );
      expect(errors, ['dind runs dockerd without an explicit --host']);
    });

    for (final spelling in [
      ['--host=tcp://0.0.0.0:2375'],
      ['--host', 'tcp://127.0.0.1:2375'],
      ['-H', 'fd://'],
      ['-H=tcp://0.0.0.0:2376'],
      ['-Htcp://0.0.0.0:2375'],
    ]) {
      test('rejects a non-Unix host given as ${spelling.join(' ')}', () {
        final errors = findDockerExposureErrors(
          _config(
            dind: {
              'command': ['dockerd', '--host=$_socket', ...spelling],
            },
          ),
        );
        expect(errors, hasLength(1));
        expect(errors.single, contains('not a Unix socket'));
      });
    }

    test('applies to a dind image under another service name', () {
      final config = _config(
        extra: {
          'engine': {'image': 'docker:dind', 'privileged': false},
        },
      );
      expect(findDockerExposureErrors(config), [
        'engine does not name dockerd as its command, so the dind '
            'entrypoint adds a TCP listener',
      ]);
    });
  });
}
