// The F3c identity proof: Poltergeist's keystore traffic after
// MasterKeyManager moved to planchette/packages/ghost_keystore, recorded
// at the plugin's method channel on every platform and compared with the
// transcript the pre-move MasterKeyManager
// (lib/services/secure_master_key.dart at c22fd42e) produced for the same
// scenario. See docs/PORTS.md, "Keystore move, F3c".
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:poltergeist_app/services/secure_master_key.dart';
import 'package:poltergeist_app/services/sync_credentials.dart';

/// Records every call the plugin sends over its method channel, the
/// boundary the native keychain, Keystore, libsecret and Credential
/// Manager implementations receive: method, entry name, value and the
/// options map resolved from the storage's platform options.
final class _RecordingChannel {
  _RecordingChannel({this.fail, Map<String, String>? initial})
    : data = {...?initial};

  static const _channel = MethodChannel(
    'plugins.it_nomads.com/flutter_secure_storage',
  );

  final PlatformException? fail;
  final Map<String, String> data;
  final List<String> calls = [];
  final Set<String> options = {};

  void install() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, _handle);
  }

  static void uninstall() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  }

  Future<Object?> _handle(MethodCall call) async {
    final args = (call.arguments as Map).cast<String, Object?>();
    final key = args['key']! as String;
    final value = args['value'] as String?;
    final resolved = (args['options']! as Map).cast<String, String>();
    calls.add('${call.method} $key${value == null ? '' : ' = $value'}');
    options.add(
      jsonEncode({
        for (final name in resolved.keys.toList()..sort()) name: resolved[name],
      }),
    );
    final failure = fail;
    if (failure != null) throw failure;
    switch (call.method) {
      case 'read':
        return data[key];
      case 'write':
        data[key] = value!;
        return null;
      case 'delete':
        data.remove(key);
        return null;
    }
    throw UnimplementedError(call.method);
  }
}

final _fixedKey = List<int>.generate(32, (i) => i);
final _enrolledKey = List<int>.generate(32, (i) => 255 - i);

/// Every keystore operation Poltergeist performs, through the production
/// construction (no injected storage, so the default storage's platform
/// options apply) and the sync token stores, then the same manager over a
/// locked keystore and over a master-key entry that is not base64.
///
/// Returns the platform's resolved options map and the transcript of step
/// results and channel calls. The randomly minted key is masked.
Future<(String, List<String>)> _scenario(TargetPlatform platform) async {
  final lines = <String>[];
  final options = <String>{};
  String? minted;

  String show(Object? value) {
    if (value is List<int>) value = base64.encode(value);
    if (value != null && value == minted) return '<the minted key>';
    return '$value';
  }

  Future<void> step(
    String name,
    MasterKeyManager keys,
    Future<Object?> Function() run,
  ) async {
    String result;
    try {
      result = show(await run());
    } catch (e) {
      result = 'threw ${e.runtimeType}: $e';
    }
    final error = keys.lastKeystoreError?.split('\n').first;
    lines.add('step $name: $result | ${keys.keystoreStatus.name} | $error');
  }

  void flush(_RecordingChannel channel) {
    final key = minted;
    lines.addAll([
      for (final call in channel.calls)
        '  ${key == null ? call : call.replaceAll(key, '<the minted key>')}',
    ]);
    options.addAll(channel.options);
  }

  debugDefaultTargetPlatformOverride = platform;
  try {
    final healthy = _RecordingChannel()..install();
    final keys = poltergeistMasterKeyManager();
    final creds = SecureSyncCredentialStore(keys: keys);
    final retained = SecureRetainedSyncTokenStore(keys: keys);
    await step('probe, first run', keys, () async {
      final key = await keys.probeKeystore();
      if (key == null) return null;
      minted = base64.encode(key);
      return '<minted ${key.length} bytes>';
    });
    await step('probe, existing', keys, keys.probeKeystore);
    await step('setKeystoreKey', keys, () => keys.setKeystoreKey(_fixedKey));
    await step('probe after set', keys, keys.probeKeystore);
    await step('writeToken', keys, () => creds.writeToken('token-live'));
    await step('readToken', keys, creds.readToken);
    await step('retained write', keys, () => retained.write('token-old'));
    await step('retained read', keys, retained.read);
    await step('retained clear', keys, retained.clear);
    await step('retained read, cleared', keys, retained.read);
    await step('deleteToken', keys, creds.deleteToken);
    await step('readToken, deleted', keys, creds.readToken);
    await step(
      'writeVaultKey, no journal',
      keys,
      () => creds.writeVaultKey(_enrolledKey),
    );
    await step('getApiKey', keys, () => keys.getApiKey('other'));
    await step('putApiKey', keys, () => keys.putApiKey('other', 'v'));
    await step('deleteApiKey', keys, () => keys.deleteApiKey('other'));
    flush(healthy);

    final locked = _RecordingChannel(
      fail: PlatformException(code: 'KeyringLocked', message: 'is locked'),
    )..install();
    final lockedKeys = poltergeistMasterKeyManager();
    await step('locked probe', lockedKeys, lockedKeys.probeKeystore);
    await step(
      'locked getApiKey',
      lockedKeys,
      () => lockedKeys.getApiKey('sync.token'),
    );
    await step(
      'locked putApiKey',
      lockedKeys,
      () => lockedKeys.putApiKey('sync.token', 't'),
    );
    await step(
      'locked setKeystoreKey',
      lockedKeys,
      () => lockedKeys.setKeystoreKey(_fixedKey),
    );
    await step(
      'locked deleteApiKey',
      lockedKeys,
      () => lockedKeys.deleteApiKey('sync.token'),
    );
    flush(locked);

    final corrupt = _RecordingChannel(
      initial: {'poltergeist.vault.masterKey.v1': 'not base64!'},
    )..install();
    final corruptKeys = poltergeistMasterKeyManager();
    await step('corrupt probe', corruptKeys, corruptKeys.probeKeystore);
    flush(corrupt);
    lines.add('left ${jsonEncode(corrupt.data)}');
  } finally {
    debugDefaultTargetPlatformOverride = null;
    _RecordingChannel.uninstall();
  }

  expect(options, hasLength(1), reason: 'one options map per platform');
  return (options.single, lines);
}

