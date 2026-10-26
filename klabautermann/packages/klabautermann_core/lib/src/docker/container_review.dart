/// DKE-06's security review and DKE-07's log rotation lint over one
/// container's list entry and inspect, before the inspect is masked.
library;

import 'package:klabautermann_docker/klabautermann_docker.dart'
    show ComposeLabels, ContainerInspect, ContainerPort, ContainerSummary;

import '../engine/protocol.dart';

/// The ports database images listen on by default. A port is matched,
/// not an image name: a database built from any image is caught, and a
/// web app named `postgres-admin` is not.
const _databasePorts = {
  1433, // SQL Server
  1521, // Oracle
  3306, // MySQL, MariaDB
  5432, // PostgreSQL
  5984, // CouchDB
  6379, // Redis, Valkey
  7687, // Neo4j Bolt
  8086, // InfluxDB
  9042, // Cassandra, ScyllaDB
  9200, // Elasticsearch, OpenSearch
  11211, // Memcached
  26257, // CockroachDB
  27017, // MongoDB
};

/// The addresses a published port listens on every interface by. The
/// list reports no address for a port published without one on older
/// engines.
const _everyAddress = {'0.0.0.0', '::', ''};

/// The file names of engine sockets: Docker's, Podman's and
/// containerd's. Each gives whoever can write it root on the host.
const _engineSockets = {'docker.sock', 'podman.sock', 'containerd.sock'};

/// The users root runs as: no `User`, its name or uid 0, with or
/// without a group.
final _rootUser = RegExp(r'^(?:root|0)?(?::.*)?$');

/// The findings [inspect] carries, most severe first. [summary] gives
/// its published ports, which the list reports with their addresses.
/// [userMapped] says the engine maps root in a container to an
/// unprivileged host user (rootless, or a user namespace remap), which
/// leaves [ContainerRisk.rootUser] out.
List<ContainerFinding> reviewContainer(
  ContainerSummary summary,
  ContainerInspect inspect, {
  required bool userMapped,
}) {
  final host = inspect.hostConfig;
  final config = inspect.config;
  final compose = ComposeLabels.fromContainerLabels(summary.labels);
  // Built in [ContainerRisk]'s order, which is the severity order.
  return [
    if (host?.privileged ?? false)
      const ContainerFinding(ContainerRisk.privileged),
    for (final mount in inspect.mounts)
      if (mount.type == 'bind' && _isEngineSocket(mount.source))
        ContainerFinding(ContainerRisk.socketMount, detail: mount.source),
    if (host?.networkMode == 'host')
      const ContainerFinding(ContainerRisk.hostNetwork),
    if (host?.pidMode == 'host') const ContainerFinding(ContainerRisk.hostPid),
    if (host != null && host.capAdd.isNotEmpty)
      ContainerFinding(
        ContainerRisk.addedCapabilities,
        detail: host.capAdd.join(', '),
      ),
    for (final port in summary.ports)
      if (_publishedDatabase(port))
        ContainerFinding(ContainerRisk.databasePublished, detail: port.label),
    if (!userMapped && _rootUser.hasMatch(config?.user ?? ''))
      const ContainerFinding(ContainerRisk.rootUser),
    if (host?.logConfig case final log?
        when log.type == 'json-file' && !log.config.containsKey('max-size'))
      const ContainerFinding(ContainerRisk.logsUnrotated),
    if (_floatingTag(config?.image) case final image?)
      ContainerFinding(ContainerRisk.latestTag, detail: image),
    if (config != null &&
        (config.healthcheck.isEmpty || config.healthcheck.first == 'NONE'))
      const ContainerFinding(ContainerRisk.noHealthcheck),
    if (host != null &&
        !host.autoRemove &&
        !(compose?.isOneOff ?? false) &&
        switch (host.restartPolicy?.name) {
          null || '' || 'no' => true,
          _ => false,
        })
      const ContainerFinding(ContainerRisk.noRestartPolicy),
  ];
}

/// The host folders whose bind mount brings the engine sockets in with
/// them.
const _socketFolders = {'/', '/run', '/var/run'};

bool _isEngineSocket(String? path) {
  if (path == null) return false;
  if (_socketFolders.contains(path)) return true;
  return _engineSockets.contains(path.substring(path.lastIndexOf('/') + 1));
}

bool _publishedDatabase(ContainerPort port) =>
    port.publicPort != null &&
    _everyAddress.contains(port.ip ?? '') &&
    _databasePorts.contains(port.privatePort);

/// [image] when it names no tag or digest, or `latest`; null otherwise
/// and for an image id, which pins the image as a digest does.
String? _floatingTag(String? image) {
  if (image == null || image.isEmpty) return null;
  if (image.contains('@') || image.startsWith('sha256:')) return null;
  if (RegExp(r'^[0-9a-f]{12,64}$').hasMatch(image)) return null;

  // A registry's port also has a colon, so the tag is read from the last
  // path segment only.
  final name = image.substring(image.lastIndexOf('/') + 1);
  final colon = name.lastIndexOf(':');
  if (colon < 0) return image;
  return name.substring(colon + 1) == 'latest' ? image : null;
}
