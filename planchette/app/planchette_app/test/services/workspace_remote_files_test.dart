import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:planchette_app/services/document_store.dart';
import 'package:planchette_app/services/document_workspace.dart';
import 'package:planchette_app/services/workspace_catalog.dart';
import 'package:planchette_app/services/workspace_remote_files.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import 'document_workspace_test.dart' show FakeDialogs;

class _Connections implements ConnectionManager {
  _Connections(this.root);
  final String root;
  final fs = LocalFileSystem();
  bool offline = false;
  final opened = <String>[];
  @override
  Future<PaneChannel> openBrowseChannel(
    String serverId, {
    required String paneTabId,
  }) async {
    opened.add(serverId);
    return _Browse(fs, root);
  }

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) async {
    if (offline) {
      throw const RemoteFileException(
        kind: RemoteFileErrorKind.disconnected,
        operation: 'connect',
        message: 'Disconnected',
      );
    }
    return _Lease(fs);
  }

  @override
  Stream<ServerStatus> watchServer(String serverId) =>
      Stream.value(const ServerStatus(ServerConnectionState.connected));
  @override
  Stream<ConnectLogLine> get connectLog => const Stream.empty();
  @override
  Future<Set<String>> connectedServerIds() async => opened.toSet();
  @override
  Future<void> disconnectServer(String serverId) async {}
  @override
  Future<void> removeBookmark(String serverId) async {}
}

class _Browse implements PaneChannel {
  _Browse(this.fs, this.homePath);
  @override
  final RemoteFileSystem fs;
  @override
  final String homePath;
  @override
  Future<void> close() async {}
  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

class _Lease implements TransferChannelLease {
  _Lease(this.fs);
  @override
  final RemoteFileSystem fs;
  @override
  AuthenticatedEndpointIdentity get endpointIdentity =>
      const AuthenticatedEndpointIdentity(
        host: 'server',
        port: 22,
        username: 'user',
        fingerprintSha256: 'SHA256:test',
      );
  @override
  Future<void> release() async {}
  @override
  void reportFailure(RemoteFileSystem source, RemoteFileException error) {}
}

class _NoPrompts implements WorkspaceConnectionPrompts {
  @override
  Future<bool> trustHost(HostKeyDecision decision) async =>
      throw StateError('Unexpected trust prompt');
  @override
  Future<CredentialDraft?> credentials(
    ServerConfig server,
    CredentialResolutionScope scope,
  ) async => throw StateError('Unexpected credential prompt');
  @override
  Future<List<String>> keyboardInteractive(
    KeyboardInteractiveChallenge challenge,
  ) async => throw StateError('Unexpected keyboard prompt');
}

void main() {
  late Directory directory;
  late File remote;
  late _Connections connections;
  late WorkspaceCatalog catalog;
  late WorkspaceRemoteFiles files;
  late DocumentWorkspace workspace;
  const server = ServerConfig(
    id: 'server-id',
    label: 'Production',
    host: 'server',
    username: 'user',
    authMethod: AuthMethod.agent,
    createdAt: 0,
    updatedAt: 0,
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('planchette-remote-');
    final root = await Directory(paths.join(directory.path, 'remote')).create();
    remote = await File(
      paths.join(root.path, 'config.txt'),
    ).writeAsString('original');
    connections = _Connections(root.path);
    catalog = WorkspaceCatalog(
      directory: Directory(paths.join(directory.path, 'catalog')),
    );
    workspace = DocumentWorkspace(
      store: LocalDocumentStore(),
      dialogs: FakeDialogs(),
    );
    files = WorkspaceRemoteFiles(
      directory: Directory(paths.join(directory.path, 'managed')),
      catalog: catalog,
      prompts: _NoPrompts(),
      connections: connections,
      isDocumentOpen: (path) => workspace.tabForPath(path) != null,
    );
  });
  tearDown(() async {
    workspace.dispose();
    await files.close();
    catalog.dispose();
    await directory.delete(recursive: true);
  });

  Future<
    ({RemoteWorkspaceConnection connection, RemoteWorkspaceDocument document})
  >
  open() async {
    final connection = await files.connect(server, windowId: 'window-1');
    final entry = await connections.fs.stat(remote.path);
    final copy = await files.openFile(connection.server, entry);
    await workspace.openManaged(copy.path, copy.publication);
    return (connection: connection, document: copy);
  }

  test(
    'guarded local save publishes through the managed checkout queue',
    () async {
      await open();
      final tab = workspace.active!;
      expect(tab.displayPath, contains('user@server:22'));
      tab.editor.text.text = 'edited';
      expect(await workspace.save(tab), isTrue);
      expect(await remote.readAsString(), 'edited');
      expect(tab.hasUnsavedChanges, isFalse);
      expect(files.localCopies(), completion(isEmpty));
    },
  );

  test('server/path checkout is shared across windows', () async {
    final opened = await open();
    final second = await files.connect(server, windowId: 'window-2');
    final copy = await files.openFile(
      second.server,
      await connections.fs.stat(remote.path),
    );
    expect(copy.path, opened.document.path);
    expect(copy.publication, same(opened.document.publication));
  });