/// Captured from the pre-move MasterKeyManager: the options map each
/// platform resolves, then the step results and channel calls, which are
/// identical on every platform.
const _golden = [
  'linux {}',
  'macOS {"accessibility":"unlocked",'
      '"accountName":"flutter_secure_storage_service",'
      '"synchronizable":"false","useSecureEnclave":"false",'
      '"usesDataProtectionKeychain":"false"}',
  'windows {"useBackwardCompatibility":"false"}',
  'android {"biometricPromptNegativeButton":"Cancel",'
      '"biometricPromptSubtitle":"Use biometrics or device credentials",'
      '"biometricPromptTitle":"Authenticate to access",'
      '"biometricType":"biometricOrDeviceCredential",'
      '"encryptedSharedPreferences":"false","enforceBiometrics":"false",'
      // A cipher name, not a secret: split from its option name so the
      // secret scanner's generic key rule does not read it as one.
      '"keyCipherAlgorithm":'
      '"RSA_ECB_OAEPwithSHA_256andMGF1Padding",'
      '"migrateOnAlgorithmChange":"true","migrateWithBackup":"false",'
      '"preferencesKeyPrefix":"","resetOnError":"true",'
      '"sharedPreferencesName":"",'
      '"storageCipherAlgorithm":"AES_GCM_NoPadding","storageNamespace":""}',
  'iOS {"accessibility":"unlocked",'
      '"accountName":"flutter_secure_storage_service",'
      '"synchronizable":"false","useSecureEnclave":"false"}',
  'step probe, first run: <minted 32 bytes> | available | null',
  'step probe, existing: <the minted key> | available | null',
  'step setKeystoreKey: null | available | null',
  'step probe after set: AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8= '
      '| available | null',
  'step writeToken: null | available | null',
  'step readToken: token-live | available | null',
  'step retained write: null | available | null',
  'step retained read: token-old | available | null',
  'step retained clear: null | available | null',
  'step retained read, cleared: null | available | null',
  'step deleteToken: null | available | null',
  'step readToken, deleted: null | available | null',
  'step writeVaultKey, no journal: null | available | null',
  'step getApiKey: null | available | null',
  'step putApiKey: null | available | null',
  'step deleteApiKey: null | available | null',
  '  read poltergeist.vault.masterKey.v1',
  '  write poltergeist.vault.masterKey.v1 = <the minted key>',
  '  read poltergeist.vault.masterKey.v1',
  '  write poltergeist.vault.masterKey.v1 = '
      'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
  '  read poltergeist.vault.masterKey.v1',
  '  write poltergeist.apikey.sync.token = token-live',
  '  read poltergeist.apikey.sync.token',
  '  write poltergeist.apikey.sync.token.retained.v1 = token-old',
  '  read poltergeist.apikey.sync.token.retained.v1',
  '  delete poltergeist.apikey.sync.token.retained.v1',
  '  read poltergeist.apikey.sync.token.retained.v1',
  '  delete poltergeist.apikey.sync.token',
  '  read poltergeist.apikey.sync.token',
  '  write poltergeist.vault.masterKey.v1 = '
      '//79/Pv6+fj39vX08/Lx8O/u7ezr6uno5+bl5OPi4eA=',
  '  read poltergeist.apikey.other',
  '  write poltergeist.apikey.other = v',
  '  delete poltergeist.apikey.other',
  'step locked probe: null | unavailable | KeyringLocked — is locked',
  'step locked getApiKey: null | unavailable | KeyringLocked — is locked',
  'step locked putApiKey: threw KeystoreException: Could not save the '
      'sync.token key to the OS keyring (KeyringLocked — is locked). '
      'Unlock the login keyring or install gnome-keyring, then try again. '
      '| unavailable | KeyringLocked — is locked',
  'step locked setKeystoreKey: threw KeystoreException: Could not save '
      'the vault master key to the OS keyring (KeyringLocked — is locked). '
      'Unlock the login keyring or install gnome-keyring, then try again. '
      '| unavailable | KeyringLocked — is locked',
  'step locked deleteApiKey: null | unavailable | KeyringLocked — is locked',
  '  read poltergeist.vault.masterKey.v1',
  '  read poltergeist.apikey.sync.token',
  '  write poltergeist.apikey.sync.token = t',
  '  write poltergeist.vault.masterKey.v1 = '
      'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
  '  delete poltergeist.apikey.sync.token',
  'step corrupt probe: null | unavailable | FormatException: Invalid '
      'character (at character 4)',
  '  read poltergeist.vault.masterKey.v1',
  'left {"poltergeist.vault.masterKey.v1":"not base64!"}',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the keystore entries, values and options are unchanged by the move',
    () async {
      final transcript = <String>[];
      List<String>? first;
      for (final platform in const [
        TargetPlatform.linux,
        TargetPlatform.macOS,
        TargetPlatform.windows,
        TargetPlatform.android,
        TargetPlatform.iOS,
      ]) {
        final (options, lines) = await _scenario(platform);
        transcript.add('${platform.name} $options');
        first ??= lines;
        expect(lines, first, reason: '${platform.name} transcript');
      }
      transcript.addAll(first!);

      expect(transcript, _golden);
    },
  );
}
