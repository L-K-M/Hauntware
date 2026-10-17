import 'dart:convert';

import 'package:seance_core/seance_core.dart'
    show AuthMethod, ImportedHost, ServerConfig, serverSearchHaystack;

import '../engine/protocol.dart';
import 'jump_routes.dart';

/// Prefixes an imported host's alias to form its [FleetEntry.serverId].
/// Synced ids are bare UUIDs, so the two can never collide; import ids are
/// device-local and never become record ids.
const String importIdPrefix = 'ssh-config:';

/// The variables [localUserName] reads, in order.
const List<String> _userVariables = ['USER', 'USERNAME'];

/// One imported host with its route and the config the engine maps it to.
typedef _Mapped = ({
  ImportedHost host,
  List<JumpHop> route,
  ServerConfig config,
});

/// How much of each host's config an import holds.
enum ImportedHostDetail {
  /// All the engine maps: a fresh import, or a schema 3 store, which keeps
  /// the values ssh would use for each host and hop.
  full,

  /// Alias, address, port and user only: a store of an older schema,
  /// which kept no `IdentityFile` or `ProxyJump` (1) or read each host's
  /// values from its first block alone (2). Whether a host signs in with
  /// a key or sits behind a jump host is unknown, so its entry names
  /// neither and it gets no config until the next import.
  addressOnly,
}

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
  ImportedFleet._(this.entries, this._configs, this._endpoints, this._detail);

  /// Maps [hosts], in order, through the hop records [hops], logging in
  /// as [localUser] wherever a host or hop names no user. A host whose
  /// `ProxyJump` [jumpRoutes] cannot follow is left out; the import never
  /// stores one. Hosts with [ImportedHostDetail.addressOnly] are listed,
  /// but with no route, sign-in, conflict or config.
  factory ImportedFleet(
    List<ImportedHost> hosts, {
    List<ImportedHost> hops = const [],
    String? localUser,
    ImportedHostDetail detail = ImportedHostDetail.full,
  }) {
    final full = detail == ImportedHostDetail.full;
    // Without detail no route is claimed, so no locator conflicts either.
    final routes = full
        ? jumpRoutes(hosts, hops: hops)
        : {for (final host in hosts) host.alias: const <JumpHop>[]};
    final configs = <String, ServerConfig>{};

    // Each config, keyed by its id, dialed through the hop [through]. One
    // whose login name is unknown, or whose route has such a hop, gets
    // none: a connect cannot start. A hop has a config only when every
    // hop before it has one, so checking [through] covers the route.
    ServerConfig config(String id, ImportedHost host, JumpHop? through) {
      final user = host.user ?? localUser;
      // Séance's mapping: an IdentityFile is a key read from its path,
      // otherwise the agent signs.
      final mapped = host
          .toServerConfig(id: id, now: 0)
          .copyWith(username: user ?? '', jumpHostId: through?.id);
      if (full &&
          user != null &&
          (through == null || configs.containsKey(through.id))) {
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
          index == 0 ? null : route[index - 1],
        );
      }
      mapped.add((
        host: host,
        route: route,
        config: config('$importIdPrefix${host.alias}', host, route.lastOrNull),
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
            authKind: switch ((full, config.authMethod)) {
              (false, _) => null,
              (true, AuthMethod.privateKey) => FleetAuthKind.identityFile,
              (true, _) => FleetAuthKind.agent,
            },
            searchText: serverSearchHaystack(config),
            locatorConflict: conflicts[index],
          ),
      ]),
      configs,
      {
        for (final (:host, :route, :config) in mapped)
          config.id: jsonEncode([
            for (final hop in route)
              [hop.host, hop.port, hop.user ?? localUser],
            [config.host, config.port, host.user ?? localUser],
          ]),
      },
      detail,
    );
  }

  /// The imported hosts in import order, with every field filled.
  final List<FleetEntry> entries;

  final Map<String, ServerConfig> _configs;

  final Map<String, String> _endpoints;

  final ImportedHostDetail _detail;

  /// The config of an imported host (`ssh-config:<alias>`) or a jump hop
  /// (`ssh-config-hop:...`); null for any other id, for a host or hop with
  /// no login name ([localUserName] found none) or behind such a hop, and
  /// for every host with [ImportedHostDetail.addressOnly].
  ServerConfig? serverConfig(String id) => _configs[id];

  /// What a connect to the imported host [id] reaches, to compare across
  /// imports: the address, port and login name of each hop and then of
  /// the host (03 §4.7's endpoint, with each hop by its address). Null for
  /// an id the fleet does not list.
  String? endpointOf(String id) => _endpoints[id];

  /// Why the imported host [id] has no [serverConfig], so a connect to it
  /// cannot start: an address-only store, or no login name for the host
  /// or a hop on its route, the only other reason a listed host lacks
  /// one. Null when it has a config or the fleet does not list it.
  ConnectRejectedReason? missingConfigReason(String id) {
    if (_configs.containsKey(id) || !_endpoints.containsKey(id)) return null;
    return switch (_detail) {
      ImportedHostDetail.addressOnly => ConnectRejectedReason.addressOnlyImport,
      ImportedHostDetail.full => ConnectRejectedReason.noLoginName,
    };
  }

  /// For each of [mapped], the ids of the others that pin a host key at
  /// one of its pin locators (`host:port`, 03 §4.6) behind another route,
  /// or null. Séance checks every hop's host key under its own locator, so
  /// an entry pins each hop, behind the hops before it, and the server,
  /// behind all of them. Routes compare by each hop's `host:port`: the
  /// same jump host as another user is the same route. Grouping the pins
  /// by locator and route keeps this linear in the entries and the ids it
  /// lists.
  static List<List<String>?> _locatorConflicts(List<_Mapped> mapped) {
    final pins = [
      for (final (host: _, :route, :config) in mapped)
        [
          for (final (index, hop) in route.indexed)
            (locator: (hop.host, hop.port), route: _routeKey(route, index)),
          (
            locator: (config.host, config.port),
            route: _routeKey(route, route.length),
          ),
        ],
    ];

    // Each locator, each route to it, and the entries that pin it so.
    final pinned = <(String, int), Map<String, Set<int>>>{};
    for (final (index, own) in pins.indexed) {
      for (final (:locator, :route) in own) {
        ((pinned[locator] ??= {})[route] ??= {}).add(index);
      }
    }

    return [
      for (final (index, own) in pins.indexed)
        _nonEmpty([
          for (final other in ({
            for (final (:locator, :route) in own)
              for (final MapEntry(key: theirs, value: others)
                  in pinned[locator]!.entries)
                if (theirs != route) ...others,
          }..remove(index)).toList()..sort())
            mapped[other].config.id,
        ]),
    ];
  }

  /// The first [length] hops of [route] by `host:port`, as one comparable
  /// key.
  static String _routeKey(List<JumpHop> route, int length) => jsonEncode([
    for (final hop in route.take(length)) [hop.host, hop.port],
  ]);

  static List<String>? _nonEmpty(List<String> ids) =>
      ids.isEmpty ? null : List.unmodifiable(ids);
}
