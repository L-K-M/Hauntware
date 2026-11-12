import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/missing_credential.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_app/ui/credential_prompt.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _menuChannel = MethodChannel('seance/menu');
const _bookmarkChannel = MethodChannel('seance/secure_bookmarks');

// Keep widget routing independent of filesystem futures in fake-async.
// The real vault writes and retry credential consumption are tested below.
class _PromptTestState extends AppState {
  _PromptTestState(
    super.services,
    SshSessionOpener opener,
    bool Function(String, String) checker,
  ) : super(openSshSession: opener, keyPassphraseChecker: checker);

  int reconnects = 0;
  Object? passphraseError;
  final providedServers = <String>[];
  ({String serverId, String passphrase})? lastPassphrase;

  @override
  Future<bool> provideKeyPassphrase(
    String serverId,
    KeyPassphraseAnswer answer,
  ) async {
    providedServers.add(serverId);
    if (passphraseError case final error?) throw error;
    return answer.passphrase == 'right';
  }

  @override
  Future<void> reconnect(
    String sessionId, {
    ({String serverId, String passphrase})? keyPassphrase,
  }) async {
    reconnects++;
    lastPassphrase = keyPassphrase;
  }
}

/// CRED-05: a server saved on another device without its password reaches
/// this one as a reference to a vault entry that is not here. Connecting
/// says so before any network attempt and offers the server's editor.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(_pathChannel, null)
      ..setMockMethodCallHandler(_menuChannel, null)
      ..setMockMethodCallHandler(_bookmarkChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    directory = null;
  });

  final server = ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.invalid',
    username: 'deploy',
    authMethod: AuthMethod.password,
    secretRef: 'saved-elsewhere',
    createdAt: 1,
    updatedAt: 1,
  );

  testWidgets('a missing password is a setup step, not a failed network', (
    tester,
  ) async {
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-cred-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        ..setMockMethodCallHandler(_pathChannel, (_) async => directory!.path)
        ..setMockMethodCallHandler(_menuChannel, (_) async => null);
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(server);
      await state!.newTab(server);
    });
    final tab = state!.tabs.whereType<TerminalSession>().single;
    expect(tab.missingCredentialServerId, 'box');
    // Nothing reached the network: the log never started a handshake.
    expect(tab.session, isNull);

    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: TerminalPane(onBack: () {}),
      ),
    );
    await tester.pump();

    expect(find.text('Credential required on this device'), findsOneWidget);
    expect(find.text('Connection failed'), findsNothing);
    expect(find.textContaining('"box" was saved on another device'),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('connection.editServer')));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
  });

  /// A device with [server] saved and its credential missing.
  Future<void> boot({
    SshSessionOpener? opener,
    bool Function(String, String)? passphraseChecker,
    bool stubReconnect = false,
  }) async {
    directory = await Directory.systemTemp.createTemp('seance-cred-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(_pathChannel, (_) async => directory!.path)
      ..setMockMethodCallHandler(_menuChannel, (_) async => null);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = stubReconnect
        ? _PromptTestState(
            services!,
            opener!,
            passphraseChecker ?? privateKeyPassphraseOpens,
          )
        : opener == null
        ? AppState(
            services!,
            keyPassphraseChecker:
                passphraseChecker ?? privateKeyPassphraseOpens,
          )
        : AppState(
            services!,
            openSshSession: opener,
            keyPassphraseChecker:
                passphraseChecker ?? privateKeyPassphraseOpens,
          );
    await state!.saveServer(server);
  }

  Future<void> pumpErrorPane(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: TerminalPane(onBack: () {}),
      ),
    );
    await tester.pump();
  }

  Future<void> waitForUi(WidgetTester tester, bool Function() ready) async {
    for (var step = 0; step < 100; step++) {
      await tester.pump(const Duration(milliseconds: 20));
      if (ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('The expected credential UI did not appear.');
  }

  testWidgets('an encrypted key failure offers a passphrase-only prompt', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await boot(
        opener:
            (
              manager, {
              required config,
              required credentials,
              required engine,
              log,
            }) async => throw SshConnectException(
              'A passphrase is required.',
              StateError('locked key'),
              log ?? SshConnectionLog(),
              kind: SshConnectFailureKind.keyPassphraseRequired,
            ),
      );
      final keyServer = server.copyWith(authMethod: AuthMethod.privateKey);
      await state!.saveServer(
        keyServer,
        secret: const Secret(
          id: 'saved-elsewhere',
          kind: SecretKind.privateKey,
          value: 'PEM',
        ),
      );
      await state!.newTab(keyServer);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: TerminalPane(onBack: () {}),
      ),
    );
    await tester.pump();

    expect(find.text('Key passphrase required'), findsOneWidget);
    await tester.tap(find.text('Enter passphrase…'));
    await tester.pumpAndSettle();
    expect(find.text('Key passphrase for box'), findsOneWidget);
    expect(find.text('Private key (PEM)'), findsNothing);
    expect(find.widgetWithText(TextField, 'Passphrase'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Key passphrase for box'), findsNothing);
  });

  testWidgets('a wrong passphrase reasks before one ephemeral reconnect', (
    tester,
  ) async {
    final attempts = <String?>[];
    await tester.runAsync(() async {
      await boot(
        stubReconnect: true,
        passphraseChecker: (pem, phrase) => phrase == 'right',
        opener:
            (
              manager, {
              required config,
              required credentials,
              required engine,
              log,
            }) async {
              attempts.add(credentials.keyPassphrase);
              throw SshConnectException(
                'No test transport',
                StateError('closed'),
                log ?? SshConnectionLog(),
                kind: credentials.keyPassphrase == null
                    ? SshConnectFailureKind.keyPassphraseRequired
                    : SshConnectFailureKind.unreachable,
              );
            },
      );
      final keyServer = server.copyWith(authMethod: AuthMethod.privateKey);
      await state!.saveServer(
        keyServer,
        secret: const Secret(
          id: 'saved-elsewhere',
          kind: SecretKind.privateKey,
          value: 'PEM',
        ),
      );
      await state!.newTab(keyServer);
    });
    await pumpErrorPane(tester);
    await tester.tap(find.text('Enter passphrase…'));
    await tester.pumpAndSettle();
    final field = find.widgetWithText(TextField, 'Passphrase');
    await tester.enterText(field, 'wrong');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await waitForUi(
        tester,
        () => find
            .text('That passphrase did not open the key. Try again.')
            .evaluate()
            .isNotEmpty,
      );
    });
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(attempts, [null]);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);

    await tester.enterText(field, 'right');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await waitForUi(
        tester,
        () => (state! as _PromptTestState).reconnects == 1,
      );
    });
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    final retried = state! as _PromptTestState;
    expect(retried.reconnects, 1);
    expect(retried.providedServers, ['box', 'box']);
    expect(retried.lastPassphrase, (serverId: 'box', passphrase: 'right'));
    expect(attempts, [null]);

    // A lower-level failure may include input in its diagnostic text.
    retried.passphraseError = StateError('key opener echoed: right');
    await tester.tap(find.text('Enter passphrase…'));
    await tester.pumpAndSettle();
    await tester.enterText(field, 'right');
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await waitForUi(tester, () => retried.providedServers.length == 3);
    });
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(find.textContaining('key opener echoed: right'), findsNothing);
    expect(
      find.text('Could not unlock or save this key. Try again.'),
      findsOneWidget,
    );
    expect(retried.reconnects, 1);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets(
    'the file-key prompt keeps secret input private and maps its save offer',
    (tester) async {
      KeyPassphraseAnswer? answer;
      final fileServer = server.copyWith(
        authMethod: AuthMethod.privateKey,
        identityFilePath: '~/.ssh/id_ed25519',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                answer = await showKeyPassphraseDialog(
                  context,
                  server: fileServer,
                );
              },
              child: const Text('Ask'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Ask'));
      await tester.pumpAndSettle();
      expect(find.text('~/.ssh/id_ed25519'), findsOneWidget);
      final field = find.widgetWithText(TextField, 'Passphrase');
      final input = tester.widget<TextField>(field);
      expect(input.obscureText, isTrue);
      expect(input.autocorrect, isFalse);
      expect(input.enableSuggestions, isFalse);
      expect(input.enableIMEPersonalizedLearning, isFalse);
      await tester.enterText(field, 'right');
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(answer!.passphrase, 'right');
      expect(answer!.saveToVault, isTrue);
    },
  );

  test('a rejected passphrase does not change the saved credential', () async {
    await boot(
      passphraseChecker: (pem, phrase) => pem == 'PEM' && phrase == 'right',
    );
    await state!.saveServer(
      server.copyWith(authMethod: AuthMethod.privateKey),
      secret: const Secret(
        id: 'saved-elsewhere',
        kind: SecretKind.privateKey,
        value: 'PEM',
        keyPassphrase: 'old',
      ),
    );
    final before = await services!.vault.getSecret('saved-elsewhere');

    expect(
      await state!.provideKeyPassphrase(
        'box',
        const KeyPassphraseAnswer('wrong', saveToVault: true),
      ),
      isFalse,
    );

    final after = await services!.vault.getSecret('saved-elsewhere');
    expect(after!.keyPassphrase, 'old');
    expect(after.updatedAt, before!.updatedAt);
  });

  test(
    'saving a pasted-key passphrase advances only its credential slot',
    () async {
      await boot(
        passphraseChecker: (pem, phrase) => pem == 'PEM' && phrase == 'right',
      );
      await state!.saveServer(
        server.copyWith(authMethod: AuthMethod.privateKey),
        secret: const Secret(
          id: 'saved-elsewhere',
          kind: SecretKind.privateKey,
          value: 'PEM',
          keyPassphrase: 'old',
          identityFilePath: '/other/key',
          identityFilePassphrase: 'other-phrase',
        ),
      );
      final before = await services!.vault.getSecret('saved-elsewhere');

      expect(
        await state!.provideKeyPassphrase(
          'box',
          const KeyPassphraseAnswer('right', saveToVault: true),
        ),
        isTrue,
      );

      final after = (await services!.vault.getSecret('saved-elsewhere'))!;
      expect(after.value, 'PEM');
      expect(after.keyPassphrase, 'right');
      expect(after.identityFilePath, '/other/key');
      expect(after.identityFilePassphrase, 'other-phrase');
      expect(after.updatedAt, greaterThan(before!.updatedAt));
    },
  );

  test(
    'saving a file-key passphrase preserves the pasted key and path binding',
    () async {
      await boot(
        passphraseChecker: (pem, phrase) =>
            pem == 'FILE PEM' && phrase == 'right',
      );
      final file = File('${directory!.path}/identity');
      await file.writeAsString('FILE PEM');
      await state!.saveServer(
        server.copyWith(
          authMethod: AuthMethod.privateKey,
          identityFilePath: file.path,
        ),
        secret: Secret(
          id: 'saved-elsewhere',
          kind: SecretKind.privateKey,
          value: 'PASTED PEM',
          keyPassphrase: 'pasted-phrase',
          identityFilePath: file.path,
          identityFilePassphrase: 'old-file-phrase',
        ),
      );

      expect(
        await state!.provideKeyPassphrase(
          'box',
          const KeyPassphraseAnswer('right', saveToVault: true),
        ),
        isTrue,
      );

      final saved = (await services!.vault.getSecret('saved-elsewhere'))!;
      expect(saved.value, 'PASTED PEM');
      expect(saved.keyPassphrase, 'pasted-phrase');
      expect(saved.identityFilePath, file.path);
      expect(saved.identityFilePassphrase, 'right');
      final credentials = await services!.resolveCredentials(
        state!.servers.single,
      );
      expect(credentials.privateKeyPem, 'FILE PEM');
      expect(credentials.keyPassphrase, 'right');
    },
  );

  test(
    'saving a file-key passphrase keeps the grant for that path',
    () async {
      await boot(
        passphraseChecker: (pem, phrase) =>
            pem == 'FILE PEM' && phrase == 'right',
      );
      final file = File('${directory!.path}/identity');
      await file.writeAsString('FILE PEM');
      const grant = 'Z3JhbnQ=';
      final bookmark = IdentityFileBookmark(path: file.path, bookmark: grant);
      // A fake resolver standing in for the native NSOpenPanel bookmark: the
      // grant opens the picked file. It records the grants it was asked to
      // open, so the test can tell the grant was consulted.
      final resolved = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_bookmarkChannel, (call) async {
        if (call.method == 'resolveBookmark') {
          resolved.add(call.arguments['bookmark'] as String);
          return {'path': file.path, 'token': 'token'};
        }
        return null;
      });
      await state!.saveServer(
        server.copyWith(
          authMethod: AuthMethod.privateKey,
          identityFilePath: file.path,
        ),
        secret: Secret(
          id: 'saved-elsewhere',
          kind: SecretKind.privateKey,
          value: 'PASTED PEM',
          keyPassphrase: 'pasted-phrase',
          identityFilePath: file.path,
          identityFilePassphrase: 'old-file-phrase',
        ),
        identityFileBookmark: bookmark,
      );
      final before = await services!.vault.getSecret('saved-elsewhere');

      expect(
        await state!.provideKeyPassphrase(
          'box',
          const KeyPassphraseAnswer('right', saveToVault: true),
        ),
        isTrue,
      );

      // The grant opened the key, and the save kept it for the next connect
      // rather than clearing it. Only consulted where the platform has
      // security-scoped bookmarks.
      if (services!.identityBookmarks.isSupported) {
        expect(resolved, [grant]);
      }
      expect(services!.settings.identityFileBookmarks['box'], bookmark);
      final saved = (await services!.vault.getSecret('saved-elsewhere'))!;
      expect(saved.value, 'PASTED PEM');
      expect(saved.keyPassphrase, 'pasted-phrase');
      expect(saved.identityFilePath, file.path);
      expect(saved.identityFilePassphrase, 'right');
      expect(saved.updatedAt, greaterThan(before!.updatedAt));
    },
  );

  test(
    'saving a file-key passphrase drops a grant for a different path',
    () async {
      await boot(
        passphraseChecker: (pem, phrase) =>
            pem == 'FILE PEM' && phrase == 'right',
      );
      final file = File('${directory!.path}/identity');
      await file.writeAsString('FILE PEM');
      await state!.saveServer(
        server.copyWith(
          authMethod: AuthMethod.privateKey,
          identityFilePath: file.path,
        ),
        secret: Secret(
          id: 'saved-elsewhere',
          kind: SecretKind.privateKey,
          value: '',
          identityFilePath: file.path,
          identityFilePassphrase: 'old-file-phrase',
        ),
      );
      // A grant left over from a previous key file: the save points the
      // server at a different path, so it must not survive.
      services!.settings.identityFileBookmarks['box'] =
          const IdentityFileBookmark(path: '/keys/old', bookmark: 'stale');
      await services!.saveSettings();

      expect(
        await state!.provideKeyPassphrase(
          'box',
          const KeyPassphraseAnswer('right', saveToVault: true),
        ),
        isTrue,
      );

      expect(services!.settings.identityFileBookmarks['box'], isNull);
    },
  );

  test('saving a pasted-key passphrase drops a leftover file grant', () async {
    await boot(
      passphraseChecker: (pem, phrase) => pem == 'PEM' && phrase == 'right',
    );
    await state!.saveServer(
      server.copyWith(authMethod: AuthMethod.privateKey),
      secret: const Secret(
        id: 'saved-elsewhere',
        kind: SecretKind.privateKey,
        value: 'PEM',
        keyPassphrase: 'old',
      ),
    );
    services!.settings.identityFileBookmarks['box'] =
        const IdentityFileBookmark(path: '/keys/old', bookmark: 'stale');
    await services!.saveSettings();

    expect(
      await state!.provideKeyPassphrase(
        'box',
        const KeyPassphraseAnswer('right', saveToVault: true),
      ),
      isTrue,
    );

    expect(services!.settings.identityFileBookmarks['box'], isNull);
  });

  test('a connection-only passphrase is consumed by one retry', () async {
    final attempts = <String?>[];
    await boot(
      passphraseChecker: (pem, phrase) => phrase == 'right',
      opener:
          (
            manager, {
            required config,
            required credentials,
            required engine,
            log,
          }) async {
            attempts.add(credentials.keyPassphrase);
            throw SshConnectException(
              'No test transport',
              StateError('closed'),
              log ?? SshConnectionLog(),
              kind: credentials.keyPassphrase == 'right'
                  ? SshConnectFailureKind.unreachable
                  : SshConnectFailureKind.keyPassphraseWrong,
            );
          },
    );
    final keyServer = server.copyWith(authMethod: AuthMethod.privateKey);
    await state!.saveServer(
      keyServer,
      secret: const Secret(
        id: 'saved-elsewhere',
        kind: SecretKind.privateKey,
        value: 'PEM',
        keyPassphrase: 'old',
      ),
    );
    await state!.newTab(keyServer);
    final first = state!.tabs.whereType<TerminalSession>().single;
    expect(first.keyPassphraseFailureServerId, 'box');
    expect(
      await state!.provideKeyPassphrase(
        'box',
        const KeyPassphraseAnswer('right'),
      ),
      isTrue,
    );

    await state!.reconnect(
      first.id,
      keyPassphrase: (serverId: 'box', passphrase: 'right'),
    );
    final retried = state!.tabs.whereType<TerminalSession>().single;
    expect(retried.keyPassphraseFailureServerId, isNull);
    await state!.reconnect(retried.id);

    expect(attempts, ['old', 'right', 'old']);
    expect(
      (await services!.vault.getSecret('saved-elsewhere'))!.keyPassphrase,
      'old',
    );
  });

  test(
    'a jump host accepts an ephemeral passphrase without retaining it',
    () async {
      await boot();
      const jump = ServerConfig(
        id: 'jump',
        label: 'Jump',
        host: 'jump.invalid',
        username: 'deploy',
        authMethod: AuthMethod.privateKey,
        secretRef: 'jump-key',
        createdAt: 1,
        updatedAt: 1,
      );
      await state!.saveServer(
        jump,
        secret: const Secret(
          id: 'jump-key',
          kind: SecretKind.privateKey,
          value: 'PEM',
          keyPassphrase: 'old',
        ),
      );

      final once = await services!.resolveJumpHost(
        'jump',
        draftKeyPassphrase: 'right',
      );
      expect(once!.credentials.keyPassphrase, 'right');
      final again = await services!.resolveJumpHost('jump');
      expect(again!.credentials.keyPassphrase, 'old');
    },
  );

  test('a password given on the tab lands where the config points', () async {
    await boot();

    expect(
      await state!.provideMissingCredential(
        'box',
        const MissingPassword('hunter2'),
      ),
      isTrue,
    );

    expect(
      (await services!.vault.getSecret('saved-elsewhere'))!.value,
      'hunter2',
    );
    final saved = state!.servers.single;
    expect(saved.secretRef, 'saved-elsewhere');
    expect(saved.authMethod, AuthMethod.password);
    // Dated past the copy this device pulled, as an edit would be.
    expect(saved.updatedAt, greaterThan(server.updatedAt));
    // Resolving the server's credential works again.
    expect(await services!.resolveCredentials(saved), isNotNull);
  });

  test('a key given on the tab is stored with its passphrase', () async {
    await boot();

    await state!.provideMissingCredential(
      'box',
      const MissingPrivateKey('PEM', passphrase: 'pp'),
    );

    final secret = (await services!.vault.getSecret('saved-elsewhere'))!;
    expect(secret.kind, SecretKind.privateKey);
    expect(secret.value, 'PEM');
    expect(secret.keyPassphrase, 'pp');
    expect(state!.servers.single.authMethod, AuthMethod.privateKey);
  });

  test('a key given on the tab replaces a key-file path, as the editor does',
      () async {
    await boot();
    // A peer's edit pointed the server at a key file this device lacks.
    await state!.saveServer(
      server.copyWith(
        authMethod: AuthMethod.privateKey,
        identityFilePath: '/home/elsewhere/.ssh/id_ed25519',
        updatedAt: 2,
      ),
    );

    await state!.provideMissingCredential('box', const MissingPrivateKey('PEM'));

    // Otherwise the path would be read and the stored key never used.
    expect(state!.servers.single.identityFilePath, isNull);
  });

  test('the agent instead writes nothing and switches the server', () async {
    await boot();

    expect(
      await state!.provideMissingCredential('box', const UseSshAgent()),
      isFalse,
    );

    expect(await services!.vault.getSecret('saved-elsewhere'), isNull);
    expect(state!.servers.single.authMethod, AuthMethod.agent);
  });

  testWidgets('the tab asks for the credential in place', (tester) async {
    await tester.runAsync(() async {
      await boot();
      await state!.newTab(server);
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(),
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: TerminalPane(onBack: () {}),
      ),
    );
    await tester.pump();

    expect(find.text('Enter password…'), findsOneWidget);
    expect(find.byKey(const ValueKey('connection.useAgent')), findsOneWidget);
    expect(find.byKey(const ValueKey('connection.editServer')), findsOneWidget);

    await tester.tap(
      find.byKey(const ValueKey('connection.provideCredential')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Password for box'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('Password for box'), findsNothing);
  });
}
