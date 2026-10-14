import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// Import SSH config saves the hosts the importer reads and reports the ones
/// it leaves out, so the toast can count them.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  late AppState state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-ssh-import-');
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

  test('saves valid hosts and counts the ones with a bad Port', () async {
    final result = await state.importSshConfig('''
Host web
  HostName = web.example.com
  Port ssh

Host typo
  HostName typo.example.com
  Port 22a
''');

    expect(result, (imported: 1, skipped: 1));
    expect(state.servers.map((s) => (s.label, s.host, s.port)), [
      ('web', 'web.example.com', 22),
    ]);
  });
}
