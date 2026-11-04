import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

/// A vault and key-file reader that records every read, so the tests can pin
/// which branches touch storage at all.
final class _FakeSource implements CredentialSource {
  _FakeSource({Map<String, Secret>? secrets}) : secrets = secrets ?? {};

  final Map<String, Secret> secrets;
  final List<String> secretReads = [];
  final List<(ServerConfig, CredentialDraft?)> identityReads = [];
  Object? identityError;

  @override
  Future<Secret?> storedSecret(String secretRef) async {
    secretReads.add(secretRef);
    return secrets[secretRef];
  }

  @override
  Future<String> identityFile(
    ServerConfig config,
    CredentialDraft? draft,
  ) async {
    identityReads.add((config, draft));
    final error = identityError;
    if (error != null) throw error;
    return 'FILE-PEM';
  }

  bool get untouched => secretReads.isEmpty && identityReads.isEmpty;
}

ServerConfig _config(
  AuthMethod auth, {
  String id = 's1',
  String label = 'prod',
  String? secretRef,
  String? identityFilePath,
}) => ServerConfig(
  id: id,
  label: label,
  host: 'prod.example.com',
  username: 'deploy',
  authMethod: auth,
  secretRef: secretRef,
  identityFilePath: identityFilePath,
  createdAt: 1,
  updatedAt: 1,
);

Secret _secret(
  String id,
  String value, {
  SecretKind kind = SecretKind.password,
  String? keyPassphrase,
  String? identityPassphrase,
  int credentialVersion = currentCredentialVersion,
}) => Secret(
  id: id,
  kind: kind,
  value: value,
  keyPassphrase: keyPassphrase,
  identityPassphrase: identityPassphrase,
  credentialVersion: credentialVersion,
);

const _grant = 'opaque-grant';

