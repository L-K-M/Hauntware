import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/theme.dart';
import 'package:seance_app/ui/server_actions.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The server list's verbs: duplicate, pin and the SSH config import.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  late AppState state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-actions-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    state = AppState(services);
  });

  tearDown(() async {
    state.dispose();
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    await directory.delete(recursive: true);
  });

  testWidgets("the Duplicate toast's Edit opens no copy once Undo removed it", (
    tester,
  ) async {
    const server = ServerConfig(
      id: 'web',
      label: 'web',
      host: 'web.example.com',
      username: 'deploy',
      createdAt: 1,
      updatedAt: 1,
    );
    await tester.runAsync(() => state.saveServer(server));
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: SeanceTheme.light(platform: TargetPlatform.macOS),
        home: AppScope(
          state: state,
          child: Scaffold(
            body: Builder(
              builder: (inner) {
                context = inner;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      ),
    );

    await tester.runAsync(
      () => duplicateServerInteractively(context, state, server),
    );
    await tester.pump();
    expect(find.text('Duplicated as "web copy"'), findsOneWidget);

    await tester.runAsync(state.undoHistory.undo);
    await tester.pump();
    expect(state.servers.map((s) => s.label), ['web']);

    await tester.tap(find.text('Edit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(Dialog), findsNothing);
  });
}
