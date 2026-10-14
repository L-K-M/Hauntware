/// Poltergeist's `bookmark:` records on the shared coordinator
/// (docs/design/catalog-library.md section 5.2): the [RecordHandler] that
/// materializes pulled bookmarks into the bookmark store, and the local
/// writes that seal edited rows through the coordinator's writer. What was
/// the bookmark half of `BookmarkCoordinator`; the payload shape and the
/// store stay product data, not catalog mechanics.
library;

import 'package:seance_core/catalog.dart';
import 'package:seance_core/seance_core.dart';

import 'bookmark_store.dart';

const _bookmarkPrefix = 'bookmark:';

/// Pulled `bookmark:` records apply under the §3.2 tuple guard, and their
/// tombstones honour deletes the same way — a bookmark carries no
/// credential and no trust decision.
final class BookmarkHandler implements RecordHandler {
  BookmarkHandler({required this._bookmarks});

  final SyncTrackingBookmarkStore _bookmarks;

  @override
  String? get prefix => 'bookmark';

  @override
  ApplyPhase get phase => ApplyPhase.configs;

  @override
  RecordKind get kind => RecordKind.bookmark;

  /// A bookmark is no credential: the passphrase trial may open it.
  @override
  bool get trialDecryptable => true;

  @override
  Future<ApplyOutcome> applyLive(
    EncryptedRecord record,
    ApplyContext context,
  ) async {
    final dec = await context.open(record);
    if (dec == null) {
      return context.holdActive ? ApplyOutcome.deferred : ApplyOutcome.skipped;
    }
    if (dec.kind != RecordKind.bookmark) {
      // Decrypt-success + prefix/kind mismatch: the primary in-place
      // corruption signature (04 §3.2's relabeled-secret case).
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    final Bookmark bookmark;
    try {
      // Strict decode — fail loud, never default a malformed field.
      bookmark = Bookmark.fromJson(dec.data, recordId: record.id);
    } catch (_) {
      await context.tripwires.trip(record.id);
      return ApplyOutcome.skipped;
    }
    // It pulled and strict-decoded: lift any past tripwire on this id.
    await context.tripwires.clear(record.id);
    if (!outranksMaterialized(
      record,
      await _bookmarks.syncTupleOf(bookmark.id),
    )) {
      return ApplyOutcome.deferred;
    }
    await _bookmarks.applySyncedRecords([
      (
        bookmark: bookmark,
        winner: BookmarkSyncTuple(
          updatedAt: record.updatedAt,
          deviceId: record.deviceId,
        ),
      ),
    ]);
    return ApplyOutcome.applied;
  }

  @override
  Future<ApplyOutcome> applyTombstone(
    EncryptedRecord record,
    ApplyContext context,
  ) async {
    // The stripped id is exactly the payload id that
    // Bookmark.fromJson(recordId:) validates the envelope against, so a
    // tombstone and a live upsert key the same materialized row.
    final bookmarkId = record.id.substring(_bookmarkPrefix.length);
    if (!outranksMaterialized(
      record,
      await _bookmarks.syncTupleOf(bookmarkId),
    )) {
      return ApplyOutcome.deferred;
    }
    await _bookmarks.removeSyncedRecord(
      bookmarkId,
      BookmarkSyncTuple(
        updatedAt: record.updatedAt,
        deviceId: record.deviceId,
        deleted: true,
      ),
    );
    return ApplyOutcome.applied;
  }

  /// Every materialized tuple re-seals — content and tombstones alike —
  /// under the row's persisted winning authorship.
  @override
  Future<int> reSealAfterStoreLoss(CatalogWriter writer) async {
    final tuples = await _bookmarks.syncTuples();
    final rows = {for (final b in await _bookmarks.load()) b.id: b};
    var resealed = 0;
    for (final entry in tuples.entries) {
      final tuple = entry.value;
      final row = rows[entry.key];
      if (tuple.deleted) {
        await writer.sealLocal(
          DecryptedRecord(
            id: '$_bookmarkPrefix${entry.key}',
            kind: RecordKind.bookmark,
            updatedAt: tuple.updatedAt,
            deviceId: tuple.deviceId,
            deleted: true,
          ),
        );
        resealed++;
      } else if (row != null) {
        await writer.sealLocal(
          DecryptedRecord(
            id: '$_bookmarkPrefix${entry.key}',
            kind: RecordKind.bookmark,
            updatedAt: tuple.updatedAt,
            deviceId: tuple.deviceId,
            data: row.toJson(),
          ),
        );
        resealed++;
      }
    }
    return resealed;
  }

  @override
  Future<DecryptedRecord?> reSourcePending(EncryptedRecord record) async {
    final row = await _bookmarks.byId(
      record.id.substring(_bookmarkPrefix.length),
    );
    if (row == null) return null;
    return DecryptedRecord(
      id: record.id,
      kind: RecordKind.bookmark,
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
      data: row.toJson(),
    );
  }
}

/// Local bookmark writes, sealed through the coordinator's
/// [CatalogWriter.sealLocal] funnel like every other local edit.
extension BookmarkRecordWrites on RecordCoordinator {
  /// A local save: seal the row under the `bookmark:` id with the row's own
  /// stamp and this install's authorship, and mark it dirty for the next
  /// push (04 §3.2 — `deviceId: deviceId`, always).
  Future<void> onBookmarkSaved(Bookmark bookmark) => writer.sealLocal(
    DecryptedRecord(
      id: '$_bookmarkPrefix${bookmark.id}',
      kind: RecordKind.bookmark,
      updatedAt: bookmark.updatedAt.toUtc().millisecondsSinceEpoch,
      deviceId: writer.deviceId,
      data: bookmark.toJson(),
    ),
  );

  /// A local delete: a real tombstone (empty blob, `deleted: true`) dated
  /// at the deletion — fixing the resurrection gap Séance's ephemeral
  /// store has. Tombstones are retained indefinitely: no GC window is safe
  /// while a long-offline device could still push the old row.
  Future<void> onBookmarkDeleted(String bookmarkId) => writer.sealLocal(
    DecryptedRecord(
      id: '$_bookmarkPrefix$bookmarkId',
      kind: RecordKind.bookmark,
      updatedAt: writer.now().toUtc().millisecondsSinceEpoch,
      deviceId: writer.deviceId,
      deleted: true,
    ),
  );
}
