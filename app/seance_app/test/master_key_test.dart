import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/secure_master_key.dart';

/// A keystore whose answers the test chooses. Overrides only the two methods
/// [MasterKeyManager] uses, so the real code path runs.
class FakeKeystore extends FlutterSecureStorage {
  FakeKeystore({this.readReturns, this.readThrows});

  /// What `read` hands back — null models both "nothing stored" and a platform
  /// that reports a refused read as absence rather than as an error.
  final String? readReturns;

  /// Set to model a platform that throws instead.
  final Object? readThrows;

  final Map<String, String?> written = {};

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    final thrown = readThrows;
    if (thrown != null) throw thrown;
    return readReturns;
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    written[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the vault master key', () {
    test('is minted once on a genuine first run', () async {
      final keystore = FakeKeystore();
      final key = await MasterKeyManager(
        keystore,
      ).probeKeystore(hasExistingVault: false);

      expect(key, hasLength(32));
      expect(keystore.written, hasLength(1));
      expect(base64.decode(keystore.written.values.single!), key);
    });

    test('is read back when the keystore has it', () async {
      final stored = List<int>.generate(32, (i) => i);
      final keystore = FakeKeystore(readReturns: base64.encode(stored));

      expect(
        await MasterKeyManager(keystore).probeKeystore(hasExistingVault: true),
        stored,
      );
      expect(keystore.written, isEmpty, reason: 'nothing to write');
    });

    test('is never replaced when a vault already exists', () async {
      // The whole point: a keystore that reports nothing while an encrypted
      // vault sits on disk is a keystore that would not hand the key over —
      // minting a new one would make that vault permanently unreadable.
      final keystore = FakeKeystore();

      await expectLater(
        MasterKeyManager(keystore).probeKeystore(hasExistingVault: true),
        throwsA(isA<MasterKeyUnavailableException>()),
      );
      expect(
        keystore.written,
        isEmpty,
        reason: 'a refused read must not overwrite the key it could not read',
      );
    });

    test('says what happened, and what to do about it', () async {
      final message = const MasterKeyUnavailableException().toString();
      expect(message, contains('vault'));
      expect(message, contains('Always Allow'));
    });

    test(
      'a keystore that throws reads as unavailable and writes nothing',
      () async {
        // A platform that reports refusal as an error cannot distinguish that
        // from a locked keyring — so it gets the locked-vault answer, not a
        // crash, and crucially no fresh key written over the one it holds.
        final keystore = FakeKeystore(
          readThrows: StateError('keychain denied'),
        );
        final keys = MasterKeyManager(keystore);

        expect(await keys.probeKeystore(hasExistingVault: true), isNull);
        expect(keys.keystoreStatus, KeystoreStatus.unavailable);
        expect(keystore.written, isEmpty);
      },
    );
  });

  /// [AppServices.initialize] decides "a vault already exists" by reading
  /// `vault.json` itself — the file, not the keystore, is the evidence. These
  /// run the real initialize path against a real support directory; only the
  /// keystore's answers are faked.
  group('the vault-file guard at startup', () {
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    late Directory directory;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('seance-master-key-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            pathChannel,
            (call) async => directory.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, null);
      await directory.delete(recursive: true);
    });

    File vault() => File('${directory.path}/vault.json');

    test(
      'that parses into a shape no vault can be still refuses a new key',
      () async {
        // Well-formed JSON, wrong shape. "Cannot read this as a vault" is the
        // same conservative answer as "cannot parse it": only an absent vault
        // or a provably empty one is a first run.
        for (final shape in const ['[]', '5', '"x"', 'null']) {
          vault().writeAsStringSync(shape);
          final keystore = FakeKeystore();

          await expectLater(
            AppServices.initialize(
              masterKeyManager: MasterKeyManager(keystore),
            ),
            throwsA(isA<MasterKeyUnavailableException>()),
            reason: 'vault.json = $shape',
          );
          expect(
            keystore.written,
            isEmpty,
            reason: 'no key may be minted over vault.json = $shape',
          );
          expect(
            vault().readAsStringSync(),
            shape,
            reason: 'the unreadable vault must survive the refusal',
          );
        }
      },
    );

    test('that is a well-formed empty object is a real first run', () async {
      vault().writeAsStringSync('{}');
      final keystore = FakeKeystore();

      final services = await AppServices.initialize(
        masterKeyManager: MasterKeyManager(keystore),
      );
      try {
        expect(services.vaultKey, isNotNull);
        expect(
          keystore.written,
          hasLength(1),
          reason:
              'an empty vault holds nothing to strand — mint is the '
              'right answer',
        );
      } finally {
        await services.probe.dispose();
      }
    });
  });
}
