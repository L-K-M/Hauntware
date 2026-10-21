/// The server editor's save rules, shared by every app that edits a
/// [ServerConfig] (docs/design/ghost-servers-part2.md section 3, F5a-1a):
/// which credential a Save writes, when that needs the stored entry, and
/// the `updatedAt` stamp. Séance and Poltergeist each carried an identical
/// copy in their editors; the Klabautermann engine plans its saves with the
/// same rules.
library;

import 'dart:math' show max;

import 'secret.dart';
import 'server_config.dart';

/// The credential this Save writes, or null when the form describes none and
/// the stored one should stay as it is.
///
/// Blank means "keep what is stored" when every box of that method is blank:
/// the fields start empty when an existing server is opened, so writing a
/// blank through would replace the stored credential with nothing on any save
/// that only touched some other field.
///
/// Not box by box, though, and the passphrase is where that shows: a *typed*
/// PEM writes `keyPassphrase: null` even when the passphrase box is blank,
/// because a newly pasted key brings its own — so re-pasting the same
/// encrypted key and leaving the passphrase alone drops the stored one.
///
/// Known gap, pre-existing and not closed here: when the auth *method*
/// changed and nothing was typed, "what is stored" is a credential of the old
/// kind. Nothing is written, so the config keeps its `secretRef` — now
/// pointing at, say, a password under a server set to key auth, until a
/// credential for the new method is entered. Clearing the ref instead would
/// throw away a working credential on a method switch the user may undo in
/// the same sitting, which is the worse of the two. `docs/STATUS.md`
/// follow-up 17 tracks it.
///
/// A *referenced* key is the case this exists for. Its passphrase is the only
/// credential that mode has, and it used to be dropped — the box was shown,
/// filled and ignored — so `Test connection`, which authenticates with what
/// was typed, reported success for a key the saved server could not decrypt.
/// [stored] is carried through when one is written, because switching to a
/// referenced file leaves an already-stored PEM unread rather than discarded,
/// and switching back has to find it again.
Secret? plannedCredential({
  required AuthMethod auth,
  required bool referenceKeyFile,
  required String password,
  required String keyPem,
  required String keyPassphrase,
  required String secretId,
  Secret? stored,
}) {
  if (auth == AuthMethod.password) {
    if (password.isEmpty) return null;
    return Secret(id: secretId, kind: SecretKind.password, value: password);
  }
  if (auth != AuthMethod.privateKey) return null;
  if (!referenceKeyFile) {
    if (keyPem.isEmpty) return null;
    return Secret(
      id: secretId,
      kind: SecretKind.privateKey,
      value: keyPem,
      keyPassphrase: keyPassphrase.isEmpty ? null : keyPassphrase,
    );
  }
  if (keyPassphrase.isEmpty) return null;
  return Secret(
    id: secretId,
    kind: SecretKind.privateKey,
    // The key itself stays on disk; only what decrypts it is stored. What is
    // carried over has to be a key: the entry under this id belongs to
    // whatever auth method last wrote it, and a server that used a password
    // before would otherwise have that password stored as its PEM — read back
    // as one the next time the key is typed rather than referenced.
    value: stored?.kind == SecretKind.privateKey ? stored!.value : '',
    // The typed passphrase belongs to the key *file*, and it lands beside the
    // PEM carried above — which was stored with a passphrase of its own. One
    // entry holds one passphrase, so the pair can end up mismatched, and
    // switching back to a pasted key without re-pasting finds a PEM that no
    // longer decrypts. Carrying the old passphrase instead would break the
    // referenced key, which is the one the server is set to use. STATUS
    // follow-up 17 has both halves of the single-slot problem.
    keyPassphrase: keyPassphrase,
  );
}

/// Whether [plannedCredential] will read [stored], so a caller knows when it
/// has to fetch the existing vault entry first.
///
/// The condition lives here rather than being restated at the call site: read
/// too narrowly, `stored` arrives null on a branch that carries it through and
/// an existing PEM is overwritten with nothing — the data loss the carry-over
/// exists to prevent. A test fuzzes the two together: wherever this is false,
/// [plannedCredential] must return the same thing with and without a [Secret]
/// in hand.
bool plannedCredentialReadsStored({
  required AuthMethod auth,
  required bool referenceKeyFile,
  required String keyPassphrase,
}) =>
    auth == AuthMethod.privateKey &&
    referenceKeyFile &&
    keyPassphrase.isNotEmpty;

/// The timestamp a save should carry: the wall clock, but never one this
/// config has already passed.
///
/// `updatedAt` is what orders this edit against every other device's, and a
/// device whose clock trails the record it pulled — the ordinary case once one
/// device runs even slightly fast — would otherwise stamp an edit that ties
/// with, or loses to, the copy it means to replace, and quietly not take
/// anywhere else.
///
/// Exclusion is where that costs most: `SyncCoordinator` dates the retraction
/// tombstone from this timestamp, so a losing stamp leaves the server and its
/// credential on the sync server and on every other device while this one
/// shows the switch on. The coordinator does re-date a retraction it sees
/// outranked, so the difference is retracting on the first push rather than a
/// round later — but the first push is where it belongs, and a monotonic stamp
/// costs one comparison.
///
/// It outranks the record *this device has pulled*, which is the whole of what
/// a local clamp can know. An edit racing a remote change this device has not
/// seen yet can still tie with it or lose, and lose silently — closing that
/// needs the coordinator, which re-dates a retraction it sees outranked.
int nextUpdatedAt(int? existingUpdatedAt, {required int now}) =>
    max(now, (existingUpdatedAt ?? 0) + 1);
