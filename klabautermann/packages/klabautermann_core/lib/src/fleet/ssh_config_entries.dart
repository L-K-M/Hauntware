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
///   cannot evaluate, a final pass that a system config may ask for, a
///   `HostName` or `IdentityFile` token, or a line ssh rejects, all of
///   which apply to the hops it names too. Where only that final pass
///   changes a name's settings, and it would give the name a route ssh
///   refuses ([loopingRoutes]: a jumphost loop, or a route through the
///   name itself), ssh cannot be taking that pass for it, so the name
///   keeps its first pass's settings.
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

  // Each alias and every name a route gives, through the hop records' own
  // routes and either pass's, with what ssh would use for it.
  final resolved = <String, SshConfigResolution>{};
  final names = [...config.aliases];
  final seen = {...names};
  for (var index = 0; index < names.length; index++) {
    final resolution = resolved[names[index]] = config.resolve(names[index]);
    final settings = switch (resolution) {
      ResolvedSshSettings(:final host) => [host],
      UnresolvedSshSettings(:final passes?) => [
        passes.firstPass,
        passes.finalPass,
      ],
      UnresolvedSshSettings() => const <ImportedHost>[],
    };
    for (final name in settings.expand(_hopNames)) {
      if (seen.add(name)) names.add(name);
    }
  }

  // The hosts, the hop records and the names left out, with the settings
  // [pick] gives each name, or null.
  ({List<ImportedHost> hosts, List<ImportedHost> hops, Set<String> leftOut})
  split(ImportedHost? Function(SshConfigResolution) pick) {
    final settings = {
      for (final name in names)
        if (pick(resolved[name]!) case final host?) name: host,
    };
    return (
      hosts: [for (final alias in config.aliases) ?settings[alias]],
      hops: [
        for (final name in names)
          if (!aliases.contains(name)) ?settings[name],
      ],
      leftOut: {
        for (final name in names)
          if (!settings.containsKey(name)) name,
      },
    );
  }

  // With the final pass that /etc/ssh/ssh_config may ask for, a name
  // whose route ssh would refuse cannot be taking that pass, so it keeps
  // its first pass's settings.
  final finalPass = split(
    (resolution) => switch (resolution) {
      ResolvedSshSettings(:final host) => host,
      UnresolvedSshSettings(:final passes?) => passes.finalPass,
      UnresolvedSshSettings() => null,
    },
  );
  final looping = loopingRoutes(
    finalPass.hosts,
    hops: finalPass.hops,
    leftOut: finalPass.leftOut,
  );
  final (:hosts, :hops, :leftOut) = split(
    (resolution) => switch (resolution) {
      ResolvedSshSettings(:final host) => host,
      UnresolvedSshSettings(:final passes?)
          when looping.contains(passes.firstPass.alias) =>
        passes.firstPass,
      UnresolvedSshSettings() => null,
    },
  );
  final routes = jumpRoutes(hosts, hops: hops, leftOut: leftOut);
  final followed = [
    for (final host in hosts)
      if (routes[host.alias] != null) host,
  ];

  // The hop records the kept hosts' routes reach.
  final records = {for (final hop in hops) hop.alias: hop};
  final reached = <String, ImportedHost>{};
  final reaching = [...followed];
  for (var index = 0; index < reaching.length; index++) {
    for (final name in _hopNames(reaching[index])) {
      final hop = records[name];
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
