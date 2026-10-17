import 'package:seance_core/seance_core.dart'
    show AuthMethod, ServerConfig, serverSearchHaystack;

import '../engine/protocol.dart';

/// The most jump hops a synced route lists, as Séance's connector refuses
/// a longer route (03 §10.1).
const int _maxRouteHops = 16;

/// The fleet entries of the servers the sync account holds (03 §4.3,
/// §10.1), in the catalog's order. Read-only in the MVP (D14), and not yet
/// connect targets: a synced server dials only once its endpoint is
/// confirmed on this device (03 §4.7, K41), so the engine gives them no
/// config and lists them with what the fleet rail and the confirmation
/// list need.
List<FleetEntry> syncedFleetEntries(List<ServerConfig> servers) {
  final byId = {for (final server in servers) server.id: server};
  return List.unmodifiable([
    for (final server in servers)
      FleetEntry(
        serverId: server.id,
        label: server.label,
        host: server.host,
        port: server.port,
        user: server.username.isEmpty ? null : server.username,
        group: server.group,
        origin: FleetEntryOrigin.synced,
        jumpRoute: _jumpRoute(server, byId),
        authKind: switch (server.authMethod) {
          AuthMethod.agent => FleetAuthKind.agent,
          AuthMethod.password => FleetAuthKind.password,
          AuthMethod.privateKey when server.identityFilePath != null =>
            FleetAuthKind.identityFile,
          AuthMethod.privateKey => FleetAuthKind.storedKey,
        },
        searchText: serverSearchHaystack(server),
      ),
  ]);
}

/// The labels of [server]'s jump hosts, first hop first, by following each
/// `jumpHostId` back; null for a direct server. A hop the account does not
/// hold is listed by its id, and a route that loops or passes
/// [_maxRouteHops] stops there, so a broken route never reads as direct.
List<String>? _jumpRoute(ServerConfig server, Map<String, ServerConfig> byId) {
  final hops = <String>[];
  final seen = {server.id};
  var next = server.jumpHostId;
  while (next != null && hops.length < _maxRouteHops && seen.add(next)) {
    final hop = byId[next];
    hops.add(hop?.label ?? next);
    next = hop?.jumpHostId;
  }
  // A server that names itself as its jump host adds no hop above, yet
  // its route is broken, not direct.
  if (hops.isEmpty) {
    return server.jumpHostId == null ? null : List.unmodifiable([server.label]);
  }
  return List.unmodifiable(hops.reversed);
}
