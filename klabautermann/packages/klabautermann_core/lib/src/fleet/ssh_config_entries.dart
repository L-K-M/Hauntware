import 'package:seance_core/seance_core.dart'
    show ImportedHost, SshConfigImporter;

import '../engine/protocol.dart';
import 'jump_routes.dart';

/// The TCP port range; a stored `Port` outside it names no reachable
/// endpoint.
const int _minimumPort = 1;
const int _maximumPort = 65535;

/// The `IdentityFile` that names no key file: ssh skips it in any case
/// (`ssh.c`, `load_public_identity_files()`), and since the config names
/// one, adds no default key file either (`readconf.c`), so only the agent
/// signs.
const String _noIdentityFile = 'none';

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
/// On top of the importer:
///
/// - `%h` in `HostName` becomes the alias, the name ssh is given for the
///   host and for a hop that names it, and `%%` becomes `%` (ssh_config(5),
///   TOKENS). ssh exits on any other token, so such a host is skipped and
///   counted;
/// - `IdentityFile none`, in any case, names no key file, so the host
///   signs in with the agent. A host whose `IdentityFile` holds a `%`
///   token or a `${VAR}` is skipped and counted: ssh fills those in from
///   the connection and the environment (ssh_config(5), TOKENS and
///   ENVIRONMENT VARIABLES), as for `%` in `ProxyJump`;
/// - a host is skipped and counted when an earlier block already took its
///   alias (the alias is the entry's id; ssh would merge the two blocks,
///   this keeps the first), or when [jumpRoutes] cannot follow its
///   `ProxyJump` (a host skipped for any reason counts as left out there).
///
/// The text is parsed in the calling isolate: the engine's, so a large
/// config never stalls the UI (CN-19). Each host carries its effective
/// `HostName` and `Port`, and the list is unmodifiable: the engine stores
/// it as its import state.
({List<ImportedHost> hosts, int skippedCount}) importedHostsFromSshConfig(
  String text,
) {
  final hosts = <ImportedHost>[];
  final aliases = <String>{};
  final refused = <String>{};
  final parsed = SshConfigImporter.parse(text);
  var skipped = parsed.skipped.length;

  for (final host in parsed.hosts) {
    if (!aliases.add(host.alias)) {
      skipped++;
      continue;
    }

    // `HostName=` with no value is as good as absent, and ssh expands
    // only a HostName the config gives.
    final hostName = switch (_nonEmpty(host.hostName)) {
      null => host.alias,
      final written => _expandHostName(written, host.alias),
    };
    final identityFile = switch (_nonEmpty(host.identityFile)) {
      final path? when path.toLowerCase() == _noIdentityFile => null,
      final path => path,
    };
    if (hostName == null ||
        (identityFile != null && !isImportedIdentityFile(identityFile))) {
      skipped++;
      refused.add(host.alias);
      continue;
    }

    hosts.add(
      ImportedHost(
        alias: host.alias,
        hostName: hostName,
        port: host.port ?? kSshDefaultPort,
        user: _nonEmpty(host.user),
        identityFile: identityFile,
        proxyJump: _nonEmpty(host.proxyJump),
      ),
    );
  }

  final routes = jumpRoutes(
    hosts,
    leftOut: {
      ...{
        for (final invalid in parsed.skipped) invalid.host.alias,
      }.difference(aliases),
      ...refused,
    },
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

/// Whether the import keeps [path] as a host's `IdentityFile`: not empty,
/// not `none` in any case (which means no key file), and holding neither
/// a `%` token nor a `${VAR}`, which ssh would expand.
bool isImportedIdentityFile(String path) =>
    path.isNotEmpty &&
    path.toLowerCase() != _noIdentityFile &&
    !path.contains('%') &&
    !path.contains(r'${');

/// ssh's expansion of a `HostName` [value] for [alias] (`ssh.c` calls
/// `percent_expand()` with `h` alone): `%h` is the alias and `%%` is `%`.
/// Null for any other token or a trailing `%`, on which ssh exits.
String? _expandHostName(String value, String alias) {
  final expanded = StringBuffer();
  for (var index = 0; index < value.length; index++) {
    final character = value[index];
    if (character != '%') {
      expanded.write(character);
      continue;
    }

    index++;
    if (index == value.length) return null;
    switch (value[index]) {
      case 'h':
        expanded.write(alias);
      case '%':
        expanded.write('%');
      default:
        return null;
    }
  }
  return expanded.toString();
}

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;
