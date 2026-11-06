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

/// What an editor explicitly does with the vault entry a server references.
/// Unlike the legacy blank-field rules below, every state is unambiguous.
enum CredentialEditAction { keep, replace, clear }

/// What a private-key edit does with the passphrase owned by that key source.
enum KeyPassphraseAction { keep, replace, clear }

/// The explicit vault mutation planned for one Save.
final class CredentialEditPlan {
  const CredentialEditPlan({required this.action, this.replacement});

  final CredentialEditAction action;

  /// Non-null only for [CredentialEditAction.replace].
  final Secret? replacement;
}

/// Plan an editor whose keep/replace/clear choices are explicit.
///
/// A pasted PEM and a referenced identity file own separate passphrase slots.
/// Keeping a passphrase is accepted only when the key source is unchanged;
/// this prevents a blank field from attaching one key's passphrase to another.
CredentialEditPlan planCredentialEdit({
  required CredentialEditAction action,
  required KeyPassphraseAction passphraseAction,
  required AuthMethod auth,
  required bool referenceKeyFile,
  required String password,
  required String keyPem,
  required String keyPassphrase,
  required String? identityFilePath,
  required String secretId,
  Secret? stored,
}) {
  if (action == CredentialEditAction.clear) {
    return const CredentialEditPlan(action: CredentialEditAction.clear);
  }
  if (auth == AuthMethod.agent) {
    throw ArgumentError(
      'SSH agent authentication has no saved credential to '
      '${action.name}',
    );
  }
  if (action == CredentialEditAction.keep) {
    final expected = switch (auth) {
      AuthMethod.password => SecretKind.password,
      AuthMethod.privateKey => SecretKind.privateKey,
      AuthMethod.agent => null,
    };
    if (expected != null) {
      if (stored == null) {
        throw ArgumentError('There is no saved credential to keep');
      }
      if (stored.kind != expected) {
        throw ArgumentError(
          'The saved ${stored.kind.name} credential cannot be kept for '
          '${auth.name} authentication',
        );
      }
      if (expected == SecretKind.privateKey) {
        if (!referenceKeyFile && stored.value.isEmpty) {
          throw ArgumentError('There is no saved pasted private key to keep');
        }
        if (referenceKeyFile) {
          final path = identityFilePath;
          if (path == null || path.isEmpty) {
            throw ArgumentError(
              'A referenced private key requires an identity file path',
            );
          }
          final sourceBound = stored.identityFilePath != null ||
              stored.identityFilePassphrase != null;
          if (sourceBound && stored.identityFilePath != path) {
            throw ArgumentError(
              'The saved passphrase belongs to a different identity file',
            );
          }
        }
      }
    }
    return const CredentialEditPlan(action: CredentialEditAction.keep);
  }

  if (auth == AuthMethod.password) {
    if (password.isEmpty) {
      throw ArgumentError.value(password, 'password', 'must not be empty');
    }
    return CredentialEditPlan(
      action: CredentialEditAction.replace,
      replacement: Secret(
        id: secretId,
        kind: SecretKind.password,
        value: password,
      ),
    );
  }

  final storedKey = stored?.kind == SecretKind.privateKey ? stored : null;
  if (referenceKeyFile) {
    final path = identityFilePath;
    if (path == null || path.isEmpty) {
      throw ArgumentError.value(
        path,
        'identityFilePath',
        'must not be empty for a referenced key',
      );
    }
    final String? filePassphrase;
    switch (passphraseAction) {
      case KeyPassphraseAction.keep:
        if (storedKey == null) {
          throw ArgumentError('There is no referenced-key passphrase to keep');
        }
        final legacy =
            storedKey.identityFilePath == null &&
            storedKey.identityFilePassphrase == null;
        if (!legacy && storedKey.identityFilePath != path) {
          throw ArgumentError(
            'The saved passphrase belongs to a different identity file',
          );
        }
        filePassphrase = legacy
            ? storedKey.keyPassphrase
            : storedKey.identityFilePassphrase;
      case KeyPassphraseAction.replace:
        if (keyPassphrase.isEmpty) {
          throw ArgumentError.value(
            keyPassphrase,
            'keyPassphrase',
            'must not be empty when replacing a passphrase',
          );
        }
        filePassphrase = keyPassphrase;
      case KeyPassphraseAction.clear:
        filePassphrase = null;
    }
    final replacement = Secret(
      id: secretId,
      kind: SecretKind.privateKey,
      value: storedKey?.value ?? '',
      // A legacy referenced-key entry kept its file passphrase in the pasted
      // slot. Preserve that slot only when there is actually a pasted PEM it
      // could belong to; otherwise clearing the file passphrase can remove the
      // now-empty vault entry entirely.
      keyPassphrase: storedKey?.value.isNotEmpty == true
          ? storedKey!.keyPassphrase
          : null,
      identityFilePath: path,
      identityFilePassphrase: filePassphrase,
    );
    if (replacement.value.isEmpty &&
        replacement.keyPassphrase == null &&
        replacement.identityFilePassphrase == null) {
      return const CredentialEditPlan(action: CredentialEditAction.clear);
    }
    return CredentialEditPlan(
      action: CredentialEditAction.replace,
      replacement: replacement,
    );
  }

  if (keyPem.isEmpty) {
    throw ArgumentError.value(keyPem, 'keyPem', 'must not be empty');
  }
  final String? pemPassphrase;
  switch (passphraseAction) {
    case KeyPassphraseAction.keep:
      if (storedKey == null || storedKey.value != keyPem) {
        throw ArgumentError(
          'A passphrase can be kept only when the pasted key is unchanged',
        );
      }
      pemPassphrase = storedKey.keyPassphrase;
    case KeyPassphraseAction.replace:
      if (keyPassphrase.isEmpty) {
        throw ArgumentError.value(
          keyPassphrase,
          'keyPassphrase',
          'must not be empty when replacing a passphrase',
        );
      }
      pemPassphrase = keyPassphrase;
    case KeyPassphraseAction.clear:
      pemPassphrase = null;
  }
  return CredentialEditPlan(
    action: CredentialEditAction.replace,
    replacement: Secret(
      id: secretId,
      kind: SecretKind.privateKey,
      value: keyPem,
      keyPassphrase: pemPassphrase,
      identityFilePath: storedKey?.identityFilePath,
      identityFilePassphrase: storedKey?.identityFilePassphrase,
    ),
  );
}

