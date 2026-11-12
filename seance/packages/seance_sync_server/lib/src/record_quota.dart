/// Per-record quota arithmetic shared by the storage backends. Not exported:
/// [AccountQuota] and `enforceAccountQuota` are the public surface.
library;

import 'package:seance_protocol/seance_protocol.dart';

import 'storage.dart';

/// Whether moving an account from the before usage to the after usage breaks
/// [quota]. The rule [enforceAccountQuota] applies to a whole batch, and a
/// per-record push applies to each entry in turn.
bool exceedsAccountQuota({
  required int beforeCount,
  required int beforeBytes,
  required int afterCount,
  required int afterBytes,
  required AccountQuota quota,
}) {
  // Existing deployments may already exceed a newly configured cap. Permit a
  // transaction that does not increase an already-over-budget dimension;
  // refusing a smaller replacement would make the account impossible to
  // repair without editing SQLite. Editing existing records leaves the live
  // count equal, which must stay legal for an account over the cap.
  final countRefused =
      afterCount > quota.maxRecords &&
      (beforeCount <= quota.maxRecords || afterCount > beforeCount);
  final bytesRefused =
      afterBytes > quota.maxBytes &&
      (beforeBytes <= quota.maxBytes || afterBytes > beforeBytes);
  return countRefused || bytesRefused;
}

/// An account's record usage as [AccountQuota] measures it.
typedef RecordUsage = ({int count, int bytes});

/// [usage] after [replacement] takes the place of [existing] (null when the
/// id is new). [existingBytes] is what [existing] is accounted at.
RecordUsage usageAfterReplacing(
  RecordUsage usage, {
  required EncryptedRecord? existing,
  required int existingBytes,
  required EncryptedRecord replacement,
}) => (
  count:
      usage.count -
      (existing == null || existing.deleted ? 0 : 1) +
      (replacement.deleted ? 0 : 1),
  bytes: usage.bytes - existingBytes + replacement.encodedJsonBytes(),
);

/// How many times a per-record push offers an entry that does not fit. The
/// first pass runs in list order. The second offers the refused entries again
/// in the room the first pass made, so a deletion frees a slot for a new id
/// whichever comes first in the push: a full account is exactly the one whose
/// owner deletes something and syncs it beside the records that were waiting.
/// A third pass could free nothing, because a deferred entry only ever grows
/// the account.
const perRecordQuotaPasses = 2;
