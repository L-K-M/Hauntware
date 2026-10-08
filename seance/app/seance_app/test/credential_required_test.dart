import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
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
}
