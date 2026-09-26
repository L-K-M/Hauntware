import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/remote_files_controller.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/files_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');
const _remotePath = '/home/test/.env';

/// The files pane asks "`<name>` changed locally. Upload it?" when the
/// checkout watcher marks a copy dirty. An editor tab's save-and-upload
/// trips that same watcher, so the pane has to know the upload is already
/// running, whichever surface started it.
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
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    directory = null;
  });

  const server = ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  /// The files pane over a connected session whose remote holds [remote].
  Future<RemoteFilesController> pumpFilesPane(
    WidgetTester tester,
    _EnvFileSystem remote,
  ) async {
    late final RemoteFilesController files;
    final session = TerminalSession(
      id: 'tab',
      serverId: server.id,
      config: server,
      engine: XtermTerminalEngine(),
    );
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-prompt-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            _pathChannel,
            (call) async => directory!.path,
          );
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
      await state!.saveServer(server);
      files = RemoteFilesController(
        () async => remote,
        shellDirectory: session.engine.workingDirectory,
        managedFileStore: services!.managedRemoteFiles,
        serverId: session.serverId,
        editSessionId: session.editSessionId,
      );
      await files.initialize();
    });
    session
      ..session = _OpenSshSession(session.engine)
      ..files = files
      ..connecting = false;
    state!
      ..tabs.add(session)
      ..activeTabId = session.id;

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: const Scaffold(body: FilesPane()),
      ),
    );
    await tester.pump();
    return files;
  }

  Finder uploadPrompt() => find.textContaining('changed locally');

  testWidgets(
    'an editor save-and-upload does not also ask to upload the file',
    (tester) async {
      final remote = _EnvFileSystem();
      final files = await pumpFilesPane(tester, remote);
      final entry = files.entries.singleWhere((e) => e.path == _remotePath);
      final copy = (await tester.runAsync(
        () => files.checkoutRemoteFile(entry),
      ))!;
      await tester.pump();

      // The upload holds mid-transfer until the test has looked. The
      // completers belong to the real event loop the upload runs on: made
      // in the test's fake-async zone, their callbacks would never fire.
      late final Completer<void> release;
      late final Future<bool> upload;
      await tester.runAsync(() async {
        final midUpload = Completer<void>();
        release = Completer<void>();
        remote.duringUpload = () async {
          midUpload.complete();
          await release.future;
        };
        // What the editor tab does on Save and upload: write the file,
        // then upload it through the shared helper.
        await files.localFile(copy).writeAsString('KEY=new\n');
        upload = uploadManagedLocalCopy(
          tester.element(find.byType(FilesPane)),
          files,
          copy,
          notifySuccess: false,
        );
        await midUpload.future;
        // The checkout watcher's reconcile for the save lands while the
        // upload runs and marks the copy dirty.
        await files.reconcileLocalCopies();
      });
      expect(files.localCopies[_remotePath]!.dirty, isTrue);
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      expect(uploadPrompt(), findsNothing);

      final uploaded = await tester.runAsync(() {
        release.complete();
        return upload;
      });
      expect(uploaded, isTrue);
      for (var i = 0; i < 3; i++) {
        await tester.pump();
      }
      expect(files.localCopies[_remotePath]!.dirty, isFalse);
      expect(uploadPrompt(), findsNothing);

      await tester.runAsync(() => files.removeLocalCopy(_remotePath));
    },
  );

  testWidgets('an edit made outside an upload still asks to upload it', (
    tester,
  ) async {
    final remote = _EnvFileSystem();
    final files = await pumpFilesPane(tester, remote);
    final entry = files.entries.singleWhere((e) => e.path == _remotePath);
    final copy = (await tester.runAsync(
      () => files.checkoutRemoteFile(entry),
    ))!;

    await tester.runAsync(() async {
      await files.localFile(copy).writeAsString('KEY=external\n');
      await files.reconcileLocalCopies();
    });
    await tester.pump();
    await tester.pump();
    expect(find.text('.env changed locally. Upload it?'), findsOneWidget);

    // Let the prompt's display timer run out before the tree goes away.
    await tester.pump(const Duration(seconds: 13));
    await tester.runAsync(() => files.removeLocalCopy(_remotePath));
  });
}

class _OpenSshSession implements SshSession {
  _OpenSshSession(this.engine);

  @override
  final TerminalEngine engine;

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => engine.dispose();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// `/home/test` holding one `.env`, uploadable, with a hook awaited
/// mid-upload so a test can look at the pane while the transfer runs.
class _EnvFileSystem implements RemoteFileSystem {
  RemoteFileEntry _file = const RemoteFileEntry(
    path: _remotePath,
    name: '.env',
    type: RemoteFileType.file,
    size: 8,
  );
  List<int> _bytes = 'KEY=old\n'.codeUnits;
  Future<void> Function()? duringUpload;

  @override
  Future<String> canonicalize(String path) async =>
      path == '.' ? '/home/test' : path;

  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async =>
      path == '/home/test' ? [_file] : const [];

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (path == _remotePath) return _file;
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'inspect',
      path: path,
      message: 'Not found',
    );
  }

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    destination.add(_bytes);
    onProgress?.call(_bytes.length, _bytes.length);
    return _file;
  }

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    final bytes = <int>[];
    await for (final chunk in content) {
      bytes.addAll(chunk);
    }
    await duringUpload?.call();
    _bytes = bytes;
    return _file = RemoteFileEntry(
      path: path,
      name: remoteBasename(path),
      type: RemoteFileType.file,
      size: bytes.length,
      modifiedAt: DateTime.utc(2026, 9, 26),
    );
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
