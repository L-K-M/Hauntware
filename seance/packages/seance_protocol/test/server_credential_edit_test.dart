// The explicit-intent server-editing rules (Sol3's credential-editing
// finding): what a Save with a declared keep/replace/clear intent writes,
// when the retained entry has to match the auth method, and which passphrase
// slot (the pasted key's or the referenced file's) an edit addresses.
//
// Red first: every symbol here is new, so before the fix this file does not
// compile; the assertions are the contract the fix has to satisfy.
import 'package:seance_protocol/seance_protocol.dart';
import 'package:test/test.dart';

void main() {
  ServerCredentialEdit plan({
    AuthMethod auth = AuthMethod.privateKey,
    bool referenceKeyFile = true,
    CredentialIntent credential = CredentialIntent.keep,
    PassphraseIntent passphrase = PassphraseIntent.keep,
    String password = '',
    String keyPem = '',
    String keyPassphrase = '',
    String secretId = 'sec-new',
    String? retainedRef = 'sec-1',
    Secret? stored,
  }) => planServerCredentialEdit(
    auth: auth,
    referenceKeyFile: referenceKeyFile,
    credential: credential,
    passphrase: passphrase,
    password: password,
    keyPem: keyPem,
    keyPassphrase: keyPassphrase,
    secretId: secretId,
    retainedRef: retainedRef,
    stored: stored,
  );

  group('keep vs clear', () {
    test('keep on the same method writes nothing and keeps the ref', () {
      final edit = plan(
        auth: AuthMethod.password,
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.password,
          value: 'pw',
        ),
      );
      expect(edit.secret, isNull);
      expect(edit.clearRef, isFalse);
      expect(edit.retiredRef, isNull);
    });

    test('clear drops the ref and retires the stored entry', () {
      final edit = plan(
        auth: AuthMethod.password,
        credential: CredentialIntent.clear,
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.password,
          value: 'pw',
        ),
      );
      expect(edit.secret, isNull);
      expect(edit.clearRef, isTrue);
      expect(edit.retiredRef, 'sec-1');
    });

    test('agent keeps an unused stored entry rather than dropping it', () {
      // Switching to the agent and back in one sitting must not cost the
      // working credential; the switch back is where the kind rule applies.
      final edit = plan(auth: AuthMethod.agent);
      expect(edit.secret, isNull);
      expect(edit.clearRef, isFalse);
      expect(edit.retiredRef, isNull);
    });

    test('agent clear removes the entry', () {
      final edit = plan(
        auth: AuthMethod.agent,
        credential: CredentialIntent.clear,
      );
      expect(edit.clearRef, isTrue);
      expect(edit.retiredRef, 'sec-1');
    });

    test(
      'replace writes a password under the given id, retiring the old one',
      () {
        // Copy-on-write: the replacement takes a fresh id so the entry the
        // config still names while it is being saved stays usable.
        final edit = plan(
          auth: AuthMethod.password,
          credential: CredentialIntent.replace,
          password: 'new-pw',
        );
        expect(edit.secret!.id, 'sec-new');
        expect(edit.secret!.kind, SecretKind.password);
        expect(edit.secret!.value, 'new-pw');
        expect(edit.clearRef, isFalse);
        expect(edit.retiredRef, 'sec-1');
      },
    );

    test('a replace with nothing typed is refused', () {
      expect(
        () => plan(
          auth: AuthMethod.password,
          credential: CredentialIntent.replace,
          password: '',
        ),
        throwsArgumentError,
      );
    });
  });

  group('kind mismatch', () {
    test('keeping a stored key under password auth is refused', () {
      expect(
        () => plan(
          auth: AuthMethod.password,
          stored: const Secret(
            id: 'sec-1',
            kind: SecretKind.privateKey,
            value: 'PEM',
          ),
        ),
        throwsA(isA<CredentialKindMismatch>()),
      );
    });

    test('keeping a stored password under pasted-key auth is refused', () {
      expect(
        () => plan(
          referenceKeyFile: false,
          stored: const Secret(
            id: 'sec-1',
            kind: SecretKind.password,
            value: 'pw',
          ),
        ),
        throwsA(isA<CredentialKindMismatch>()),
      );
    });

    test('replace and clear resolve the mismatch instead of throwing', () {
      final replaced = plan(
        auth: AuthMethod.password,
        credential: CredentialIntent.replace,
        password: 'new-pw',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.privateKey,
          value: 'PEM',
        ),
      );
      expect(replaced.secret!.kind, SecretKind.password);
      final cleared = plan(
        auth: AuthMethod.password,
        credential: CredentialIntent.clear,
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.privateKey,
          value: 'PEM',
        ),
      );
      expect(cleared.clearRef, isTrue);
    });

    test('a referenced key still refuses a password-kind retained entry', () {
      // Its value is not used while the key stays on disk, but retaining a
      // password here would make a later switch to a pasted key interpret the
      // password as PEM and would keep the wrong credential syncing.
      expect(
        () => plan(
          stored: const Secret(
            id: 'sec-1',
            kind: SecretKind.password,
            value: 'pw',
          ),
        ),
        throwsA(isA<CredentialKindMismatch>()),
      );
    });

    test('retainedCredentialMatches names the same rule', () {
      bool matches(AuthMethod auth, SecretKind kind) =>
          retainedCredentialMatches(auth: auth, storedKind: kind);
      expect(matches(AuthMethod.agent, SecretKind.password), isTrue);
      expect(matches(AuthMethod.password, SecretKind.password), isTrue);
      expect(matches(AuthMethod.password, SecretKind.privateKey), isFalse);
      expect(matches(AuthMethod.privateKey, SecretKind.password), isFalse);
      expect(matches(AuthMethod.privateKey, SecretKind.privateKey), isTrue);
    });
  });

  group('passphrase ownership', () {
    const storedBoth = Secret(
      id: 'sec-1',
      kind: SecretKind.privateKey,
      value: 'PEM',
      keyPassphrase: 'pem-phrase',
      identityPassphrase: 'file-phrase',
    );

    test('a referenced file replaces only its own slot', () {
      final edit = plan(
        credential: CredentialIntent.keep,
        passphrase: PassphraseIntent.replace,
        keyPassphrase: 'new-file-phrase',
        stored: storedBoth,
      );
      // The pasted PEM and its passphrase are carried untouched.
      expect(edit.secret!.value, 'PEM');
      expect(edit.secret!.keyPassphrase, 'pem-phrase');
      expect(edit.secret!.identityPassphrase, 'new-file-phrase');
      expect(edit.retiredRef, 'sec-1');
    });

    test('clearing a migrated file passphrase leaves the PEM slot alone', () {
      final edit = plan(passphrase: PassphraseIntent.clear, stored: storedBoth);
      expect(edit.secret!.identityPassphrase, isNull);
      expect(edit.secret!.keyPassphrase, 'pem-phrase');
    });

    test('clearing a legacy shared passphrase clears the one slot it had', () {
      // Pre-split entries kept one ambiguous passphrase. Clearing the file
      // slot must not also erase the only passphrase the stored PEM may use.
      const legacy = Secret(
        id: 'sec-1',
        kind: SecretKind.privateKey,
        value: 'PEM',
        keyPassphrase: 'shared-phrase',
        credentialVersion: 1,
      );
      final edit = plan(passphrase: PassphraseIntent.clear, stored: legacy);
      expect(edit.secret!.identityPassphrase, isNull);
      expect(edit.secret!.keyPassphrase, 'shared-phrase');
      expect(edit.secret!.credentialVersion, currentCredentialVersion);
    });

    test(
      'replacing a file passphrase migrates without stealing the PEM slot',
      () {
        const legacy = Secret(
          id: 'sec-1',
          kind: SecretKind.privateKey,
          value: 'PEM',
          keyPassphrase: 'shared-phrase',
          credentialVersion: 1,
        );
        final edit = plan(
          passphrase: PassphraseIntent.replace,
          keyPassphrase: 'file-phrase',
          stored: legacy,
        );
        // The file's passphrase now lives in its own slot; the legacy value
        // stays where the pasted PEM will look for it.
        expect(edit.secret!.identityPassphrase, 'file-phrase');
        expect(edit.secret!.keyPassphrase, 'shared-phrase');
      },
    );

    test('clearing when no file passphrase is stored writes nothing', () {
      final edit = plan(
        passphrase: PassphraseIntent.clear,
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.privateKey,
          value: 'PEM',
        ),
      );
      expect(edit.secret, isNull);
      expect(edit.retiredRef, isNull);
    });

    test('a pasted-key passphrase edit leaves the file slot alone', () {
      final edit = plan(
        referenceKeyFile: false,
        passphrase: PassphraseIntent.replace,
        keyPassphrase: 'new-pem-phrase',
        stored: storedBoth,
      );
      expect(edit.secret!.value, 'PEM');
      expect(edit.secret!.keyPassphrase, 'new-pem-phrase');
      expect(edit.secret!.identityPassphrase, 'file-phrase');
    });

    test('a re-pasted key can keep its stored passphrase', () {
      // STATUS follow-up 21: re-pasting the same encrypted key with the box
      // left blank used to drop the stored passphrase.
      final edit = plan(
        referenceKeyFile: false,
        credential: CredentialIntent.replace,
        passphrase: PassphraseIntent.keep,
        keyPem: 'PEM-AGAIN',
        stored: storedBoth,
      );
      expect(edit.secret!.value, 'PEM-AGAIN');
      expect(edit.secret!.keyPassphrase, 'pem-phrase');
      expect(edit.secret!.identityPassphrase, 'file-phrase');
      expect(edit.retiredRef, 'sec-1');
    });

    test('a fresh pasted key with no passphrase stores none', () {
      final edit = plan(
        referenceKeyFile: false,
        credential: CredentialIntent.replace,
        passphrase: PassphraseIntent.keep,
        keyPem: 'PEM',
        retainedRef: null,
      );
      expect(edit.secret!.keyPassphrase, isNull);
      expect(edit.retiredRef, isNull);
    });

    test('replacing a referenced-file credential is refused', () {
      // The key itself stays on disk; the passphrase slots are the vault
      // material this mode has.
      expect(
        () => plan(credential: CredentialIntent.replace, keyPem: 'PEM'),
        throwsArgumentError,
      );
    });

    test('a passphrase choice without stored key material is refused', () {
      expect(
        () => plan(
          referenceKeyFile: false,
          passphrase: PassphraseIntent.replace,
          keyPassphrase: 'x',
        ),
        throwsArgumentError,
      );
    });

    test('a passphrase intent under password or agent auth is refused', () {
      expect(
        () =>
            plan(auth: AuthMethod.password, passphrase: PassphraseIntent.clear),
        throwsArgumentError,
      );
      expect(
        () => plan(
          auth: AuthMethod.agent,
          passphrase: PassphraseIntent.replace,
          keyPassphrase: 'x',
        ),
        throwsArgumentError,
      );
    });

    test('a file-passphrase replacement resolves a wrong-kind entry', () {
      final edit = plan(
        passphrase: PassphraseIntent.replace,
        keyPassphrase: 'x',
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.password,
          value: 'pw',
        ),
      );
      expect(edit.secret!.kind, SecretKind.privateKey);
      expect(edit.secret!.value, isEmpty);
      expect(edit.secret!.identityPassphrase, 'x');
      expect(edit.retiredRef, 'sec-1');
    });

    test('clearing a file passphrase clears a wrong-kind entry', () {
      final edit = plan(
        passphrase: PassphraseIntent.clear,
        stored: const Secret(
          id: 'sec-1',
          kind: SecretKind.password,
          value: 'pw',
        ),
      );
      expect(edit.secret, isNull);
      expect(edit.clearRef, isTrue);
      expect(edit.retiredRef, 'sec-1');
    });
  });

  group('planServerCredentialEditReadsStored', () {
    test('covers every branch that reads the entry', () {
      // Same fuzz shape as plannedCredentialReadsStored: wherever the
      // predicate says no read happens, the plan must be identical with and
      // without the entry in hand.
      const stored = Secret(
        id: 'sec-1',
        kind: SecretKind.privateKey,
        value: 'STORED-PEM',
        keyPassphrase: 'pem-phrase',
        identityPassphrase: 'file-phrase',
      );
      for (final auth in AuthMethod.values) {
        for (final referenceKeyFile in [true, false]) {
          for (final credential in CredentialIntent.values) {
            for (final passphrase in PassphraseIntent.values) {
              for (final keyPem in ['', 'TYPED-PEM']) {
                for (final keyPassphrase in ['', 'typed']) {
                  final combination =
                      'auth=$auth ref=$referenceKeyFile '
                      'credential=$credential passphrase=$passphrase '
                      'pem="$keyPem" box="$keyPassphrase"';
                  final reads = planServerCredentialEditReadsStored(
                    auth: auth,
                    referenceKeyFile: referenceKeyFile,
                    credential: credential,
                    passphrase: passphrase,
                  );
                  ServerCredentialEdit? call({Secret? with_}) {
                    try {
                      return plan(
                        auth: auth,
                        referenceKeyFile: referenceKeyFile,
                        credential: credential,
                        passphrase: passphrase,
                        keyPem: keyPem,
                        keyPassphrase: keyPassphrase,
                        stored: with_,
                      );
                    } on CredentialKindMismatch {
                      return null;
                    } on ArgumentError {
                      return null;
                    }
                  }

                  final withStored = call(with_: stored);
                  final without = call();
                  if (!reads) {
                    expect(
                      _samePlan(withStored, without),
                      isTrue,
                      reason: 'reads stored without saying so: $combination',
                    );
                  }
                }
              }
            }
          }
        }
      }
    });
  });
}

bool _samePlan(ServerCredentialEdit? a, ServerCredentialEdit? b) {
  if (a == null || b == null) {
    return identical(a, b) || (a == null && b == null);
  }
  return a.clearRef == b.clearRef &&
      a.retiredRef == b.retiredRef &&
      a.secret?.id == b.secret?.id &&
      a.secret?.kind == b.secret?.kind &&
      a.secret?.value == b.secret?.value &&
      a.secret?.keyPassphrase == b.secret?.keyPassphrase &&
      a.secret?.identityPassphrase == b.secret?.identityPassphrase &&
      a.secret?.credentialVersion == b.secret?.credentialVersion &&
      a.secret?.updatedAt == b.secret?.updatedAt;
}
