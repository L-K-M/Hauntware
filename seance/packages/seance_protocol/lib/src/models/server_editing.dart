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
/// This compatibility planner retains that historical blank-field behavior.
/// An editor that supports method switches must validate the retained kind or
/// use [planServerCredentialEdit], whose explicit choices make the transition
/// unambiguous.
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
    // Keep the carried PEM's passphrase in its own slot. The typed value
    // decrypts the referenced file, not that PEM; sharing the old slot made a
    // switch to a file silently corrupt the credential used when switching
    // back. This compatibility planner is still used by sibling products, so
    // new entries must use the same split schema as the explicit editor.
    keyPassphrase: stored?.kind == SecretKind.privateKey
        ? stored!.keyPassphrase
        : null,
    identityPassphrase: keyPassphrase,
    credentialVersion: currentCredentialVersion,
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

/// What an editor intends to do with the credential reference.
enum CredentialIntent { keep, replace, clear }

/// What an editor intends to do with the passphrase for the selected key.
enum PassphraseIntent { keep, replace, clear }

/// A retained vault entry does not belong to the authentication method now
/// selected in the editor.
final class CredentialKindMismatch implements Exception {
  const CredentialKindMismatch({required this.expected, required this.actual});

  final SecretKind expected;
  final SecretKind actual;

  @override
  String toString() =>
      'Stored ${actual.name} credential does not match ${expected.name} auth.';
}

/// The atomic credential portion of one server save.
///
/// [secret] is written under a fresh id before the config is saved.
/// [clearRef] means the saved config names no credential. [retiredRef] is
/// removed only after the config save succeeds and no other server names it.
final class ServerCredentialEdit {
  const ServerCredentialEdit({
    this.secret,
    this.clearRef = false,
    this.retiredRef,
  });

  final Secret? secret;
  final bool clearRef;
  final String? retiredRef;
}

/// Whether a retained entry is compatible with the selected auth source.
bool retainedCredentialMatches({
  required AuthMethod auth,
  required SecretKind storedKind,
}) {
  if (auth == AuthMethod.agent) return true;
  if (auth == AuthMethod.password) return storedKind == SecretKind.password;
  return storedKind == SecretKind.privateKey;
}

/// Whether [planServerCredentialEdit] must be given the retained vault entry.
///
/// This may conservatively request a read for a branch that ultimately writes
/// no secret. It never returns false for a branch that validates or carries
/// stored material, which is the data-loss-sensitive direction.
bool planServerCredentialEditReadsStored({
  required AuthMethod auth,
  required bool referenceKeyFile,
  required CredentialIntent credential,
  required PassphraseIntent passphrase,
}) {
  if (credential == CredentialIntent.clear || auth == AuthMethod.agent) {
    return false;
  }
  if (auth == AuthMethod.password) return credential == CredentialIntent.keep;
  return true;
}

