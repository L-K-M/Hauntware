import 'package:seance_core/seance_core.dart' show ImportedHost;

import 'jump_routes.dart';
import 'ssh_config_settings.dart';

/// Reads an OpenSSH client config's [text] into the hosts FL-02 imports,
/// each with the settings ssh would use for it ([SshConfigSettings]), and
/// the settings of every other name their routes give.
///
/// - Each name a `Host` line gives is one host, in the order the names
///   first appear (`Host a b` makes `a` and `b`, as Séance's
///   `SshConfigImporter` reads it). Wildcard and negated patterns name no
///   host, so a block such as `Host *` only sets values for the hosts it
///   matches, and an alias's later blocks only add what its earlier ones
///   left unset. Hosts defined only in an included file are not
///   imported, since `Include` is not followed.
/// - Each host carries its effective `HostName` (`%h` expanded, and
///   lowercased unless it is an address), `Port`, `User`, first
///   `IdentityFile` and `ProxyJump`. A name with no `HostName` is its
///   own address, as in ssh, and `IdentityFile none` names no key file.
/// - ssh reaches a hop with a nested ssh that reads the config for the
///   hop's name, so each name a route gives that is no alias is resolved
///   the same way into a hop record, which [jumpRoutes] reads.
/// - A host is left out and counted when [SshConfigSettings] cannot
///   resolve it or [jumpRoutes] cannot follow its route: one ssh would
///   take through a `ProxyCommand`, a `Match` or `Include` the engine
///   cannot evaluate, a `HostName` or `IdentityFile` token, or a line ssh
///   rejects, all of which apply to the hops it names too.
///
/// The text is parsed in the calling isolate: the engine's, so a large
/// config never stalls the UI (CN-19). Both lists are unmodifiable, in
/// file order and in the order the routes first name them: the engine
/// stores them as its import state. The hop records are only those a
/// kept host's route reaches.
({List<ImportedHost> hosts, List<ImportedHost> hops, int skippedCount})
importedHostsFromSshConfig(String text) {
  final config = SshConfigSettings.parse(text);
  final aliases = config.aliases.toSet();
  final leftOut = <String>{};
  final hosts = <ImportedHost>[];
  for (final alias in config.aliases) {
    switch (config.resolve(alias)) {
      case ResolvedSshSettings(:final host):
        hosts.add(host);
      case UnresolvedSshSettings():
        leftOut.add(alias);
    }
  }

  // Every name a route gives that no Host line does, through the hop
  // records' own routes too.
  final hops = <String, ImportedHost>{};
  final named = [...hosts];
  for (var index = 0; index < named.length; index++) {
    for (final name in _hopNames(named[index])) {
      if (aliases.contains(name) ||
          leftOut.contains(name) ||
          hops.containsKey(name)) {
        continue;
      }
      switch (config.resolve(name)) {
        case ResolvedSshSettings(:final host):
          hops[name] = host;
          named.add(host);
        case UnresolvedSshSettings():
          leftOut.add(name);
      }
    }
  }

  final routes = jumpRoutes(
    hosts,
    hops: hops.values.toList(),
    leftOut: leftOut,
  );
  final followed = [
    for (final host in hosts)
      if (routes[host.alias] != null) host,
  ];

  // The hop records the kept hosts' routes reach.
  final reached = <String, ImportedHost>{};
  final reaching = [...followed];
  for (var index = 0; index < reaching.length; index++) {
    for (final name in _hopNames(reaching[index])) {
      final hop = hops[name];
      if (hop == null || reached.containsKey(name)) continue;

      reached[name] = hop;
      reaching.add(hop);
    }
  }
  return (
    hosts: List.unmodifiable(followed),
    hops: List.unmodifiable(reached.values),
    skippedCount: config.aliases.length - followed.length,
  );
}

/// The names [host]'s `ProxyJump` gives; none when it has none or the
/// engine cannot read it.
List<String> _hopNames(ImportedHost host) => switch (host.proxyJump) {
  null => const [],
  final value => proxyJumpHosts(value) ?? const [],
};
