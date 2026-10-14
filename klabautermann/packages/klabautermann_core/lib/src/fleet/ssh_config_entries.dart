import 'package:seance_core/seance_core.dart'
    show ImportedHost, SshConfigImporter;

import '../engine/protocol.dart';
import 'jump_routes.dart';

/// The TCP port range; a stored `Port` outside it names no reachable
/// endpoint.
const int _minimumPort = 1;
const int _maximumPort = 65535;

/// Reads an OpenSSH client config's [text] into the hosts FL-02 imports,
/// through Séance's `SshConfigImporter`, so Klabautermann reads a config
/// exactly as Séance does. What the importer does, and so what this does:
///
/// - one host per name a `Host` line gives, with its block's settings:
///   `Host a b` makes `a` and `b`. Wildcard and negated patterns are not
///   names, so blocks such as `Host *` describe defaults, not hosts, and
///   are dropped (their defaults are not applied to other hosts);
/// - `HostName`, `Port`, `User`, `IdentityFile` and `ProxyJump` are read,
///   a missing `HostName` falls back to the alias as ssh does, and every
///   other directive is ignored;
/// - `Match` blocks are ignored, and `Include` is not followed: the importer
///   drops the directive and the engine opens no file, so hosts defined only
///   in an included file are not imported;
/// - `Port` is a decimal 1 to 65535 or the service name `ssh`, `http` or
///   `https`; a block with any other `Port` is skipped and its hosts are
///   counted. ssh rejects the whole config over such a `Port`, unless it is
///   another service name ssh resolves.
///
/// On top of the importer, a host is skipped and counted when an earlier
/// block already took its alias (the alias is the entry's id; ssh would
/// merge the two blocks, this keeps the first), or when [jumpRoutes]
/// cannot follow its `ProxyJump` (a host the importer skipped counts as
/// left out there). The text is parsed in the calling isolate: the
/// engine's, so a large config never stalls the UI (CN-19). Each host
/// carries its effective `HostName` and `Port`, and the list is
/// unmodifiable: the engine stores it as its import state.
({List<ImportedHost> hosts, int skippedCount}) importedHostsFromSshConfig(
  String text,
) {
  final hosts = <ImportedHost>[];
  final aliases = <String>{};
  final parsed = SshConfigImporter.parse(text);
  var skipped = parsed.skipped.length;

  for (final host in parsed.hosts) {
    if (!aliases.add(host.alias)) {
      skipped++;
      continue;
    }

    hosts.add(
      ImportedHost(
        alias: host.alias,
        // `HostName=` with no value is as good as absent.
        hostName: _nonEmpty(host.hostName) ?? host.alias,
        port: host.port ?? kSshDefaultPort,
        user: _nonEmpty(host.user),
        identityFile: _nonEmpty(host.identityFile),
        proxyJump: _nonEmpty(host.proxyJump),
      ),
    );
  }

  final routes = jumpRoutes(
    hosts,
    leftOut: {
      for (final refused in parsed.skipped) refused.host.alias,
    }.difference(aliases),
  );
  final followed = [
    for (final host in hosts)
      if (routes[host.alias] != null) host,
  ];
  return (
    hosts: List.unmodifiable(followed),
    skippedCount: skipped + hosts.length - followed.length,
  );
}

/// Whether [port] is in the TCP port range, so it can name an endpoint.
bool isTcpPort(int port) => port >= _minimumPort && port <= _maximumPort;

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;
