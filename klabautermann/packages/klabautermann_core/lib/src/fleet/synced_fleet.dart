import 'package:seance_core/catalog.dart' show EndpointPin;
import 'package:seance_core/seance_core.dart'
    show AuthMethod, ServerConfig, serverSearchHaystack;

import '../engine/protocol.dart';

/// The most jump hops a synced route lists, as Séance's connector refuses
/// a longer route (03 §10.1).
const int _maxRouteHops = 16;

/// The servers the sync account holds as the engine lists and dials them
/// (03 §4.3, §4.7, §10.1), in the catalog's order. Read-only in the MVP
/// (D14). A synced server is dialed only while its endpoint is confirmed
/// on this device (SAF-09): its pin matches its host, port, user and jump
/// route, and each jump host on that route matches its own pin, since a
/// connect through a hop hands that hop a credential too. Every other
/// synced server is listed with what the fleet rail and the confirmation
/// list need, and no config.
final class SyncedFleet {
  SyncedFleet._(
    this.entries,
    this._byId,
    this._routes,
    this._pins,
    this._unreadable,
    this.confirmedIds,
    this.unreadableIds,
  );

  /// Lists [servers] against the endpoints this device confirmed, [pins]
  /// by server id. [unreadable] names the servers whose pins the store
  /// could not read: they count as unpinned, so nothing dials them, but
  /// a server behind or at one is in [unreadableIds].
  factory SyncedFleet(
    List<ServerConfig> servers, {
    Map<String, EndpointPin> pins = const {},
    Set<String> unreadable = const {},
  }) {
    final byId = {for (final server in servers) server.id: server};
    final routes = {
      for (final server in servers) server.id: _routeIds(server, byId),
    };

    bool matchesPin(ServerConfig server) => switch (pins[server.id]) {
      null => false,
      final pin =>
        pin.host == server.host &&
            pin.port == server.port &&
            pin.username == server.username &&
            _sameIds(pin.jumpRouteIds, routes[server.id]!),
    };

    // A hop the account does not hold cannot be dialed through, so the
    // connect fails without reaching anything; the server's pin decides.
    EndpointConfirmation confirmation(ServerConfig server) {
      if (!pins.containsKey(server.id)) return EndpointConfirmation.unconfirmed;

      final hopsMatch = routes[server.id]!.every(
        (id) => byId[id] == null || matchesPin(byId[id]!),
      );
      return matchesPin(server) && hopsMatch
          ? EndpointConfirmation.confirmed
          : EndpointConfirmation.changed;
    }

    final states = {
      for (final server in servers) server.id: confirmation(server),
    };
    return SyncedFleet._(
      List.unmodifiable([
        for (final server in servers)
          FleetEntry(
            serverId: server.id,
            label: server.label,
            host: server.host,
            port: server.port,
            user: server.username.isEmpty ? null : server.username,
            group: server.group,
            origin: FleetEntryOrigin.synced,
            jumpRoute: _jumpRoute(server, routes[server.id]!, byId),
            authKind: switch (server.authMethod) {
              AuthMethod.agent => FleetAuthKind.agent,
              AuthMethod.password => FleetAuthKind.password,
              AuthMethod.privateKey when server.identityFilePath != null =>
                FleetAuthKind.identityFile,
              AuthMethod.privateKey => FleetAuthKind.storedKey,
            },
            searchText: serverSearchHaystack(server),
            endpoint: states[server.id],
          ),
      ]),
      byId,
      routes,
      Map.unmodifiable(pins),
      Set.unmodifiable(unreadable),
      Set.unmodifiable({
        for (final MapEntry(key: id, value: state) in states.entries)
          if (state == EndpointConfirmation.confirmed) id,
      }),
      Set.unmodifiable({
        for (final server in servers)
          if (unreadable.contains(server.id) ||
              routes[server.id]!.any(unreadable.contains))
            server.id,
      }),
    );
  }

  /// No synced servers: not enrolled, or nothing pulled yet.
  static final SyncedFleet empty = SyncedFleet(const []);

  /// The synced servers in catalog order, each with its
  /// [FleetEntry.endpoint].
  final List<FleetEntry> entries;

  final Map<String, ServerConfig> _byId;