void main() {
  test('the default missing-secret policy is fail', () {
    expect(
      CredentialResolver(_FakeSource()).missingSecretPolicy,
      MissingSecretPolicy.fail,
    );
  });

  group('agent auth', () {
    test('short-circuits before any read', () async {
      final source = _FakeSource();
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.agent, secretRef: 'stale', identityFilePath: '/k'),
        draft: const CredentialDraft(
          password: 'pw',
          privateKeyPem: 'PEM',
          identityBookmark: _grant,
        ),
      );

      expect(credentials.method, AuthMethod.agent);
      expect(source.untouched, isTrue);
    });
  });

  group('orphan identity bookmark', () {
    test('is refused under key auth with no path or typed PEM', () async {
      final source = _FakeSource(secrets: {'ref': _secret('ref', 'PEM')});

      await expectLater(
        CredentialResolver(source).resolve(
          _config(AuthMethod.privateKey, secretRef: 'ref'),
          draft: const CredentialDraft(identityBookmark: _grant),
        ),
        throwsA(
          isA<ArgumentError>()
              .having((e) => e.name, 'name', 'draftIdentityBookmark')
              .having((e) => e.invalidValue, 'invalidValue', _grant),
        ),
      );
      expect(source.untouched, isTrue);
    });

    test('is a harmless leftover beside a typed PEM', () async {
      final source = _FakeSource();
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.privateKey),
        draft: const CredentialDraft(
          privateKeyPem: 'PEM',
          identityBookmark: _grant,
        ),
      );

      expect(credentials.privateKeyPem, 'PEM');
      expect(source.untouched, isTrue);
    });

    test('an empty typed PEM does not excuse it', () async {
      await expectLater(
        CredentialResolver(_FakeSource()).resolve(
          _config(AuthMethod.privateKey),
          draft: const CredentialDraft(
            privateKeyPem: '',
            identityBookmark: _grant,
          ),
        ),
        throwsArgumentError,
      );
    });

    test('is forwarded beside a configured identity path', () async {
      final source = _FakeSource();
      const draft = CredentialDraft(identityBookmark: _grant);
      final config = _config(AuthMethod.privateKey, identityFilePath: '/k');

      final credentials = await CredentialResolver(
        source,
      ).resolve(config, draft: draft);

      expect(credentials.privateKeyPem, 'FILE-PEM');
      expect(source.identityReads, hasLength(1));
      expect(source.identityReads.single.$1, same(config));
      expect(source.identityReads.single.$2?.identityBookmark, _grant);
    });

    test('is a harmless leftover under password auth', () async {
      final source = _FakeSource();
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.password),
        draft: const CredentialDraft(password: 'pw', identityBookmark: _grant),
      );

      expect(credentials.method, AuthMethod.password);
      expect(credentials.password, 'pw');
      expect(credentials.privateKeyPem, isNull);
      expect(source.untouched, isTrue);
    });
  });

  group('password auth', () {
    test('a typed password wins without a vault read', () async {
      final source = _FakeSource(secrets: {'ref': _secret('ref', 'saved')});
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.password, secretRef: 'ref'),
        draft: const CredentialDraft(password: 'typed'),
      );

      expect(credentials.password, 'typed');
      expect(source.untouched, isTrue);
    });

    test('a blank typed password falls back to the vault', () async {
      final source = _FakeSource(secrets: {'ref': _secret('ref', 'saved')});
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.password, secretRef: 'ref'),
        draft: const CredentialDraft(password: ''),
      );

      expect(credentials.password, 'saved');
      expect(source.secretReads, ['ref']);
    });

    test('no secretRef resolves empty without a read', () async {
      final source = _FakeSource();
      final credentials = await CredentialResolver(
        source,
      ).resolve(_config(AuthMethod.password));

      expect(credentials.password, '');
      expect(source.untouched, isTrue);
    });

    test('a draft for another method is ignored', () async {
      final source = _FakeSource(secrets: {'ref': _secret('ref', 'saved')});
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.password, secretRef: 'ref'),
        draft: const CredentialDraft(privateKeyPem: 'PEM', keyPassphrase: 'p'),
      );

      expect(credentials.method, AuthMethod.password);
      expect(credentials.password, 'saved');
    });
  });

  group('key auth with a referenced identity file', () {
    test('wins over a typed PEM', () async {
      final source = _FakeSource();
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.privateKey, identityFilePath: '/k'),
        draft: const CredentialDraft(privateKeyPem: 'TYPED'),
      );

      expect(credentials.privateKeyPem, 'FILE-PEM');
      expect(source.identityReads, hasLength(1));
    });

    test('a typed passphrase skips the stored-passphrase read', () async {
      final source = _FakeSource(
        secrets: {'ref': _secret('ref', '', identityPassphrase: 'stored')},
      );
      final credentials = await CredentialResolver(source).resolve(
        _config(
          AuthMethod.privateKey,
          secretRef: 'ref',
          identityFilePath: '/k',
        ),
        draft: const CredentialDraft(keyPassphrase: 'typed'),
      );

      expect(credentials.keyPassphrase, 'typed');
      expect(source.secretReads, isEmpty);
    });

    test('a blank passphrase falls back to the stored one', () async {
      final source = _FakeSource(
        secrets: {'ref': _secret('ref', '', identityPassphrase: 'stored')},
      );
      final credentials = await CredentialResolver(source).resolve(
        _config(
          AuthMethod.privateKey,
          secretRef: 'ref',
          identityFilePath: '/k',
        ),
        draft: const CredentialDraft(keyPassphrase: ''),
      );

      expect(credentials.privateKeyPem, 'FILE-PEM');
      expect(credentials.keyPassphrase, 'stored');
      expect(source.secretReads, ['ref']);
    });

    test('the stored file passphrase is read from its own slot', () async {
      // Post-split entry: both keys have passphrases, and the file's must
      // not be read from the PEM's slot or the other way round.
      final source = _FakeSource(
        secrets: {
          'ref': const Secret(
            id: 'ref',
            kind: SecretKind.privateKey,
            value: '',
            keyPassphrase: 'pem-phrase',
            identityPassphrase: 'file-phrase',
          ),
        },
      );
      final credentials = await CredentialResolver(source).resolve(
        _config(
          AuthMethod.privateKey,
          secretRef: 'ref',
          identityFilePath: '/k',
        ),
      );

      expect(credentials.privateKeyPem, 'FILE-PEM');
      expect(credentials.keyPassphrase, 'file-phrase');
    });

    test('a legacy shared passphrase still serves the file', () async {
      // Pre-split entry: the file's passphrase was the only one stored.
      final source = _FakeSource(
        secrets: {
          'ref': _secret(
            'ref',
            '',
            keyPassphrase: 'legacy-phrase',
            credentialVersion: 1,
          ),
        },
      );
      final credentials = await CredentialResolver(source).resolve(
        _config(
          AuthMethod.privateKey,
          secretRef: 'ref',
          identityFilePath: '/k',
        ),
      );

      expect(credentials.keyPassphrase, 'legacy-phrase');
    });

    test(
      'an explicit clear resolves no passphrase without a stored read',
      () async {
        final source = _FakeSource(
          secrets: {'ref': _secret('ref', '', keyPassphrase: 'stored')},
        );
        final credentials = await CredentialResolver(source).resolve(
          _config(
            AuthMethod.privateKey,
            secretRef: 'ref',
            identityFilePath: '/k',
          ),
          draft: const CredentialDraft(
            passphraseIntent: PassphraseIntent.clear,
          ),
        );

        expect(credentials.keyPassphrase, isNull);
        expect(source.secretReads, isEmpty);
      },
    );

    test('no secretRef means no passphrase and no vault read', () async {
      final source = _FakeSource();
      final credentials = await CredentialResolver(
        source,
      ).resolve(_config(AuthMethod.privateKey, identityFilePath: '/k'));

      expect(credentials.keyPassphrase, isNull);
      expect(source.secretReads, isEmpty);
    });

    for (final policy in MissingSecretPolicy.values) {
      test(
        'an absent passphrase entry is no passphrase (${policy.name})',
        () async {
          final source = _FakeSource();
          final credentials =
              await CredentialResolver(
                source,
                missingSecretPolicy: policy,
              ).resolve(
                _config(
                  AuthMethod.privateKey,
                  secretRef: 'gone',
                  identityFilePath: '/k',
                ),
              );

          expect(credentials.privateKeyPem, 'FILE-PEM');
          expect(credentials.keyPassphrase, isNull);
          expect(source.secretReads, ['gone']);
        },
      );
    }

    test('a failed file read propagates', () async {
      final source = _FakeSource()..identityError = StateError('unreadable');

      await expectLater(
        CredentialResolver(
          source,
        ).resolve(_config(AuthMethod.privateKey, identityFilePath: '/k')),
        throwsStateError,
      );
    });
  });

  group('key auth with a typed PEM', () {
    test('a blank passphrase means none, not the stored one', () async {
      final source = _FakeSource(
        secrets: {'ref': _secret('ref', 'SAVED', keyPassphrase: 'stored')},
      );
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.privateKey, secretRef: 'ref'),
        draft: const CredentialDraft(privateKeyPem: 'TYPED', keyPassphrase: ''),
      );

      expect(credentials.privateKeyPem, 'TYPED');
      expect(credentials.keyPassphrase, isNull);
      expect(source.untouched, isTrue);
    });

    test('keeps a typed passphrase', () async {
      final credentials = await CredentialResolver(_FakeSource()).resolve(
        _config(AuthMethod.privateKey),
        draft: const CredentialDraft(
          privateKeyPem: 'TYPED',
          keyPassphrase: 'p',
        ),
      );

      expect(credentials.keyPassphrase, 'p');
    });

    test(
      'an explicit keep carries the stored passphrase onto the re-paste',
      () async {
        // The mirror of the blank-box rule: a re-pasted key with Keep chosen
        // authenticates with the stored passphrase, exactly as the save
        // writes it.
        final source = _FakeSource(
          secrets: {
            'ref': _secret(
              'ref',
              'SAVED',
              kind: SecretKind.privateKey,
              keyPassphrase: 'stored',
            ),
          },
        );
        final credentials = await CredentialResolver(source).resolve(
          _config(AuthMethod.privateKey, secretRef: 'ref'),
          draft: const CredentialDraft(
            privateKeyPem: 'PEM-AGAIN',
            passphraseIntent: PassphraseIntent.keep,
          ),
        );

        expect(credentials.privateKeyPem, 'PEM-AGAIN');
        expect(credentials.keyPassphrase, 'stored');
        expect(source.secretReads, ['ref']);
      },
    );

    test(
      'an explicit keep with no reference ignores stale typed text',
      () async {
        final source = _FakeSource();
        final credentials = await CredentialResolver(source).resolve(
          _config(AuthMethod.privateKey),
          draft: const CredentialDraft(
            privateKeyPem: 'TYPED',
            keyPassphrase: 'stale',
            passphraseIntent: PassphraseIntent.keep,
          ),
        );

        expect(credentials.privateKeyPem, 'TYPED');
        expect(credentials.keyPassphrase, isNull);
        expect(source.untouched, isTrue);
      },
    );
  });

  group('key auth with a stored PEM', () {
    test('resolves the stored key and passphrase', () async {
      final source = _FakeSource(
        secrets: {
          'ref': _secret(
            'ref',
            'SAVED',
            kind: SecretKind.privateKey,
            keyPassphrase: 'stored',
          ),
        },
      );
      final credentials = await CredentialResolver(
        source,
      ).resolve(_config(AuthMethod.privateKey, secretRef: 'ref'));

      expect(credentials.privateKeyPem, 'SAVED');
      expect(credentials.keyPassphrase, 'stored');
    });

    test('a typed passphrase beats the stored one', () async {
      final source = _FakeSource(
        secrets: {'ref': _secret('ref', 'SAVED', keyPassphrase: 'stored')},
      );
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.privateKey, secretRef: 'ref'),
        draft: const CredentialDraft(keyPassphrase: 'typed'),
      );

      expect(credentials.privateKeyPem, 'SAVED');
      expect(credentials.keyPassphrase, 'typed');
    });

    test('an explicit clear drops the stored passphrase', () async {
      final source = _FakeSource(
        secrets: {'ref': _secret('ref', 'SAVED', keyPassphrase: 'stored')},
      );
      final credentials = await CredentialResolver(source).resolve(
        _config(AuthMethod.privateKey, secretRef: 'ref'),
        draft: const CredentialDraft(passphraseIntent: PassphraseIntent.clear),
      );

      expect(credentials.privateKeyPem, 'SAVED');
      expect(credentials.keyPassphrase, isNull);
    });

    test('no secretRef resolves an empty key without a read', () async {
      final source = _FakeSource();
      final credentials = await CredentialResolver(
        source,
      ).resolve(_config(AuthMethod.privateKey));

      expect(credentials.privateKeyPem, '');
      expect(credentials.keyPassphrase, isNull);
      expect(source.untouched, isTrue);
    });
  });

  group('a named vault entry this device lacks', () {
    test('fails a password under the default policy', () async {
      await expectLater(
        CredentialResolver(
          _FakeSource(),
        ).resolve(_config(AuthMethod.password, secretRef: 'gone')),
        throwsA(
          isA<CredentialMissingException>()
              .having((e) => e.serverId, 'serverId', 's1')
              .having((e) => e.serverLabel, 'serverLabel', 'prod')
              .having((e) => e.authMethod, 'authMethod', AuthMethod.password)
              .having(
                (e) => '$e',
                'message',
                contains('the password for "prod"'),
              ),
        ),
      );
    });

    test('fails a stored key under the default policy', () async {
      await expectLater(
        CredentialResolver(
          _FakeSource(),
        ).resolve(_config(AuthMethod.privateKey, secretRef: 'gone')),
        throwsA(
          isA<CredentialMissingException>()
              .having((e) => e.authMethod, 'authMethod', AuthMethod.privateKey)
              .having((e) => '$e', 'message', contains('the private key for')),
        ),
      );
    });

    test('a typed password is still used', () async {
      final credentials = await CredentialResolver(_FakeSource()).resolve(
        _config(AuthMethod.password, secretRef: 'gone'),
        draft: const CredentialDraft(password: 'typed'),
      );

      expect(credentials.password, 'typed');
    });

    test('substitutes an empty password when asked to', () async {
      final credentials = await CredentialResolver(
        _FakeSource(),
        missingSecretPolicy: MissingSecretPolicy.substituteEmpty,
      ).resolve(_config(AuthMethod.password, secretRef: 'gone'));

      expect(credentials.method, AuthMethod.password);
      expect(credentials.password, '');
    });

    test('substitutes an empty key when asked to', () async {
      final credentials =
          await CredentialResolver(
            _FakeSource(),
            missingSecretPolicy: MissingSecretPolicy.substituteEmpty,
          ).resolve(
            _config(AuthMethod.privateKey, secretRef: 'gone'),
            draft: const CredentialDraft(keyPassphrase: 'typed'),
          );

      expect(credentials.privateKeyPem, '');
      expect(credentials.keyPassphrase, 'typed');
    });
  });

  group('jumpHostResolver', () {
    test('resolves a saved hop with its stored credential', () async {
      final jump = _config(AuthMethod.password, id: 'jump', secretRef: 'ref');
      final source = _FakeSource(secrets: {'ref': _secret('ref', 'saved')});
      final resolve = CredentialResolver(
        source,
      ).jumpHostResolver((id) async => id == jump.id ? jump : null);

      final resolved = await resolve(jump.id);

      expect(resolved?.config, same(jump));
      expect(resolved?.credentials.password, 'saved');
    });

    test('an unknown hop is null without a read', () async {
      final source = _FakeSource();
      final resolve = CredentialResolver(
        source,
      ).jumpHostResolver((id) async => null);

      expect(await resolve('missing'), isNull);
      expect(source.untouched, isTrue);
    });

    test('a hop missing its credential names itself', () async {
      final jump = _config(
        AuthMethod.password,
        id: 'jump',
        label: 'bastion',
        secretRef: 'gone',
      );
      final resolve = CredentialResolver(
        _FakeSource(),
      ).jumpHostResolver((id) async => jump);

      await expectLater(
        resolve(jump.id),
        throwsA(
          isA<CredentialMissingException>()
              .having((e) => e.serverId, 'serverId', 'jump')
              .having((e) => e.serverLabel, 'serverLabel', 'bastion'),
        ),
      );
    });
  });

  group('Test/Save parity', () {
    // The property the editor's Test connection exists for: resolving the
    // form's explicit intent and resolving the entry that intent saves must
    // produce the same passphrase. Each case plans the save (the shared
    // model a Save runs through), materializes the written entry as the
    // vault would hold it, and resolves the saved config against it.
    test('a referenced file edited to a new passphrase', () async {
      const stored = Secret(
        id: 'sec-1',
        kind: SecretKind.privateKey,
        value: 'PEM',
        keyPassphrase: 'legacy-phrase',
      );
      final edit = planServerCredentialEdit(
        auth: AuthMethod.privateKey,
        referenceKeyFile: true,
        credential: CredentialIntent.keep,
        passphrase: PassphraseIntent.replace,
        password: '',
        keyPem: '',
        keyPassphrase: 'new-file-phrase',
        secretId: 'sec-2',
        retainedRef: 'sec-1',
        stored: stored,
      );

      final source = _FakeSource(secrets: {edit.secret!.id: edit.secret!});
      final config = _config(
        AuthMethod.privateKey,
        secretRef: edit.secret!.id,
        identityFilePath: '/k',
      );
      // After the save: no draft, the stored slots decide.
      final saved = await CredentialResolver(source).resolve(config);
      // Before the save: the form's intent, as Test connection sends it.
      final tested =
          await CredentialResolver(
            _FakeSource(secrets: {'sec-1': stored}),
          ).resolve(
            _config(
              AuthMethod.privateKey,
              secretRef: 'sec-1',
              identityFilePath: '/k',
            ),
            draft: const CredentialDraft(
              keyPassphrase: 'new-file-phrase',
              passphraseIntent: PassphraseIntent.replace,
            ),
          );

      expect(tested.keyPassphrase, 'new-file-phrase');
      expect(saved.keyPassphrase, tested.keyPassphrase);
    });

    test('a referenced file cleared of its passphrase', () async {
      const stored = Secret(
        id: 'sec-1',
        kind: SecretKind.privateKey,
        value: 'PEM',
        identityPassphrase: 'file-phrase',
      );
      final edit = planServerCredentialEdit(
        auth: AuthMethod.privateKey,
        referenceKeyFile: true,
        credential: CredentialIntent.keep,
        passphrase: PassphraseIntent.clear,
        password: '',
        keyPem: '',
        keyPassphrase: '',
        secretId: 'sec-2',
        retainedRef: 'sec-1',
        stored: stored,
      );

      final source = _FakeSource(secrets: {edit.secret!.id: edit.secret!});
      final config = _config(
        AuthMethod.privateKey,
        secretRef: edit.secret!.id,
        identityFilePath: '/k',
      );
      final saved = await CredentialResolver(source).resolve(config);
      final tested =
          await CredentialResolver(
            _FakeSource(secrets: {'sec-1': stored}),
          ).resolve(
            _config(
              AuthMethod.privateKey,
              secretRef: 'sec-1',
              identityFilePath: '/k',
            ),
            draft: const CredentialDraft(
              passphraseIntent: PassphraseIntent.clear,
            ),
          );

      expect(tested.keyPassphrase, isNull);
      expect(saved.keyPassphrase, isNull);
    });

    test('a re-pasted key keeping its passphrase', () async {
      const stored = Secret(
        id: 'sec-1',
        kind: SecretKind.privateKey,
        value: 'PEM',
        keyPassphrase: 'pem-phrase',
      );
      final edit = planServerCredentialEdit(
        auth: AuthMethod.privateKey,
        referenceKeyFile: false,
        credential: CredentialIntent.replace,
        passphrase: PassphraseIntent.keep,
        password: '',
        keyPem: 'PEM-AGAIN',
        keyPassphrase: '',
        secretId: 'sec-2',
        retainedRef: 'sec-1',
        stored: stored,
      );

      final source = _FakeSource(secrets: {edit.secret!.id: edit.secret!});
      final config = _config(AuthMethod.privateKey, secretRef: edit.secret!.id);
      final saved = await CredentialResolver(source).resolve(config);
      final tested =
          await CredentialResolver(
            _FakeSource(secrets: {'sec-1': stored}),
          ).resolve(
            _config(AuthMethod.privateKey, secretRef: 'sec-1'),
            draft: const CredentialDraft(
              privateKeyPem: 'PEM-AGAIN',
              passphraseIntent: PassphraseIntent.keep,
            ),
          );

      expect(tested.keyPassphrase, 'pem-phrase');
      expect(saved.keyPassphrase, 'pem-phrase');
    });
  });
}
