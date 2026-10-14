/// Whether a `RecordCoordinator` may write to the account (decision D14;
/// docs/design/catalog-library.md sections 4 and 5.1).
library;

/// The push behaviour of one coordinator.
enum PushPolicy {
  /// Pull-only (D14, 03 §4.4 "Pull-only mode"): rounds pull and apply,
  /// and nothing is sealed, written to the catalog, published or pushed.
  /// Every mutating `CatalogWriter` call refuses before touching a store,
  /// `CatalogWriter.sealLocal` refuses before `crypto.seal`, and a round
  /// skips its push half.
  none,

  /// Local edits seal through the catalog writer and every round pushes
  /// the dirty set — Poltergeist's behaviour.
  normal,
}
