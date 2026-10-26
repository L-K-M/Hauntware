import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// TrueNAS's zsh reports nothing: no OSC 7, no title. Once connected, the
/// tab and the Git pane still learn where it is, from one read beside it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late AppServices services;
  AppState? state;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-silent-shell-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
  });

  tearDown(() async {
    state?.dispose();
    state = null;
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
  });

  test(
    'the tab and the Git pane follow a shell that reports nothing',
    () async {
      final commands = <String>[];
      final app = state = AppState(
        services,
        openSshSession:
            (
              manager, {
              required config,
              required credentials,
              required engine,
              log,
            }) async => _SilentShellSession(engine, commands),
      );
      app.servers = [
        ServerConfig(
          id: 'nas',
          label: 'nas',
          host: 'truenas.local',
          username: 'truenas_admin',
          createdAt: 1,
          updatedAt: 1,
        ),
      ];

      await app.newTab(app.servers.single);
      final tab = app.tabs.single as TerminalSession;
      expect(tab.error, isNull);
      expect(tab.git, isNotNull, reason: 'connected');
      await _until(() => tab.metadata.value.workingDirectory == '/mnt/tank');

      expect(tab.git!.reportedDirectory, '/mnt/tank');
      expect(commands, hasLength(1), reason: 'one read serves every consumer');
    },
  );
}

/// A connected session whose shell is in `/mnt/tank` and says nothing; every
/// command is the directory read.
class _SilentShellSession implements SshSession {
  _SilentShellSession(this.engine, this.commands);

  @override
  final TerminalEngine engine;

  final List<String> commands;

  @override
  void Function()? onClosed;

  @override
  bool get isClosed => false;

  @override
  Future<RemoteCommandResult> runCommand(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
  }) async {
    commands.add(command);
    return const RemoteCommandResult(
      stdout: 'seance-cwd\n/mnt/tank\n',
      exitCode: 0,
    );
  }

  @override
  Future<RemoteFileSystem> openRemoteFileSystem({
    Duration timeout = const Duration(seconds: 15),
  }) => throw UnimplementedError('no Files pane in this test');

  @override
  void resize(TerminalSize size) {}

  @override
  Future<void> close() => engine.dispose();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Waits in real time until [condition] holds: the read runs on the
/// connection's own schedule.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('the condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