  test(
    'a managed copy replaced by a symlink never opens its local target',
    () async {
      if (Platform.isWindows) return;
      final connection = await files.connect(server, windowId: 'window-1');
      final copy = await files.openFile(
        connection.server,
        await connections.fs.stat(remote.path),
      );
      final target = await File(
        paths.join(directory.path, 'private.txt'),
      ).writeAsString('private data');
      await File(copy.path).delete();
      await Link(copy.path).create(target.path);
      await workspace.openManaged(copy.path, copy.publication);
      expect(workspace.documents, isEmpty);
      expect(workspace.error, isNotNull);
      expect(await target.readAsString(), 'private data');
    },
  );

  test(
    'same-metadata remote tamper blocks upload and keeps local edits',
    () async {
      await open();
      final modified = await remote.lastModified();
      await remote.writeAsString('tampered');
      await remote.setLastModified(modified);
      final tab = workspace.active!;
      tab.editor.text.text = 'my edits';
      expect(await workspace.save(tab), isFalse);
      expect(await remote.readAsString(), 'tampered');
      expect(await File(tab.path!).readAsString(), 'my edits');
      expect(tab.hasUnsavedChanges, isTrue);
      expect(workspace.error, contains('Could not save'));
    },
  );

  test(
    'offline edits survive restart and recover without a server connection',
    () async {
      await open();
      final tab = workspace.active!;
      tab.editor.text.text = 'recover me';
      connections.offline = true;
      expect(await workspace.save(tab), isFalse);
      workspace.dispose();
      await files.close();
      workspace = DocumentWorkspace(
        store: LocalDocumentStore(),
        dialogs: FakeDialogs(),
      );
      files = WorkspaceRemoteFiles(
        directory: Directory(paths.join(directory.path, 'managed')),
        catalog: catalog,
        prompts: _NoPrompts(),
        connections: connections,
        isDocumentOpen: (path) => workspace.tabForPath(path) != null,
      );
      final copies = await files.localCopies();
      expect(copies, hasLength(1));
      await workspace.openManaged(
        copies.single.path,
        copies.single.publication,
      );
      expect(workspace.active!.editor.text.text, 'recover me');
      expect(workspace.active!.hasUnsavedChanges, isTrue);
      connections.offline = false;
      await files.connect(server, windowId: 'window-2');
      expect(await workspace.save(workspace.active!), isTrue);
      expect(await remote.readAsString(), 'recover me');
    },
  );

  test('catalog endpoint edits cannot retarget an old working copy', () async {
    final first = await open();
    final other = await files.connect(
      server.copyWith(host: 'other-server'),
      windowId: 'window-2',
    );
    expect(other.server.id, isNot(first.connection.server.id));
    final copy = await files.openFile(
      other.server,
      await connections.fs.stat(remote.path),
    );
    expect(copy.path, isNot(first.document.path));
    expect(first.document.publication.displayPath, contains('user@server:22'));
    expect(copy.publication.displayPath, contains('user@other-server:22'));
  });

  test(
    'a recreated missing checkout is never overwritten without a baseline',
    () async {
      await open();
      final tab = workspace.active!;
      final local = File(tab.path!);
      tab.editor.text.text = 'my buffer';
      await local.delete();
      await workspace.checkDisk();
      expect(tab.disk, DiskState.missing);
      await local.writeAsString('another writer');
      expect(await workspace.save(tab), isFalse);
      expect(await local.readAsString(), 'another writer');
      expect(await remote.readAsString(), 'original');
      expect(tab.hasUnsavedChanges, isTrue);
    },
  );

  test(
    'interrupted managed replacement restores pending edits on restart',
    () async {
      await open();
      final tab = workspace.active!;
      tab.editor.text.text = 'previous pending edit';
      connections.offline = true;
      expect(await workspace.save(tab), isFalse);
      final local = File(tab.path!);
      workspace.dispose();
      await files.close();
      await local.rename('${local.path}.poltergeist-deadbeef-cafe.backup');
      await File(
        '${local.path}.poltergeist-deadbeef-cafe.edit',
      ).writeAsString('new complete edit');
      workspace = DocumentWorkspace(
        store: LocalDocumentStore(),
        dialogs: FakeDialogs(),
      );
      files = WorkspaceRemoteFiles(
        directory: Directory(paths.join(directory.path, 'managed')),
        catalog: catalog,
        prompts: _NoPrompts(),
        connections: connections,
        isDocumentOpen: (path) => workspace.tabForPath(path) != null,
      );
      final copies = await files.localCopies();
      expect(copies, hasLength(1));
      await workspace.openManaged(
        copies.single.path,
        copies.single.publication,
      );
      expect(workspace.active!.editor.text.text, 'new complete edit');
      expect(workspace.active!.hasUnsavedChanges, isTrue);
      expect(await remote.readAsString(), 'original');
    },
  );
}
