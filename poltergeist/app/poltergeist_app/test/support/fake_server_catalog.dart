import 'package:poltergeist_core/poltergeist_core.dart';

/// A scriptable [CatalogSnapshot] for widget tests. In the app only the
/// sync coordinator materializes the catalog; here [replace] stands in for
/// its rebuild, with the same label-then-id order and unmodifiable list.
final class FakeServerCatalog implements CatalogSnapshot {
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

  void replace(Iterable<ServerConfig> servers) {
    _servers = List.unmodifiable(
      servers.toList()..sort((a, b) {
        final byLabel = a.label.toLowerCase().compareTo(b.label.toLowerCase());
        return byLabel != 0 ? byLabel : a.id.compareTo(b.id);
      }),
    );
  }
}
