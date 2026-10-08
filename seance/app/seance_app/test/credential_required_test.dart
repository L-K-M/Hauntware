import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/missing_credential.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _menuChannel = MethodChannel('seance/menu');

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
      ..setMockMethodCallHandler(_menuChannel, null);
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
  Future<void> boot() async {
    directory = await Directory.systemTemp.createTemp('seance-cred-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(_pathChannel, (_) async => directory!.path)
      ..setMockMethodCallHandler(_menuChannel, (_) async => null);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services!);
    await state!.saveServer(server);
  }

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