/// Plan an explicit keep/replace/clear credential edit.
///
/// A write against an existing reference is copy-on-write: [secretId] must be
/// fresh. Version-one entries keep their shared passphrase available to the
/// slot the user did not edit; making an explicit choice upgrades the result
/// to the split version-two layout.
ServerCredentialEdit planServerCredentialEdit({
  required AuthMethod auth,
  required bool referenceKeyFile,
  required CredentialIntent credential,
  required PassphraseIntent passphrase,
  required String password,
  required String keyPem,
  required String keyPassphrase,
  required String secretId,
  required String? retainedRef,
  Secret? stored,
}) {
  String? nonEmpty(String value) => value.isEmpty ? null : value;

  ServerCredentialEdit replacement(Secret secret) {
    if (retainedRef != null && secret.id == retainedRef) {
      throw ArgumentError.value(
        secret.id,
        'secretId',
        'must be fresh when replacing a retained credential',
      );
    }
    return ServerCredentialEdit(
      secret: secret,
      retiredRef: retainedRef == secret.id ? null : retainedRef,
    );
  }

  void requirePassphraseKeep() {
    if (passphrase != PassphraseIntent.keep) {
      throw ArgumentError.value(
        passphrase,
        'passphrase',
        'is only meaningful for private-key authentication',
      );
    }
  }

  if (credential == CredentialIntent.clear) {
    requirePassphraseKeep();
    return ServerCredentialEdit(
      clearRef: retainedRef != null,
      retiredRef: retainedRef,
    );
  }

  if (auth == AuthMethod.agent) {
    requirePassphraseKeep();
    if (credential == CredentialIntent.replace) {
      throw ArgumentError.value(
        credential,
        'credential',
        'ssh-agent authentication stores no credential',
      );
    }
    return const ServerCredentialEdit();
  }

  if (auth == AuthMethod.password) {
    requirePassphraseKeep();
    if (credential == CredentialIntent.keep) {
      if (stored != null && stored.kind != SecretKind.password) {
        throw CredentialKindMismatch(
          expected: SecretKind.password,
          actual: stored.kind,
        );
      }
      return const ServerCredentialEdit();
    }
    final value = nonEmpty(password);
    if (value == null) {
      throw ArgumentError.value(password, 'password', 'must not be empty');
    }
    return replacement(
      Secret(id: secretId, kind: SecretKind.password, value: value),
    );
  }

  if (referenceKeyFile) {
    if (credential == CredentialIntent.replace) {
      throw ArgumentError.value(
        credential,
        'credential',
        'a referenced key stays on disk; edit its passphrase instead',
      );
    }
    if (passphrase == PassphraseIntent.keep &&
        stored != null &&
        stored.kind != SecretKind.privateKey) {
      throw CredentialKindMismatch(
        expected: SecretKind.privateKey,
        actual: stored.kind,
      );
    }
    if (passphrase == PassphraseIntent.keep) {
      return const ServerCredentialEdit();
    }

    final replacementPassphrase = nonEmpty(keyPassphrase);
    if (passphrase == PassphraseIntent.replace &&
        replacementPassphrase == null) {
      throw ArgumentError.value(
        keyPassphrase,
        'keyPassphrase',
        'must not be empty when replacing it',
      );
    }
    final privateKey = stored?.kind == SecretKind.privateKey ? stored : null;
    if (passphrase == PassphraseIntent.clear &&
        privateKey == null &&
        retainedRef == null) {
      return const ServerCredentialEdit();
    }
    if (passphrase == PassphraseIntent.clear && privateKey == null) {
      return ServerCredentialEdit(clearRef: true, retiredRef: retainedRef);
    }
    final storedFilePassphrase = privateKey == null
        ? null
        : privateKey.usesLegacySharedPassphrase
        ? privateKey.identityPassphrase ?? privateKey.keyPassphrase
        : privateKey.identityPassphrase;
    if (passphrase == PassphraseIntent.clear && storedFilePassphrase == null) {
      return const ServerCredentialEdit();
    }
    return replacement(
      Secret(
        id: secretId,
        kind: SecretKind.privateKey,
        value: privateKey?.value ?? '',
        keyPassphrase: privateKey?.keyPassphrase,
        identityPassphrase: passphrase == PassphraseIntent.replace
            ? replacementPassphrase
            : null,
        credentialVersion: currentCredentialVersion,
      ),
    );
  }

  if (credential == CredentialIntent.keep &&
      stored != null &&
      stored.kind != SecretKind.privateKey) {
    throw CredentialKindMismatch(
      expected: SecretKind.privateKey,
      actual: stored.kind,
    );
  }
  final privateKey = stored?.kind == SecretKind.privateKey ? stored : null;
  if (credential == CredentialIntent.keep &&
      (privateKey == null || privateKey.value.isEmpty)) {
    throw ArgumentError(
      'The retained credential does not contain private-key material.',
    );
  }
  if (credential == CredentialIntent.keep &&
      passphrase == PassphraseIntent.keep) {
    return const ServerCredentialEdit();
  }

  final value = credential == CredentialIntent.replace
      ? nonEmpty(keyPem)
      : privateKey?.value;
  if (value == null) {
    throw ArgumentError.value(keyPem, 'keyPem', 'must not be empty');
  }
  final replacementPassphrase = nonEmpty(keyPassphrase);
  if (passphrase == PassphraseIntent.replace && replacementPassphrase == null) {
    throw ArgumentError.value(
      keyPassphrase,
      'keyPassphrase',
      'must not be empty when replacing it',
    );
  }

  final pastedPassphrase = switch (passphrase) {
    PassphraseIntent.keep => privateKey?.keyPassphrase,
    PassphraseIntent.replace => replacementPassphrase,
    PassphraseIntent.clear => null,
  };
  final referencedPassphrase = privateKey == null
      ? null
      : privateKey.usesLegacySharedPassphrase
      ? privateKey.keyPassphrase
      : privateKey.identityPassphrase;
  return replacement(
    Secret(
      id: secretId,
      kind: SecretKind.privateKey,
      value: value,
      keyPassphrase: pastedPassphrase,
      identityPassphrase: referencedPassphrase,
      credentialVersion: currentCredentialVersion,
    ),
  );
}

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
