// The Docker exposure rules for the fixture's rendered Compose config
// (03 §11.3; M3 decision M6). run.sh pipes `docker compose config --format
// json` here after Poltergeist's checker, which rejects host networking
// and ports published beyond loopback. These rules reject what would make
// a Docker engine reachable from the host or its network:
//
// - a published 2375 or 2376, the engine's TCP ports, on any address;
// - a bind mount or device of a host docker.sock, of a directory that
//   holds one, or of a rootless engine's /run/user tree;
// - `privileged` on any service but dind (and a Podman one, 03 §11.3);
// - a dind service whose command does not run dockerd with an explicit,
//   Unix-only --host: with no command, or with options only, the dind
//   image's entrypoint adds a TCP listener on 2375 or 2376;
// - a registry service that publishes a port or leaves the default
//   Compose network: the fixture's registry speaks plain HTTP and serves
//   that network only (M4 E27), and dind may trust no other registry over
//   plain HTTP;
// - a sync service (M5 plan M08a) that publishes anything but its one
//   port on loopback, mounts a volume, or keeps its storage on disk: it
//   is Séance's sync server with open registration, for the fixture's
//   convergence suite only.
import 'dart:convert';
import 'dart:io';

/// The Docker engine's plain and TLS TCP ports.
const _engineTcpPorts = {2375, 2376};

/// The services that may run privileged: Docker in Docker and a rootful
/// Podman service.
const _privilegedServices = {'dind', 'podman'};

/// Where a host keeps its Docker socket: `/var/run` is `/run` on most
/// hosts, but not on every one.
const _hostSockets = ['/var/run/docker.sock', '/run/docker.sock'];

/// Where rootless engines keep their sockets: `/run/user/<uid>/docker.sock`.
/// The uid varies, so the whole tree counts as holding a socket.
const _rootlessSocketRoots = ['/var/run/user', '/run/user'];

const _socketName = 'docker.sock';
const _dindService = 'dind';
const _registryService = 'registry';
const _syncService = 'sync';

/// The port the sync server listens on in its container.
const _syncPort = 8787;
const _loopback = '127.0.0.1';

/// The one registry dind may reach over plain HTTP: the fixture's, by its
/// Compose service name.
const _fixtureRegistry = 'registry:5000';
const _dockerd = 'dockerd';
const _unixScheme = 'unix://';

/// Finds Docker exposure paths in rendered Compose JSON.
List<String> findDockerExposureErrors(Map<String, Object?> config) {
  final services = config['services'];
  if (services is! Map) {
    return ['rendered config has no services map'];
  }

  final errors = <String>[];
  for (final MapEntry(:key, :value) in services.entries) {
    final name = '$key';
    if (value is! Map) {
      errors.add('$name is not a service map');
      continue;
    }

    errors
      ..addAll(_portErrors(name, value['ports']))
      ..addAll(_bindErrors(name, value['volumes']))
      ..addAll(_deviceErrors(name, value['devices']));
    if (value['privileged'] == true && !_privilegedServices.contains(name)) {
      errors.add('$name runs privileged outside dind');
    }
    if (name == _dindService || '${value['image']}'.contains('dind')) {
      errors
        ..addAll(_dindCommandErrors(name, value['command']))
        ..addAll(_insecureRegistryErrors(name, value['command']));
    }
    if (name == _registryService || _isRegistryImage('${value['image']}')) {
      errors.addAll(_registryErrors(name, value));
    }
    if (name == _syncService) errors.addAll(_syncErrors(name, value));
  }
  return errors;
}

Iterable<String> _portErrors(String name, Object? ports) sync* {
  // Poltergeist's checker reports ports that are not normalized.
  if (ports is! List) return;
  for (final port in ports) {
    if (port is! Map) continue;
    final target = int.tryParse('${port['target']}');
    if (_engineTcpPorts.contains(target)) {
      yield '$name publishes container port $target';
    }
    final published = _portRange('${port['published'] ?? ''}');
    for (final engine in _engineTcpPorts) {
      if (published.contains(engine)) yield '$name publishes host port $engine';
    }
  }
}

/// The ports [text] names: one (`2244`), a range (`2244-2250`), or none.
Iterable<int> _portRange(String text) {
  final bounds = text.split('-').map(int.tryParse).toList();
  return switch (bounds) {
    [final int port] => [port],
    [final int first, final int last] when first <= last => [
      for (var port = first; port <= last; port++) port,
    ],
    _ => const [],
  };
}

Iterable<String> _bindErrors(String name, Object? volumes) sync* {
  if (volumes is! List) return;
  for (final volume in volumes) {
    if (volume is! Map) {
      yield '$name has an unnormalized volume: $volume';
      continue;
    }
    if (volume['type'] != 'bind') continue;
    final source = '${volume['source']}';
    if (_holdsHostSocket(source)) {
      yield '$name binds the host path $source, which is or holds '
          '$_socketName';
    }
  }
}

/// `devices:` hands a service a host path just as a bind does. Compose
/// renders each entry as a map with a `source`; the short `src:dst:perms`
/// string form is handled too.
Iterable<String> _deviceErrors(String name, Object? devices) sync* {
  if (devices is! List) return;
  for (final device in devices) {
    final source = device is Map
        ? '${device['source']}'
        : '$device'.split(':').first;
    if (_holdsHostSocket(source)) {
      yield '$name maps the host device $source, which is or holds '
          '$_socketName';
    }
  }
}

