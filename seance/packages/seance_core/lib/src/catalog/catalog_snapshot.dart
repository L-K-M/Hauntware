/// The read-only server catalog apps consume (docs/design/catalog-library.md
/// section 4): the public half of what was Poltergeist's
/// `SeanceServerCatalog`. No mutator and no change registration reach an
/// app; the `RecordCoordinator` that materializes it holds the only
/// writable handle.
library;

import 'package:seance_protocol/seance_protocol.dart';

/// The Séance servers visible to the shared account, as the coordinator
/// last materialized them (04 §4.2).
abstract interface class CatalogSnapshot {
  /// The pulled Séance server configs, sorted by label for display. The
  /// list is unmodifiable and identity-stable between rebuilds.
  List<ServerConfig> get servers;

  /// The config [id] resolves to, or null when the catalog has no such
  /// record — the answer a `serverConfigId` reference needs before a
  /// connect may dial anything.
  ServerConfig? byId(String id);
}
