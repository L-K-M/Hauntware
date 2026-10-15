import 'package:klabautermann_core/klabautermann_core.dart';

/// A Debian login user in `sudo` but not `systemd-journal` or `docker`,
/// with sudo asking for a password and a rootful Docker socket the user
/// cannot write.
HostProfile debianHost() => HostProfile.fromJson({
  'uid': 1000,
  'user': 'alice',
  'groups': ['alice', 'sudo'],
  'distroId': 'debian',
  'systemdDir': true,
  'systemdVersion': 252,
  'sudoKind': 'sudo',
  'sudoNonInteractive': false,
  'tools': {
    'journalctl': '/usr/bin/journalctl',
    'dmesg': '/usr/bin/dmesg',
    'tail': '/usr/bin/tail',
    'crontab': '/usr/bin/crontab',
    'docker': '/usr/bin/docker',
  },
  'engineSockets': [
    {'path': '/var/run/docker.sock', 'exists': true, 'writable': false},
    {'path': '/run/user/1000/docker.sock', 'exists': false, 'writable': false},
  ],
  'areaStatuses': {'identity': 'ok', 'sockets': 'ok', 'tools': 'ok'},
});

/// An Alpine container logged in as root: no systemd, no journal, and a
/// rootless Podman socket. [tools] overrides the probed tools by name.
HostProfile alpineContainer({Map<String, String?> tools = const {}}) =>
    HostProfile.fromJson({
      'uid': 0,
      'user': 'root',
      'groups': ['root'],
      'distroId': 'alpine',
      'systemdDir': false,
      'sudoKind': 'none',
      'doasPresent': false,
      'tools': {
        'journalctl': null,
        'dmesg': null,
        'tail': '/usr/bin/tail',
        'crontab': '/usr/bin/crontab',
        'docker': null,
        'podman': '/usr/bin/podman',
        ...tools,
      },
      'engineSockets': [
        {
          'path': '/run/user/0/podman/podman.sock',
          'exists': true,
          'writable': true,
        },
      ],
      'areaStatuses': {'identity': 'ok', 'sockets': 'ok', 'tools': 'ok'},
    });
