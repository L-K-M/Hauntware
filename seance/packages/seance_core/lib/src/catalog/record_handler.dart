/// The per-prefix seam of the shared coordinator (03 §4.4;
/// docs/design/catalog-library.md sections 4 and 5): dispatch routes a
/// record by the plaintext prefix of its id before anything is decrypted,
/// and the [RecordHandler] that claims the prefix decides what the record
/// does to the domain stores.
library;

import 'package:seance_protocol/seance_protocol.dart';

import 'catalog_writer.dart';
import 'persistent_record_store.dart';
import 'pin_verdicts.dart';
import 'record_crypto.dart';
import 'sync_tuple.dart';

/// When a handler's records apply within one pass. Records of the
/// [configs] and [pins] phases share the first sweep in `seq` order, the
/// order the cursor rules are written against; [secrets] records apply
/// after that sweep, so the exclusion shield judges them against the
/// pass's final server set (Séance's `_applySecretRecords` order).
enum ApplyPhase { configs, pins, secrets }

/// What one record did. [applied] and [skipped] let the apply cursor
/// advance past the record; [deferred] parks it, and the coordinator keeps
/// the cursor below the lowest deferred `seq`.
enum ApplyOutcome { applied, skipped, deferred }

/// Per-pass state a handler needs, built once per apply pass.
final class ApplyContext {
  const ApplyContext({
    required this.records,
    required this.crypto,
    required this.writer,
    required this.tripwires,
    required this.holdActive,
  });

  final SyncRecordStore records;
  final RecordCrypto crypto;

  /// The write path a handler seals through while applying — an excluded
  /// server's re-dated retraction, an own-device tombstone's revive.
  final CatalogWriter writer;

  /// Strict-decode failures trip here; every applied record clears its id.
  final SyncTripwireStore tripwires;

  /// 04 §4.5's `passphraseUnverified` hold: a decrypt failure under it is
  /// seen-but-deferred, not skipped — the record may simply be sealed under
  /// the passphrase the user has not yet typed right.
  final bool holdActive;

  /// Decrypt for application: a failure means the record is not for this
  /// vault key (or is corrupt ciphertext) — preserved untouched, and NOT
  /// the tripwire (that is decrypt-success + decode-failure).
  Future<DecryptedRecord?> open(EncryptedRecord record) async {
    try {
      return await crypto.open(record);
    } catch (_) {
      return null;
    }
  }
}

/// Per-prefix record semantics (03 §4.4). Unknown prefixes never reach a
/// handler: the coordinator skips them undecrypted.
abstract interface class RecordHandler {
  /// The first id segment before ':'; null claims bare ids (`serverConfig`).
  String? get prefix;

  ApplyPhase get phase;

  /// The kind this prefix's records seal under — tombstone re-seals carry
  /// it, and a live record decrypting to any other kind trips.
  RecordKind get kind;

  /// Whether 04 §4.5's passphrase trial and deferred foreign-record check
  /// may open this prefix's records. A credential prefix must say no: the
  /// never-decrypt dispatch binds the trial too.
  bool get trialDecryptable;

  /// Apply a pulled live record.
  Future<ApplyOutcome> applyLive(EncryptedRecord record, ApplyContext context);

  /// Apply a pulled tombstone. Tombstones carry no sealed kind, so the
  /// prefix alone routes them; a prefix whose tombstones must never strip
  /// local state returns [ApplyOutcome.skipped].
  Future<ApplyOutcome> applyTombstone(
    EncryptedRecord record,
    ApplyContext context,
  );

  /// §3.1's corruption recovery for this prefix: re-seal every materialized
  /// row through [writer] under its persisted winning
  /// `(updatedAt, deviceId)`. Returns the number of materialized tuples
  /// re-sealed.
  Future<int> reSealAfterStoreLoss(CatalogWriter writer);

  /// 04 §4.5's release path for one dirty live [record] that no longer
  /// opens under the verified key: the plaintext record it re-seals as,
  /// keeping the envelope's `(updatedAt, deviceId)` verbatim, or null when
  /// no store can supply it (the record then stays dirty, unreleased).
  Future<DecryptedRecord?> reSourcePending(EncryptedRecord record);
}

/// The substring before the **first** colon — a `hostkey:[2001:db8::1]:22`
/// id contains several, and anything but the first segment would misroute
/// it. Null for a bare id.
String? syncIdPrefix(String id) {
  final colon = id.indexOf(':');
  return colon < 0 ? null : id.substring(0, colon);
}

/// The §3.2 tuple guard, shared by upsert and tombstone: a pulled [record]
/// applies when its envelope tuple outranks the tuple last materialized for
/// its row ([SyncTuple.outranks]), or when nothing is materialized yet.
bool outranksMaterialized(EncryptedRecord record, SyncTuple? materialized) =>
    materialized == null ||
    SyncTuple(
      updatedAt: record.updatedAt,
      deviceId: record.deviceId,
    ).outranks(materialized);
