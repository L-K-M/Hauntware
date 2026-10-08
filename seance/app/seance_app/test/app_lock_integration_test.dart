import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_lock.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/file_stores.dart';
import 'package:seance_app/services/local_settings_backend.dart';
import 'package:seance_app/services/secure_master_key.dart';
import 'package:seance_app/services/secrets_recovery.dart';
import 'package:seance_app/services/settings_backend.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_core/seance_core.dart';

import 'support/device_authenticator.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _masterKeyName = 'seance.vault.masterKey.v1';
const _savedSecret = Secret(
  id: 'saved',
  kind: SecretKind.password,
  value: 'password',
  updatedAt: 1,
);

class _Keystore extends FlutterSecureStorage {
  final values = <String, String>{};
  int reads = 0;
  int masterReads = 0;

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
    reads++;
    if (key == _masterKeyName) masterReads++;
    return values[key];
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
    if (value == null) {
      values.remove(key);
      return;
    }
    values[key] = value;
  }
}

class _Transport implements SessionTransport {
  _Transport(this._engine);

  final XtermTerminalEngine _engine;
  int closes = 0;

  @override
  bool get isClosed => closes != 0;

  @override
  void Function()? onClosed;

  @override
  void resize(TerminalSize size) {}

  @override
  Future<void> close() async {
    closes++;
    await _engine.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late _Keystore keystore;
  late TestDeviceAuthenticator device;
  late Duration elapsed;
  final states = <AppState>[];

  File file(String name) => File('${directory.path}/$name');

  Future<AppState> launch([AppLockMode? mode]) async {
    if (mode != null) {
      final store = SettingsStore(file('settings.json'));
      final settings = await store.load();
      settings.appLock = mode;
      await store.save(settings);
    }
    final services = await AppServices.initialize(
      masterKeyManager: MasterKeyManager(keystore),
      deviceAuthenticator: device,
      appLockElapsed: () => elapsed,
    );
    final state = AppState(services);
    states.add(state);
    return state;
  }

  ServerConfig server(
    AuthMethod method, {
    String? ref = 'saved',
    String? path,
  }) => ServerConfig(
    id: 'server',
    label: 'prod',
    host: 'prod.example',
    username: 'user',
    authMethod: method,
    secretRef: ref,
    identityFilePath: path,
    createdAt: 1,
    updatedAt: 1,
  );

  void timeout(AppState state) {
    state.onAppLifecycle(AppLifecycleState.hidden);
    elapsed += appLockBackgroundTimeout;
    state.onAppLifecycle(AppLifecycleState.resumed);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-lock-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (_) async => directory.path);
    keystore = _Keystore();
    device = TestDeviceAuthenticator();
    elapsed = Duration.zero;
  });

  tearDown(() async {
    for (final state in states) {
      state.dispose();
      await state.services.probe.dispose();
    }
    states.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    await directory.delete(recursive: true);
  });

  test('default off preserves saved credentials and never prompts', () async {
    final state = await launch();
    await state.services.vault.putSecret(_savedSecret);
    expect(
      (await state.services.resolveCredentials(
        server(AuthMethod.password),
      )).password,
      'password',
    );
    expect(device.prompts, 0);
  });

  test('app-lock changes and timeout preserve existing SSH sessions', () async {
    final state = await launch();
    final engine = XtermTerminalEngine();
    final transport = _Transport(engine);
    final tab = TerminalSession(
      id: 'live',
      serverId: 'server',
      config: server(AuthMethod.password),
      engine: engine,
      connecting: false,
    )..session = transport;
    state.tabs.add(tab);
    await state.setAppLock(AppLockMode.on);
    timeout(state);
    expect(state.services.appLock.requiresAuthentication, isTrue);
    expect(tab.isConnected, isTrue);
    expect(tab.session, same(transport));
    expect(transport.closes, 0);
    await state.setAppLock(AppLockMode.off);
    expect(state.tabs.single, same(tab));
    expect(transport.closes, 0);
  });

  test(
    'locked launch defers keystore and concurrent reads share its unlock',
    () async {
      final state = await launch(AppLockMode.on);
      expect(keystore.reads, 0);
      final answer = Completer<void>();
      device.onAuthenticate = () => answer.future;
      final reads = [
        state.services.resolveCredentials(server(AuthMethod.password)),
        state.services.resolveCredentials(server(AuthMethod.password)),
      ];
      final failures = [
        for (final read in reads)
          expectLater(read, throwsA(isA<CredentialMissingException>())),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(device.prompts, 1);
      expect(keystore.reads, 0);
      answer.complete();
      await Future.wait(failures);
      expect(keystore.masterReads, 1);
      expect(
        state.services.vaultKey,
        base64Decode(keystore.values[_masterKeyName]!),
      );
    },
  );

  test(
    'rejected launch read is auth failure, not missing or damaged data',
    () async {
      final original = (await launch()).services;
      await original.vault.putSecret(_savedSecret);
      final bytes = await file('vault.json').readAsBytes();
      final state = await launch(AppLockMode.on);
      keystore.reads = 0;
      device.reject();
      await expectLater(
        state.services.resolveCredentials(server(AuthMethod.password)),
        throwsA(isA<AppLockException>()),
      );
      await expectLater(
        state.services.vault.readableSecret('saved'),
        throwsA(isA<AppLockException>()),
      );
      expect(keystore.reads, 0);
      expect(await file('vault.json').readAsBytes(), bytes);
      device.onAuthenticate = null;
      expect(
        (await state.services.resolveCredentials(
          server(AuthMethod.password),
        )).password,
        'password',
      );
    },
  );

  test(
    'keystore API keys, assistant and sync/inbox refuse before reads',
    () async {
      final state = await launch(AppLockMode.on);
      final services = state.services;
      services.settings.syncBaseUrl = 'https://sync.example';
      services.settings.llmApiKeyRef = 'anthropic';
      services.settings.braveApiKeyRef = 'brave';
      keystore.values['seance.apikey.anthropic'] = 'api-key';
      device.reject();
      for (final action in <Future<Object?> Function()>[
        () => services.masterKeys.getApiKey('anthropic'),
        services.buildLlmProvider,
        services.buildSearchProvider,
        services.runSync,
        () => services.withInbox((_) async => 'inbox'),
        () => LocalSettingsBackend(state).fetchModels(
          const ModelQuery(
            kind: LlmProviderKind.anthropic,
            baseUrl: 'https://llm.example',
            model: 'model',
            typedApiKey: '',
          ),
        ),
      ]) {
        await expectLater(action(), throwsA(isA<AppLockException>()));
      }
      expect(keystore.reads, 0);
      expect(services.masterKeys.keystoreStatus, KeystoreStatus.unknown);
    },
  );

  test(
    'stored key and referenced identity file both require the gate',
    () async {
      final seed = (await launch()).services;
      await seed.vault.putSecret(
        const Secret(
          id: 'pem',
          kind: SecretKind.privateKey,
          value: 'PEM',
          keyPassphrase: 'phrase',
          updatedAt: 1,
        ),
      );
      await file('identity').writeAsString('FILE PEM');
      final services = (await launch(AppLockMode.on)).services;
      device.reject();
      await expectLater(
        services.resolveCredentials(server(AuthMethod.privateKey, ref: 'pem')),
        throwsA(isA<AppLockException>()),
      );
      await expectLater(
        services.resolveCredentials(
          server(AuthMethod.privateKey, ref: null, path: file('identity').path),
        ),
        throwsA(isA<AppLockException>()),
      );
      device.onAuthenticate = null;
      final stored = await services.resolveCredentials(
        server(AuthMethod.privateKey, ref: 'pem'),
      );
      expect(stored.privateKeyPem, 'PEM');
      expect(stored.keyPassphrase, 'phrase');
      expect(
        (await services.resolveCredentials(
          server(AuthMethod.privateKey, ref: null, path: file('identity').path),
        )).privateKeyPem,
        'FILE PEM',
      );
    },
  );

  test('agent and newly typed credentials require no saved read', () async {
    final services = (await launch(AppLockMode.on)).services;
    device.reject();
    expect(
      (await services.resolveCredentials(server(AuthMethod.agent))).method,
      AuthMethod.agent,
    );
    expect(
      (await services.resolveCredentials(
        server(AuthMethod.password),
        draftPassword: 'typed',
      )).password,
      'typed',
    );
    expect(
      (await services.resolveCredentials(
        server(AuthMethod.privateKey),
        draftPrivateKey: 'typed PEM',
      )).privateKeyPem,
      'typed PEM',
    );
    expect(device.prompts, 0);
    expect(keystore.reads, 0);
  });

  test(
    'rejected recovery, export, restore and rekey leave stores intact',
    () async {
      final seed = (await launch()).services;
      await seed.vault.putSecret(_savedSecret);
      final code = seed.newRecoveryCode();
      await seed.saveRecoveryCode(code);
      final export = await seed.exportSecrets();
      final bytes = await file('vault.json').readAsBytes();
      final keys = Map.of(keystore.values);
      final services = (await launch(AppLockMode.on)).services;
      device.reject();
      for (final action in <Future<Object?> Function()>[
        services.recoveryConfigured,
        services.exportSecrets,
        () => services.saveRecoveryCode(services.newRecoveryCode()),
        () => services.restoreSecrets(
          export,
          code,
          policy: RestoreConflictPolicy.replaceExisting,
        ),
        () => services.rekeyVaultForTesting(List.filled(32, 42)),
        services.vault.store.allSecretBlobs,
      ]) {
        await expectLater(action(), throwsA(isA<AppLockException>()));
      }
      expect(await file('vault.json').readAsBytes(), bytes);
      expect(keystore.values, keys);
      expect(await file('vault.json.rekey').exists(), isFalse);
      device.onAuthenticate = null;
      await services.rekeyVaultForTesting(List.filled(32, 42));
      expect(
        (await SecretsExport.open(
          await services.exportSecrets(),
          code,
        )).secrets['saved']!.value,
        'password',
      );
      expect(
        (await services.restoreSecrets(
          export,
          code,
          policy: RestoreConflictPolicy.keepExisting,
        )).kept,
        1,
      );
    },
  );

  test(
    'a pending rekey journal is untouched until launch auth succeeds',
    () async {
      final seed = (await launch()).services;
      await seed.vault.putSecret(_savedSecret);
      final store = FileVaultStore(file('vault.json'));
      final newKey = List.filled(32, 42);
      await store.stageRekey(currentKey: seed.vaultKey!, newKey: newKey);
      await seed.masterKeys.setKeystoreKey(newKey);
      final journal = await file('vault.json.rekey').readAsBytes();
      final state = await launch(AppLockMode.on);
      device.reject();
      await expectLater(
        state.services.resolveCredentials(server(AuthMethod.password)),
        throwsA(isA<AppLockException>()),
      );
      expect(await file('vault.json.rekey').readAsBytes(), journal);
      device.onAuthenticate = null;
      expect(
        (await state.services.resolveCredentials(
          server(AuthMethod.password),
        )).password,
        'password',
      );
      expect(await file('vault.json.rekey').exists(), isFalse);
    },
  );

  test(
    'startup cancellation shows an error and keeps retry available',
    () async {
      final state = await launch(AppLockMode.on);
      state.services.settings.llmApiKeyRef = 'anthropic';
      keystore.values['seance.apikey.anthropic'] = 'api-key';
      device.reject();
      await state.load();
      expect(state.credentialAccessError, 'Auth cancelled');
      expect(state.llmConfigured, isFalse);
      expect(device.prompts, 1);
      device.onAuthenticate = null;
      await state.onVaultUnlocked();
      expect(state.llmConfigured, isTrue);
      expect(state.credentialAccessError, isNull);
    },
  );

  test('manual inbox refresh reports cancellation and allows retry', () async {
    final state = await launch(AppLockMode.on);
    state.services.settings.syncBaseUrl = 'https://sync.example';
    device.reject();
    await state.refreshInbox();
    expect(state.inboxError, 'Auth cancelled');
    expect(keystore.reads, 0);
    device.onAuthenticate = null;
    await state.refreshInbox();
    expect(state.inboxError, isNull);
  });

  test(
    'local backend authenticates both transitions and rejects atomically',
    () async {
      final state = await launch();
      final backend = LocalSettingsBackend(state);
      device.reject();
      await expectLater(
        backend.setAppLock(AppLockMode.on),
        throwsA(isA<AppLockException>()),
      );
      expect(backend.settings.appLock, AppLockMode.off);
      expect(
        (await state.services.settingsStore.load()).appLock,
        AppLockMode.off,
      );
      device.onAuthenticate = null;
      await backend.setAppLock(AppLockMode.on);
      expect(
        (await state.services.settingsStore.load()).appLock,
        AppLockMode.on,
      );
      device.reject();
      await expectLater(
        backend.setAppLock(AppLockMode.off),
        throwsA(isA<AppLockException>()),
      );
      expect(backend.settings.appLock, AppLockMode.on);
      expect(
        (await state.services.settingsStore.load()).appLock,
        AppLockMode.on,
      );
      timeout(state);
      await expectLater(
        state.services.masterKeys.getApiKey('anthropic'),
        throwsA(isA<AppLockException>()),
      );
      device.onAuthenticate = null;
      await backend.setAppLock(AppLockMode.off);
      expect(
        (await state.services.settingsStore.load()).appLock,
        AppLockMode.off,
      );
    },
  );

  test('unsupported device refuses enable without writing', () async {
    device.supported = AppLockAvailability.unavailable;
    final state = await launch();
    final backend = LocalSettingsBackend(state);
    expect(backend.appLockAvailability, AppLockAvailability.unavailable);
    await expectLater(
      backend.setAppLock(AppLockMode.on),
      throwsA(isA<AppLockException>()),
    );
    expect(backend.settings.appLock, AppLockMode.off);
    expect(device.prompts, 0);
  });

  test(
    'failed settings write rolls back the choice and keeps queue usable',
    () async {
      final state = await launch();
      final backend = LocalSettingsBackend(state);
      await backend.setAppLock(AppLockMode.on);
      await file('settings.json').delete();
      await Directory(file('settings.json').path).create();
      await expectLater(
        backend.setAppLock(AppLockMode.off),
        throwsA(isA<FileSystemException>()),
      );
      expect(state.services.settings.appLock, AppLockMode.on);
      await Directory(file('settings.json').path).delete();
      await state.services.saveSettings();
      timeout(state);
      expect(state.services.appLock.requiresAuthentication, isTrue);
      await backend.setAppLock(AppLockMode.off);
      expect(
        (await state.services.settingsStore.load()).appLock,
        AppLockMode.off,
      );
    },
  );
}
