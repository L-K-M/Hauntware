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

const _remotePath = '/config.txt';

// Keep the remote POSIX namespace separate from the host's native file paths.
class _RemoteFiles implements RemoteFileSystem {
  _RemoteFiles(this._root);
  final String _root;
  final _local = LocalFileSystem();

  String _localPath(String path) =>
      paths.joinAll([_root, ...paths.posix.split(path).skip(1)]);

  RemoteFileEntry _withPath(RemoteFileEntry entry, String path) =>
      RemoteFileEntry(
        path: path,
        name: entry.name,
        type: entry.type,
        size: entry.size,
        uid: entry.uid,
        gid: entry.gid,
        accessedAt: entry.accessedAt,
        modifiedAt: entry.modifiedAt,
        mode: entry.mode,
        contentSha256: entry.contentSha256,
      );

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async =>
      _withPath(
        await _local.stat(_localPath(path), followLinks: followLinks),
        path,
      );

  @override
  Future<RemoteFileEntry> download(
    String path,
    StreamSink<List<int>> destination, {
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async => _withPath(
    await _local.download(
      _localPath(path),
      destination,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    ),
    path,
  );

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
  }) async => _withPath(
    await _local.upload(
      _localPath(path),
      content,
      length: length,
      overwrite: overwrite,
      preserveMode: preserveMode,
      expectedTarget: expectedTarget,
      onProgress: onProgress,
      cancellation: cancellation,
      computeHash: computeHash,
    ),
    path,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Connections implements ConnectionManager {
  _Connections(String root) : fs = _RemoteFiles(root);
  final _RemoteFiles fs;
  bool offline = false;
  final opened = <String>[];

  // Mirrors the pool after a drop: leases park until it reconnects.
  Completer<void>? reconnect;
  var state = ServerConnectionState.connected;
  final _status = StreamController<ServerStatus>.broadcast();
  var leased = 0;
  var released = 0;

  void announce(ServerConnectionState next) {
    state = next;
    _status.add(ServerStatus(next));
  }

  @override
  Future<PaneChannel> openBrowseChannel(
    String serverId, {
    required String paneTabId,
  }) async {
    opened.add(serverId);
    return _Browse(fs, '/');
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
    await reconnect?.future;
    leased++;
    return _Lease(fs, () => released++);
  }

  @override
  Stream<ServerStatus> watchServer(String serverId) async* {
    yield ServerStatus(state);
    yield* _status.stream;
  }

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
  _Lease(this.fs, this._onRelease);
  @override
  final RemoteFileSystem fs;
  final void Function() _onRelease;
  @override
  AuthenticatedEndpointIdentity get endpointIdentity =>
      const AuthenticatedEndpointIdentity(
        host: 'server',
        port: 22,
        username: 'user',
        fingerprintSha256: 'SHA256:test',
      );
  @override
  Future<void> release() async => _onRelease();
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
    final temp = await Directory.systemTemp.createTemp('planchette-remote-');
    directory = Directory(await temp.resolveSymbolicLinks());
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
    final entry = await connections.fs.stat(_remotePath);
    final copy = await files.openFile(connection.server, entry);
    await workspace.openManaged(copy.path, copy.publication);
    return (connection: connection, document: copy);
  }

  test(
    'guarded local save publishes through the managed checkout queue',
    () async {
      final opened = await open();
      expect(opened.document.publication.sourcePath, _remotePath);
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
      await connections.fs.stat(_remotePath),
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
        await connections.fs.stat(_remotePath),
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

  // A parked save keeps its tab busy, which refuses closing it and quitting.
  const promptly = Duration(seconds: 10);

  test(
    'saving while the server reconnects fails promptly and keeps edits',
    () async {
      final opened = await open();
      final tab = workspace.active!;
      connections
        ..reconnect = Completer<void>()
        ..announce(ServerConnectionState.reconnecting);
      tab.editor.text.text = 'offline edit';
      expect(await workspace.save(tab).timeout(promptly), isFalse);
      expect(tab.busy, isFalse);
      expect(tab.editor.isSaving, isFalse);
      expect(workspace.error, contains('reconnect'));
      expect(await File(tab.path!).readAsString(), 'offline edit');
      expect(await remote.readAsString(), 'original');
      expect(opened.document.publication.pending, isTrue);

      connections.reconnect!.complete();
      connections
        ..reconnect = null
        ..announce(ServerConnectionState.connected);
      expect(await workspace.save(tab), isTrue, reason: workspace.error);
      expect(await remote.readAsString(), 'offline edit');
      expect(opened.document.publication.pending, isFalse);
    },
  );

  test(
    'a drop during a parked save fails it and returns the late channel',
    () async {
      await open();
      final tab = workspace.active!;
      connections.reconnect = Completer<void>();
      tab.editor.text.text = 'offline edit';
      final saving = workspace.save(tab);
      await pumpEventQueue();
      connections.announce(ServerConnectionState.reconnecting);
      expect(await saving.timeout(promptly), isFalse);
      expect(tab.busy, isFalse);

      connections.reconnect!.complete();
      await pumpEventQueue();
      expect(connections.leased, greaterThan(0));
      expect(connections.released, connections.leased);
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
      await connections.fs.stat(_remotePath),
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
