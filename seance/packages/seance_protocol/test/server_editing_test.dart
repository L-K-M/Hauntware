// The server editor's save rules (docs/design/ghost-servers-part2.md
// section 3, F5a-1a): what a Save writes for the credential boxes, when it
// reads the stored entry, and the `updatedAt` stamp. The cases come from
// Séance's planned_credential_test.dart and server_exclude_from_sync_test.dart
// and from Poltergeist's server_editor_test.dart, where each app tested its
// own copy.
import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('plannedCredential', () {
    Secret? plan({
      AuthMethod auth = AuthMethod.privateKey,
      bool referenceKeyFile = true,
      String password = '',
      String keyPem = '',
      String keyPassphrase = '',
      Secret? stored,
    }) =>
        plannedCredential(
          auth: auth,
          referenceKeyFile: referenceKeyFile,
          password: password,
          keyPem: keyPem,
          keyPassphrase: keyPassphrase,
          secretId: 'sec-1',
          stored: stored,
        );

    test('a referenced key stores the passphrase that decrypts it', () {
      // The box is shown in this mode and used to be dropped: `Test
      // connection` authenticates with what was typed, so it reported success
      // for a key the saved server could not decrypt.
      final secret = plan(keyPassphrase: 'hunter2');
      expect(secret, isNotNull);
      expect(secret!.keyPassphrase, 'hunter2');
      expect(secret.id, 'sec-1');
      // The key itself stays on disk.
      expect(secret.value, isEmpty);
    });

    test('a PEM stored under the same entry survives the passphrase write',
        () {
      // Switching to a referenced file leaves the stored key unread, not
      // discarded — switching back has to find it again.
      final secret = plan(
        keyPassphrase: 'hunter2',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.privateKey,
          value: 'PEM',
        ),
      );
      expect(secret!.value, 'PEM');
      expect(secret.keyPassphrase, 'hunter2');
      // And the pair that leaves behind: the carried PEM was stored with its
      // own passphrase, and this write replaces it with the referenced key's.
      // Pinned as the documented behaviour rather than as a desirable one —
      // one entry holds one passphrase, and the referenced key is the one the
      // server is set to use. STATUS follow-up 17.
    });

    test('a typed PEM does not inherit the stored passphrase', () {
      // The mirror of the case above, and the other half of the single-slot
      // problem: a newly pasted key brings its own passphrase, so a blank box
      // beside it means "none", not "keep". Dropping it is deliberate —
      // carrying one key's passphrase onto another is what makes an entry
      // undecryptable — but nothing pinned it, and the fuzz's fixture has no
      // stored passphrase to notice with.
      final secret = plan(
        referenceKeyFile: false,
        keyPem: 'NEW PEM',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.privateKey,
          value: 'OLD PEM',
          keyPassphrase: 'belongs to the old key',
        ),
      );
      expect(secret!.value, 'NEW PEM');
      expect(secret.keyPassphrase, isNull);
    });

    test('a blank box keeps whatever is stored, in every mode', () {
      // With something stored, which is the case the name is about: nothing
      // written means the entry is left as it is, and a plan built from it
      // would be a write nobody asked for.
      const stored =
          Secret(id: 'sec-1', kind: SecretKind.privateKey, value: 'PEM');
      expect(plan(), isNull);
      expect(plan(stored: stored), isNull);
      expect(plan(referenceKeyFile: false, stored: stored), isNull);
      expect(plan(auth: AuthMethod.password, stored: stored), isNull);
      // The agent has no credential of its own to write.
      expect(plan(auth: AuthMethod.agent, keyPassphrase: 'x'), isNull);
    });

    test('a typed key carries its passphrase, or none', () {
      final withPass =
          plan(referenceKeyFile: false, keyPem: 'PEM', keyPassphrase: 'p');
      expect(withPass!.value, 'PEM');
      expect(withPass.keyPassphrase, 'p');
      final without = plan(referenceKeyFile: false, keyPem: 'PEM');
      expect(without!.keyPassphrase, isNull);
    });

    test('a stored password is not carried into a key entry', () {
      // The entry under this id belongs to whatever auth method last wrote
      // it. A server that used a password before would otherwise have that
      // password stored as its PEM, and read back as one the next time the
      // key was typed rather than referenced.
      final secret = plan(
        keyPassphrase: 'hunter2',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.password,
          value: 'the old password',
        ),
      );
      // The kind as well as the fields: an entry that kept the old
      // `password` stamp while carrying a passphrase is the same
      // contamination one label along, and a read that dispatches on `kind`
      // would take the passphrase for a password.
      expect(secret!.kind, SecretKind.privateKey);
      expect(secret.value, isEmpty);
      expect(secret.keyPassphrase, 'hunter2');
    });

    test('a password is stored as one', () {
      final secret = plan(auth: AuthMethod.password, password: 'pw');
      expect(secret!.kind, SecretKind.password);
      expect(secret.value, 'pw');
    });

    test('plannedCredentialReadsStored covers every branch that reads it', () {
      // `_save` fetches the vault entry only where the predicate says it is
      // needed, so the two have to agree by construction rather than by
      // convention: widen the carry-over without widening the predicate and
      // `stored` arrives null on a branch that dereferences it, writing an
      // empty PEM over a real key.
      //
      // Fuzzed rather than enumerated by hand, so a branch added later is
      // covered without anyone remembering to list it.
      const stored = Secret(
        id: 'sec-1',
        kind: SecretKind.privateKey,
        value: 'STORED PEM',
      );
      for (final auth in AuthMethod.values) {
        for (final referenceKeyFile in [true, false]) {
          for (final password in ['', 'pw']) {
            for (final keyPem in ['', 'TYPED PEM']) {
              for (final keyPassphrase in ['', 'pass']) {
                final reads = plannedCredentialReadsStored(
                  auth: auth,
                  referenceKeyFile: referenceKeyFile,
                  keyPassphrase: keyPassphrase,
                );
                Secret? call({Secret? with_}) => plan(
                      auth: auth,
                      referenceKeyFile: referenceKeyFile,
                      password: password,
                      keyPem: keyPem,
                      keyPassphrase: keyPassphrase,
                      stored: with_,
                    );
                final withStored = call(with_: stored);
                final without = call();
                final combination = 'auth=$auth reference=$referenceKeyFile '
                    'password="$password" pem="$keyPem" '
                    'passphrase="$keyPassphrase"';
                if (reads) {
                  // The predicate promises the entry matters here, so a plan
                  // made without it has to differ — otherwise the fetch is
                  // dead weight and the promise is empty.
                  // The whole plan, as the comment above says: a branch
                  // where the entry mattered only for the passphrase would
                  // otherwise fail this for the wrong reason. Not weaker in
                  // practice — the passphrase comes from the form, so a
                  // carry-over that stopped carrying leaves both equal.
                  expect(
                    withStored?.value != without?.value ||
                        withStored?.keyPassphrase != without?.keyPassphrase,
                    isTrue,
                    reason: 'reads stored, yet ignores it: $combination',
                  );
                } else {
                  // `kind` as well: a carry-over that took the stored
                  // entry's kind would stamp a private key as a password —
                  // the cross-method contamination the neighbouring tests are
                  // about — and the two fields below would not notice.
                  expect(withStored?.kind, without?.kind,
                      reason: 'reads stored without saying so: $combination');
                  expect(withStored?.value, without?.value,
                      reason: 'reads stored without saying so: $combination');
                  expect(withStored?.keyPassphrase, without?.keyPassphrase,
                      reason: 'reads stored without saying so: $combination');
                }
              }
            }
          }
        }
      }
    });

    const storedPem = Secret(
      id: 'sec-1',
      kind: SecretKind.privateKey,
      value: 'STORED-PEM',
      keyPassphrase: 'old-phrase',
    );

    test('password auth writes a password only when typed', () {
      expect(
        plannedCredential(
          auth: AuthMethod.password,
          referenceKeyFile: false,
          password: '',
          keyPem: '',
          keyPassphrase: '',
          secretId: 's',
        ),
        isNull,
      );
      final secret = plannedCredential(
        auth: AuthMethod.password,
        referenceKeyFile: false,
        password: 'hunter2',
        keyPem: '',
        keyPassphrase: '',
        secretId: 's',
      )!;
      expect(secret.kind, SecretKind.password);
      expect(secret.value, 'hunter2');
    });

    test('agent auth never writes a credential', () {
      expect(
        plannedCredential(
          auth: AuthMethod.agent,
          referenceKeyFile: false,
          password: 'stray',
          keyPem: 'stray',
          keyPassphrase: 'stray',
          secretId: 's',
        ),
        isNull,
      );
    });

    test('a typed PEM writes the key, blank passphrase dropping the old one',
        () {
      final secret = plannedCredential(
        auth: AuthMethod.privateKey,
        referenceKeyFile: false,
        password: '',
        keyPem: 'PEM-BYTES',
        keyPassphrase: '',
        secretId: 's',
        stored: storedPem,
      )!;
      expect(secret.kind, SecretKind.privateKey);
      expect(secret.value, 'PEM-BYTES');
      // A re-pasted key brings its own passphrase — the stored one must not
      // silently apply to new material.
      expect(secret.keyPassphrase, isNull);
    });

    test('a referenced key writes only its passphrase, carrying the PEM', () {
      // Blank passphrase in reference mode plans nothing — the stored entry
      // is the credential already.
      expect(
        plannedCredential(
          auth: AuthMethod.privateKey,
          referenceKeyFile: true,
          password: '',
          keyPem: '',
          keyPassphrase: '',
          secretId: 's',
          stored: storedPem,
        ),
        isNull,
      );
      final secret = plannedCredential(
        auth: AuthMethod.privateKey,
        referenceKeyFile: true,
        password: '',
        keyPem: '',
        keyPassphrase: 'file-phrase',
        secretId: 's',
        stored: storedPem,
      )!;
      // The file's passphrase, not the stored PEM's, and the stored key
      // material carried so the entry stays a key.
      expect(secret.keyPassphrase, 'file-phrase');
      expect(secret.value, 'STORED-PEM');
    });

    test('a referenced key over a password-kind entry stores an empty PEM',
        () {
      final secret = plannedCredential(
        auth: AuthMethod.privateKey,
        referenceKeyFile: true,
        password: '',
        keyPem: '',
        keyPassphrase: 'file-phrase',
        secretId: 's',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.password,
          value: 'hunter2',
        ),
      )!;
      // The entry under this id belongs to whatever auth last wrote it — a
      // password must not be carried into a private-key slot.
      expect(secret.kind, SecretKind.privateKey);
      expect(secret.value, '');
    });

    test('reads the stored entry only on the carry-over branch', () {
      // The guard is where "fetch the vault entry first" is decided: wherever
      // it says no read happens, the plan must be identical with and without
      // one in hand.
      bool reads(AuthMethod auth, bool ref, String pass) =>
          plannedCredentialReadsStored(
            auth: auth,
            referenceKeyFile: ref,
            keyPassphrase: pass,
          );
      expect(reads(AuthMethod.privateKey, true, 'x'), isTrue);
      expect(reads(AuthMethod.privateKey, true, ''), isFalse);
      expect(reads(AuthMethod.privateKey, false, 'x'), isFalse);
      expect(reads(AuthMethod.password, true, 'x'), isFalse);
      expect(reads(AuthMethod.agent, true, 'x'), isFalse);
    });
  });

  group('nextUpdatedAt', () {
    test('uses the wall clock when it is already ahead', () {
      expect(nextUpdatedAt(100, now: 5000), 5000);
    });

    test('a new server has nothing to outrank', () {
      expect(nextUpdatedAt(null, now: 5000), 5000);
    });

    test('a clock behind the stored stamp still moves the record forward', () {
      // The case that matters: this device pulled a record another device
      // wrote under a faster clock. Stamping an honest "now" would tie with or
      // lose to it, so the edit — an exclusion, most expensively — would take
      // here and nowhere else.
      expect(nextUpdatedAt(5000, now: 100), 5001);
    });

    test('a tie is not good enough', () {
      // Last-write-wins breaks a tie by device id and sequence, not in the
      // editing device's favour, so an equal stamp is a coin flip.
      expect(nextUpdatedAt(5000, now: 5000), 5001);
    });

    test('advances past both the clock and the record', () {
      expect(nextUpdatedAt(100, now: 200), 200);
      // A fast peer's record this device pulled: the stamp has to beat it.
      expect(nextUpdatedAt(2000000000, now: 200), (2000000000) + 1);
      expect(nextUpdatedAt(null, now: 200), 200);
    });
  });
}
