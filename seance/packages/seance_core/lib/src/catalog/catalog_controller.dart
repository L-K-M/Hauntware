/// 04 §3.2's server catalog: the in-memory materialization of pulled
/// `serverConfig` records, present only in shared mode (§4.2). It owns no
/// file — the `RecordCoordinator` rebuilds it from the server store after
/// every apply pass, so a tombstone or a config edit Séance pushed lands on
/// the next round without any cache-invalidation bookkeeping.
///
/// Constructed and held only by the coordinator (not exported by
/// `package:seance_core/catalog.dart`); apps read it as a
/// [CatalogSnapshot].
library;

import 'package:seance_protocol/seance_protocol.dart';

import 'catalog_snapshot.dart';
import 'server_order.dart';

/// The writable side of the catalog: [CatalogSnapshot] plus [replace] and
/// the change notification. `servers` is replaced wholesale by the
/// coordinator's rebuild; consumers hold no reference into it.
final class CatalogController implements CatalogSnapshot {
  CatalogController({void Function(List<ServerConfig> snapshot)? onReplaced})
    : // The public collaborator name stays readable; its field is private.
      // ignore: prefer_initializing_formals
      _onReplaced = onReplaced;

  final void Function(List<ServerConfig> snapshot)? _onReplaced;
  List<ServerConfig> _servers = const [];

  @override
  List<ServerConfig> get servers => _servers;

  @override
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
