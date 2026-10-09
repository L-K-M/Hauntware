/// 04 §3.2's `SeanceServerCatalog`: the in-memory, read-only
/// materialization of pulled `serverConfig` records, present only in
/// shared mode (§4.2). It owns no file — [BookmarkCoordinator] rebuilds it
/// from the persistent record store on every `applyPulled`, so a tombstone
/// or a config edit Séance pushed lands on the next round without any
/// cache-invalidation bookkeeping.
library;

import 'package:seance_core/seance_core.dart';

import 'server_order.dart';

/// A read-only view over the Séance servers visible to the shared account.
/// `servers` is replaced wholesale by the coordinator's rebuild; consumers
/// hold no reference into it.
final class SeanceServerCatalog {
  SeanceServerCatalog({
    void Function(List<ServerConfig> snapshot)? onReplaced,
  }) : // The public collaborator name stays readable; its field is private.
       // ignore: prefer_initializing_formals
       _onReplaced = onReplaced;

  final void Function(List<ServerConfig> snapshot)? _onReplaced;
  List<ServerConfig> _servers = const [];

  /// The pulled Séance server configs, sorted by label for display. The
  /// list is unmodifiable and identity-stable between [replace] calls.
  List<ServerConfig> get servers => _servers;

  /// The config [id] resolves to, or null when the catalog has no such
  /// record — the answer a `serverConfigId` reference needs before a
  /// connect may dial anything.
  ServerConfig? byId(String id) {
    for (final server in _servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  /// Swap in a fresh materialization — the coordinator calls this after
  /// diffing the store's prefixless records on each apply pass. The optional
  /// publisher runs synchronously after assignment, so a consumer can order
  /// the new routing snapshot before any connection reads it.
  void replace(Iterable<ServerConfig> servers) {
    final snapshot = List<ServerConfig>.unmodifiable(
      servers.toList()..sort(compareServersByLabel),
    );
    _servers = snapshot;
    _onReplaced?.call(snapshot);
  }
}
