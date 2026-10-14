/// The LWW authorship tuple the catalog stores persist per row (04 §3.2).
/// Moved from Poltergeist's bookmark store, where it was
/// `BookmarkSyncTuple`; its members and JSON shape are unchanged.
library;

/// The LWW authorship tuple of the record last materialized into a store
/// for a row — the winning envelope's `(updatedAt, deviceId)` (04 §3.2).
/// Persisted per id alongside the rows, including `deleted` tombstone
/// tuples for rows that are gone: the coordinator's apply pass compares a
/// pulled record against this tuple, and a tombstone tuple is what stops a
/// stale live record resurrecting a just-deleted row before the tombstone
/// record has pushed.
final class SyncTuple {
  const SyncTuple({
    required this.updatedAt,
    required this.deviceId,
    this.deleted = false,
  });

  /// Milliseconds since epoch — the record envelope's `updatedAt`.
  final int updatedAt;

  /// The record envelope's `deviceId`. [fromJson] also accepts an empty id,
  /// which marks the authorship as unknown: an empty id loses every deviceId
  /// tie-break, so a re-pulled copy of the same write still applies.
  final String deviceId;

  /// True when the materialized state is a deletion: the row is absent and
  /// this tuple is what a pulled live record must out-tuple to resurrect.
  final bool deleted;

  @override
  bool operator ==(Object other) =>
      other is SyncTuple &&
      other.updatedAt == updatedAt &&
      other.deviceId == deviceId &&
      other.deleted == deleted;

  @override
  int get hashCode => Object.hash(updatedAt, deviceId, deleted);

  Map<String, dynamic> toJson() => {
    'updatedAt': updatedAt,
    'deviceId': deviceId,
    if (deleted) 'deleted': true,
  };

  static SyncTuple? fromJson(Object? json) {
    if (json is! Map) return null;
    final updatedAt = json['updatedAt'];
    final deviceId = json['deviceId'];
    if (updatedAt is! num || deviceId is! String) return null;
    return SyncTuple(
      updatedAt: updatedAt.toInt(),
      deviceId: deviceId,
      deleted: json['deleted'] == true,
    );
  }
}