  /// Each server's jump route by server id, first hop first.
  final Map<String, List<String>> _routes;

  final Map<String, EndpointPin> _pins;

  /// The ids whose pins the store could not read.
  final Set<String> _unreadable;

  /// The servers whose endpoints are confirmed, the only ones dialed.
  final Set<String> confirmedIds;

  /// The servers whose own pin, or a jump host's on their route, the
  /// store could not read, so whether their endpoint changed is unknown.
  /// None is in [confirmedIds].
  final Set<String> unreadableIds;

  /// Whether the account holds the server [id].
  bool lists(String id) => _byId.containsKey(id);

  /// The config of the synced server or jump host [id] while its endpoint
  /// is confirmed; null otherwise, so nothing dials it. Safe because a
  /// sync never drops a pin: a changed server leaves [confirmedIds] while
  /// its old pin stays, and [pinsFor] never replaces a hop's pin.
  ServerConfig? serverConfig(String id) =>
      confirmedIds.contains(id) ? _byId[id] : null;

  /// Why a connect to the synced server [id] cannot start, or null when it
  /// can or the account does not hold it.
  ConnectRejectedReason? missingConfigReason(String id) =>
      lists(id) && !confirmedIds.contains(id)
      ? ConnectRejectedReason.endpointNotConfirmed
      : null;

  /// The pins that confirm the servers [ids] as they stand now, stamped
  /// [now] (D64): one per listed server, and one per jump host on its
  /// route that this device never confirmed. A hop confirmed before keeps
  /// its pin: when a sync changed it, it waits for its own confirmation,
  /// so confirming a server behind it never accepts the hop's new
  /// endpoint unseen. A hop whose pin the store could not read counts as
  /// pinned, for the same reason. Ids the account does not hold, and servers no pin
  /// can describe (an empty host or hop id, a port out of range), are
  /// skipped.
  List<EndpointPin> pinsFor(Iterable<String> ids, DateTime now) {
    final pins = <String, EndpointPin>{};
    void add(String id) {
      final server = _byId[id];
      if (server == null || pins.containsKey(id)) return;
      try {
        pins[id] = EndpointPin(
          serverId: id,
          host: server.host,
          port: server.port,
          username: server.username,
          jumpRouteIds: _routes[id]!,
          confirmedAt: now,
        );
      } on ArgumentError {
        // No pin can hold it, so it stays unconfirmed and undialed.
      }
    }

    for (final id in ids) {
      if (!lists(id)) continue;
      add(id);
      for (final hop in _routes[id]!) {
        if (!_pins.containsKey(hop) && !_unreadable.contains(hop)) add(hop);
      }
    }
    return List.unmodifiable(pins.values);
  }

  /// The ids of [server]'s jump hosts, first hop first, by following each
  /// `jumpHostId` back. A hop the account does not hold ends the route,
  /// and one that loops ends with the id that closes the loop, so a
  /// server naming itself still has a route; neither passes
  /// [_maxRouteHops].
  static List<String> _routeIds(
    ServerConfig server,
    Map<String, ServerConfig> byId,
  ) {
    final hops = <String>[];
    final seen = {server.id};
    var next = server.jumpHostId;
    while (next != null && hops.length < _maxRouteHops) {
      hops.add(next);
      if (!seen.add(next)) break;
      next = byId[next]?.jumpHostId;
    }
    return List.unmodifiable(hops.reversed);
  }

  /// The labels of the hops [route] names, first hop first, a hop the
  /// account does not hold by its id; null for a direct server, so a
  /// broken route never reads as direct. A loop's closing id, first in
  /// [route], names the server or a hop already listed, so it is left
  /// out unless it is all the route holds.
  static List<String>? _jumpRoute(
    ServerConfig server,
    List<String> route,
    Map<String, ServerConfig> byId,
  ) {
    if (route.isEmpty) return null;

    final looped =
        route.first == server.id || route.skip(1).contains(route.first);
    final hops = looped && route.length > 1 ? route.skip(1) : route;
    return List.unmodifiable([for (final id in hops) byId[id]?.label ?? id]);
  }

  static bool _sameIds(List<String> a, List<String> b) {
    if (a.length != b.length) return false;

    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
