import 'dart:convert';

import 'package:seance_core/seance_core.dart'
    show AuthMethod, ImportedHost, ServerConfig, serverSearchHaystack;

import '../engine/protocol.dart';
import 'jump_routes.dart';

/// Prefixes an imported host's alias to form its [FleetEntry.serverId].
/// Synced ids are bare UUIDs, so the two can never collide; import ids are
/// device-local and never become record ids.
const String _importIdPrefix = 'ssh-config:';

/// The variables [localUserName] reads, in order.
const List<String> _userVariables = ['USER', 'USERNAME'];

/// One imported host with its route and the config the engine maps it to.
typedef _Mapped = ({
  ImportedHost host,
  List<JumpHop> route,
  ServerConfig config,
});

/// The login name for an imported host or hop whose config names no
/// user: `USER` (macOS, Linux) or else `USERNAME` (Windows) in
/// [environment]; null when neither holds one. ssh takes the account's
/// passwd entry instead, which Dart cannot read portably.
String? localUserName(Map<String, String> environment) {
  for (final name in _userVariables) {
    final value = environment[name];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// The FL-02 imports as the engine lists and connects to them (03 §4.6,
/// §10.1): one [FleetEntry] and one `ServerConfig` per host, and a
/// `ServerConfig` per jump hop, so a link can hand [serverConfig] to
/// `CredentialResolver.jumpHostResolver`. Built from what the import store
/// holds; nothing here crosses the isolate boundary but [entries].
final class ImportedFleet {
  ImportedFleet._(this.entries, this._configs);

  /// Maps [hosts], in order, logging in as [localUser] wherever a host or
  /// hop names no user. A host whose `ProxyJump` [jumpRoutes] cannot
  /// follow is left out; the import never stores one.
  factory ImportedFleet(List<ImportedHost> hosts, {String? localUser}) {
    final routes = jumpRoutes(hosts);
    final configs = <String, ServerConfig>{};

    // Each config, keyed by its id. One whose login name is unknown, or
    // whose route has such a hop, gets none: a connect cannot start.
    ServerConfig config(String id, ImportedHost host, List<JumpHop> route) {
      final user = host.user ?? localUser;
      // Séance's mapping: an IdentityFile is a key read from its path,
      // otherwise the agent signs.
      final mapped = host
          .toServerConfig(id: id, now: 0)
          .copyWith(username: user ?? '', jumpHostId: route.lastOrNull?.id);
      if (user != null && route.every((hop) => configs.containsKey(hop.id))) {
        configs[id] = mapped;
      }
      return mapped;
    }

    final mapped = <_Mapped>[];
    for (final host in hosts) {
      final route = routes[host.alias];
      if (route == null) continue;

      for (final (index, hop) in route.indexed) {
        config(
          hop.id,
          ImportedHost(
            alias: hop.name,
            hostName: hop.host,
            port: hop.port,
            user: hop.user,
            identityFile: hop.identityFile,
          ),
          route.sublist(0, index),
        );
      }
      mapped.add((
        host: host,
        route: route,
        config: config('$_importIdPrefix${host.alias}', host, route),
      ));
    }

    final conflicts = _locatorConflicts(mapped);
    return ImportedFleet._(
      List.unmodifiable([
        for (final (index, (:host, :route, :config)) in mapped.indexed)
          FleetEntry(
            serverId: config.id,
            label: host.alias,
            host: config.host,
            port: config.port,
            // What the config names; [localUserName] fills in only the
            // ServerConfig.
            user: host.user,
            origin: FleetEntryOrigin.sshConfig,
            jumpRoute: route.isEmpty
                ? null
                : List.unmodifiable([for (final hop in route) hop.name]),
            authKind: config.authMethod == AuthMethod.privateKey
                ? FleetAuthKind.identityFile
                : FleetAuthKind.agent,
            searchText: serverSearchHaystack(config),
            locatorConflict: conflicts[index],
          ),
      ]),
      configs,
    );
  }

  /// The imported hosts in import order, with every field filled.
  final List<FleetEntry> entries;

  final Map<String, ServerConfig> _configs;

  /// The config of an imported host (`ssh-config:<alias>`) or a jump hop
  /// (`ssh-config-hop:...`); null for any other id, and for a host or hop
  /// with no login name ([localUserName] found none) or behind such a hop.
  ServerConfig? serverConfig(String id) => _configs[id];

  /// For each of [mapped], the ids of the others at the same host-key pin
  /// locator (`host:port`, 03 §4.6) behind another route, or null. Routes
  /// compare by each hop's `host:port`: the same jump host as another user
  /// is the same route.
  static List<List<String>?> _locatorConflicts(List<_Mapped> mapped) {
    final routes = [
      for (final (host: _, :route, :config) in mapped)
        (
          locator: (config.host, config.port),
          route: jsonEncode([
            for (final hop in route) [hop.host, hop.port],
          ]),
        ),
    ];
    return [
      for (final (index, own) in routes.indexed)
        _nonEmpty([
          for (final (other, theirs) in routes.indexed)
            if (other != index &&
                theirs.locator == own.locator &&
                theirs.route != own.route)
              mapped[other].config.id,
        ]),
    ];
  }

  static List<String>? _nonEmpty(List<String> ids) =>
      ids.isEmpty ? null : List.unmodifiable(ids);
}
