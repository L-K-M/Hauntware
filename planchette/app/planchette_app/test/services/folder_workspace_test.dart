import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/folder_workspace.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

class _DelayedFileSystem extends LocalFileSystem {
  final requests = <String, Completer<List<RemoteFileEntry>>>{};
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) {
    final request = requests[path];
    return request?.future ?? super.listDirectory(path);
  }
}

class _RemoteFiles extends LocalFileSystem {
  @override
  Future<String> canonicalize(String path) async => path;
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async => [];
}

class _Channel implements PaneChannel {
  _Channel({this.broken = false});
  final bool broken;
  @override
  RemoteFileSystem get fs =>
      broken ? throw StateError('Disconnected') : _RemoteFiles();
  @override
  String get homePath => '/home/user';
  @override
  Future<void> close() async {}
  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

void main() {
  late Directory directory;
  late FolderWorkspace workspace;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planchette-folders-');
    workspace = FolderWorkspace();
  });
  tearDown(() async {
    workspace.dispose();
    await directory.delete(recursive: true);
  });

  test(
    'lists local folders first and preserves the selected root boundary',
    () async {
      await File(paths.join(directory.path, 'notes.txt')).writeAsString('text');
      await File(paths.join(directory.path, '.config')).writeAsString('hidden');
      final sub = await Directory(paths.join(directory.path, 'src')).create();
      await workspace.openLocal(directory.path);
      expect(workspace.entries.map((entry) => entry.name), [
        'src',
        'notes.txt',
      ]);
      workspace.toggleHidden();
      expect(workspace.entries.map((entry) => entry.name), contains('.config'));
      await workspace.navigate(sub.path);
      expect(workspace.canGoUp, isTrue);
      await workspace.up();
      expect(workspace.path, directory.path);
      expect(workspace.canGoUp, isFalse);
      await workspace.navigate(directory.parent.path);
      expect(workspace.path, directory.path);
      expect(workspace.error, contains('inside this workspace'));
      await workspace.refresh();
      expect(workspace.error, isNull);
    },
  );

  test('a slower listing cannot replace a newer folder', () async {
    workspace.dispose();
    final fs = _DelayedFileSystem();
    workspace = FolderWorkspace(localFileSystem: fs);
    final a = await Directory(paths.join(directory.path, 'a')).create();
    final b = await Directory(paths.join(directory.path, 'b')).create();
    await workspace.openLocal(directory.path);
    fs.requests[a.path] = Completer();
    final slow = workspace.navigate(a.path);
    await workspace.navigate(b.path);
    fs.requests[a.path]!.complete([]);
    await slow;
    expect(workspace.path, b.path);
    expect(workspace.loading, isFalse);
  });

  test('failed replacement keeps the previous workspace usable', () async {
    await workspace.openLocal(directory.path);
    await workspace.openLocal(paths.join(directory.path, 'missing'));
    expect(workspace.root, directory.path);
    expect(workspace.error, isNotNull);
    await workspace.refresh();
    expect(workspace.error, isNull);
    await workspace.close();
    expect(workspace.isOpen, isFalse);
  });

  const server = ServerConfig(
    id: 'server',
    label: 'Server',
    host: 'host',
    username: 'user',
    authMethod: AuthMethod.agent,
    createdAt: 0,
    updatedAt: 0,
  );

  test('remote start directory expands home-relative paths', () async {
    await workspace.openRemote(
      server,
      _Channel(),
      const Stream.empty(),
      root: '~/sites',
    );
    expect(workspace.root, '/home/user/sites');
  });

  test(
    'failed channel acquisition leaves the existing browser retryable',
    () async {
      await workspace.openLocal(directory.path);
      await workspace.openRemote(
        server,
        _Channel(broken: true),
        const Stream.empty(),
      );
      expect(workspace.root, directory.path);
      expect(workspace.loading, isFalse);
      expect(workspace.error, contains('Disconnected'));
    },
  );
}
