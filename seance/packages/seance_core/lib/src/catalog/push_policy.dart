/// Whether a `RecordCoordinator` may write to the account (decision D14;
/// docs/design/catalog-library.md sections 4 and 5.1).
library;

/// The push behaviour of one coordinator.
enum PushPolicy {
  /// Today's behaviour: local edits seal through the catalog writer and
  /// every round pushes the dirty set. The pull-only policy D14 needs
  /// arrives with the write-path refusals that make it hold.
  normal,
}
