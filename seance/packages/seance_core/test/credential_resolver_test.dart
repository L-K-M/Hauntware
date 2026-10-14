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
}) => Secret(id: id, kind: kind, value: value, keyPassphrase: keyPassphrase);

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
        secrets: {'ref': _secret('ref', '', keyPassphrase: 'stored')},
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
        secrets: {'ref': _secret('ref', '', keyPassphrase: 'stored')},
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
}