/// Whether [planCredentialEdit] needs the current vault entry.
bool planCredentialEditReadsStored({
  required CredentialEditAction action,
  required AuthMethod auth,
}) =>
    action == CredentialEditAction.keep ||
    (action == CredentialEditAction.replace && auth == AuthMethod.privateKey);

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
/// Legacy blank-field callers still have one gap: when the auth *method*
/// changes and nothing is typed, "what is stored" is a credential of the old
/// kind. Nothing is written, so the config keeps its `secretRef`. Explicit
/// callers use [planCredentialEdit] and reject that mismatch instead.
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
  required String? identityFilePath,
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
      identityFilePath: stored?.kind == SecretKind.privateKey
          ? stored!.identityFilePath
          : null,
      identityFilePassphrase: stored?.kind == SecretKind.privateKey
          ? stored!.identityFilePassphrase
          : null,
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
    // Preserve the inactive pasted key's own passphrase, and bind the typed
    // passphrase to the referenced source instead of overwriting that slot.
    keyPassphrase:
        stored?.kind == SecretKind.privateKey && stored!.value.isNotEmpty
        ? stored.keyPassphrase
        : null,
    identityFilePath: identityFilePath,
    identityFilePassphrase: keyPassphrase,
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
  required String keyPem,
  required String keyPassphrase,
}) =>
    auth == AuthMethod.privateKey &&
    (referenceKeyFile ? keyPassphrase.isNotEmpty : keyPem.isNotEmpty);

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
