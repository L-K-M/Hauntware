import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/ui/server_actions.dart';

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
Host web www
  HostName = web.example.com
  Port ssh

Host typo
  HostName typo.example.com
  Port 22a
''');

    expect(result, (imported: 2, skipped: 1));
    expect(
      state.servers.map((s) => (s.label, s.host, s.port)),
      unorderedEquals([
        ('web', 'web.example.com', 22),
        ('www', 'web.example.com', 22),
      ]),
    );
  });

  group('a picked file', () {
    test('reads as its text', () async {
      final file = File('${directory.path}/config')
        ..writeAsStringSync('Host web\n  HostName web.example.com\n');
      final read = await readSshConfigFile(file);
      expect(read.text, contains('web.example.com'));
      expect(read.rejection, isNull);
    });

    test('that is not UTF-8 is turned away as no SSH config', () async {
      // A private key or other binary file picked by mistake.
      final file = File('${directory.path}/id_ed25519')
        ..writeAsBytesSync([0xff, 0xfe, 0x00, 0x80, 0xc3]);
      final read = await readSshConfigFile(file);
      expect(read.text, isNull);
      expect(read.rejection, 'That file is not an SSH config.');
    });

    test('too large to be a config is turned away unread', () async {
      final file = File('${directory.path}/big')
        ..writeAsBytesSync(List.filled(1024 * 1024 + 1, 0x20));
      final read = await readSshConfigFile(file);
      expect(read.text, isNull);
      expect(read.rejection, 'That file is too large to be an SSH config.');
    });
  });
}