bool _holdsHostSocket(String source) {
  final path = source.length > 1 && source.endsWith('/')
      ? source.substring(0, source.length - 1)
      : source;
  if (path == '/' || path.split('/').last == _socketName) return true;
  if (_rootlessSocketRoots.any(
    (root) => path == root || path.startsWith('$root/'),
  )) {
    return true;
  }
  return _hostSockets.any(
    (socket) => socket == path || socket.startsWith('$path/'),
  );
}

Iterable<String> _dindCommandErrors(String name, Object? command) sync* {
  if (command is! List || command.isEmpty || command.first != _dockerd) {
    yield '$name does not name $_dockerd as its command, so the dind '
        'entrypoint adds a TCP listener';
    return;
  }

  final hosts = _hostOptions([for (final argument in command) '$argument']);
  if (hosts.isEmpty) {
    yield '$name runs $_dockerd without an explicit --host';
  }
  for (final host in hosts) {
    if (!host.startsWith(_unixScheme)) {
      yield '$name runs $_dockerd with --host $host, not a Unix socket';
    }
  }
}

/// dockerd's `--insecure-registry` values other than the fixture's own.
Iterable<String> _insecureRegistryErrors(String name, Object? command) sync* {
  if (command is! List) return;
  final arguments = [for (final argument in command) '$argument'];
  for (var i = 1; i < arguments.length; i++) {
    final argument = arguments[i];
    final String registry;
    if (argument == '--insecure-registry') {
      registry = i + 1 < arguments.length ? arguments[++i] : '';
    } else if (argument.startsWith('--insecure-registry=')) {
      registry = argument.substring('--insecure-registry='.length);
    } else {
      continue;
    }
    if (registry != _fixtureRegistry) {
      yield '$name trusts $registry over plain HTTP, not only '
          '$_fixtureRegistry';
    }
  }
}

/// A registry that is reachable beyond the Compose network.
Iterable<String> _registryErrors(
  String name,
  Map<Object?, Object?> service,
) sync* {
  if (service['ports'] case final List ports when ports.isNotEmpty) {
    yield '$name publishes a port; the fixture registry stays on the '
        'Compose network';
  }
  if (service['network_mode'] != null) {
    yield '$name sets network_mode; the fixture registry stays on the '
        'Compose network';
  }
  // The rendered config names every service's networks, `default` alone
  // when the file names none.
  if (service['networks'] case final Map networks) {
    final others = [
      for (final network in networks.keys)
        if (network != 'default') network,
    ];
    if (others.isNotEmpty) {
      yield '$name joins ${others.join(', ')}; the fixture registry stays '
          'on the default Compose network';
    }
  }
}

/// Whether [image] is the registry image, from a mirror or spelled bare.
bool _isRegistryImage(String image) =>
    image.contains('/registry:') || image.startsWith('registry:');

/// The values of dockerd's `--host`/`-H` options in [arguments], in each
/// spelling its flag parser accepts.
List<String> _hostOptions(List<String> arguments) {
  final hosts = <String>[];
  for (var i = 1; i < arguments.length; i++) {
    final argument = arguments[i];
    if (argument == '--host' || argument == '-H') {
      hosts.add(i + 1 < arguments.length ? arguments[++i] : '');
    } else if (argument.startsWith('--host=')) {
      hosts.add(argument.substring('--host='.length));
    } else if (argument.startsWith('-H=')) {
      hosts.add(argument.substring('-H='.length));
    } else if (argument.startsWith('-H')) {
      hosts.add(argument.substring('-H'.length));
    }
  }
  return hosts;
}

Future<void> main() async {
  final input = await stdin.transform(utf8.decoder).join();

  Object? decoded;
  try {
    decoded = jsonDecode(input);
  } on FormatException catch (error) {
    stderr.writeln('invalid rendered Compose JSON: $error');
    exitCode = 2;
    return;
  }

  if (decoded is! Map<String, Object?>) {
    stderr.writeln('rendered Compose config is not an object');
    exitCode = 2;
    return;
  }

  final errors = findDockerExposureErrors(decoded);
  if (errors.isEmpty) {
    stdout.writeln('Docker exposure check passed.');
    return;
  }

  for (final error in errors) {
    stderr.writeln('unsafe Compose config: $error');
  }
  exitCode = 1;
}

Iterable<String> _syncErrors(String name, Map<Object?, Object?> service) sync* {
  final ports = service['ports'];
  for (final port in ports is List ? ports : const []) {
    if (port is! Map) continue;
    if ('${port['target']}' != '$_syncPort') {
      yield '$name publishes container port ${port['target']}';
    }
    if (port['host_ip'] != _loopback) {
      yield '$name publishes beyond loopback';
    }
  }
  final volumes = service['volumes'];
  if (volumes is List && volumes.isNotEmpty) yield '$name mounts a volume';
  final environment = service['environment'];
  if (environment is Map &&
      '${environment['SEANCE_DB_PATH'] ?? ''}'.isNotEmpty) {
    yield '$name keeps its storage on disk';
  }
}
