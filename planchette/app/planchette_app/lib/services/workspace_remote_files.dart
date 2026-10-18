import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as paths;
import 'package:planchette_core/planchette_core.dart'
    show textDocumentMaximumBytes;
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:seance_core/seance_core.dart'
    show CredentialMissingException, privateKeyNeedsPassphrase;

import 'document_publication.dart';
import 'workspace_catalog.dart';

/// Prompts stay with the window; SSH, identity-file reads and checkouts stay
/// behind the application service.
abstract interface class WorkspaceConnectionPrompts {
  Future<bool> trustHost(HostKeyDecision decision);
  Future<CredentialDraft?> credentials(
    ServerConfig server,
    CredentialResolutionScope scope,
  );
  Future<List<String>> keyboardInteractive(
    KeyboardInteractiveChallenge challenge,
  );
}

typedef RemoteWorkspaceConnection = ({
  ServerConfig server,
  PaneChannel channel,
  Stream<ServerStatus> status,
});
typedef RemoteWorkspaceDocument = ({
  String path,
  DocumentPublication publication,
});

/// One app-wide checkout owner. Windows share the same server/path working
/// copy, so their normal document deduplication also covers remote files.
final class WorkspaceRemoteFiles {
  WorkspaceRemoteFiles({
    required Directory directory,
    required this.catalog,
    required WorkspaceConnectionPrompts prompts,
    ConnectionManager? connections,
    bool Function(String path)? isDocumentOpen,
    this.onError,
  }) : // Collaborator names are public; ownership stays private.
       // ignore: prefer_initializing_formals
       _directory = directory,
       // ignore: prefer_initializing_formals
       _prompts = prompts,
       _injectedConnections = connections,
       // ignore: prefer_initializing_formals
       _isDocumentOpen = isDocumentOpen;

  final Directory _directory;
  final WorkspaceConnectionPrompts _prompts;
  final ConnectionManager? _injectedConnections;
  final bool Function(String path)? _isDocumentOpen;
  final WorkspaceCatalog catalog;
  final void Function(Object, StackTrace)? onError;
  final Map<String, ServerConfig> _servers = {};
  final Map<String, _RemotePublication> _publications = {};
  ConnectionManager? _connections;
  ConnectionManager? _guarded;
  TransferQueue? _queue;
  ManagedRemoteFileStore? _store;
  CheckoutManager? _checkouts;
  StreamSubscription<void>? _changes;
  Future<void>? _starting;

  Future<void> _start() =>
      _starting ??= _initialize().catchError((Object error) {
        _starting = null;
        throw error;
      });

  Future<void> _initialize() async {
    await catalog.load();
    final source = _CatalogCredentials(catalog);
    final resolver = CredentialResolver(source);
    final connections =
        _injectedConnections ??
        PooledConnectionManager(
          resolveServer: (id) async {
            final server = _servers[id];
            if (server == null) {
              throw StateError('Open this server workspace first.');
            }
            return server;
          },
          resolveCredentials: (server, scope) async {
            try {
              final credentials = await resolver.resolve(server);
              final missingPassword =
                  credentials.method == AuthMethod.password &&
                  (credentials.password?.isEmpty ?? true);
              final missingPassphrase =
                  credentials.method == AuthMethod.privateKey &&
                  privateKeyNeedsPassphrase(credentials.privateKeyPem ?? '') &&
                  credentials.keyPassphrase == null;
              if (!missingPassword && !missingPassphrase) {
                return ResolvedCredentials(
                  credentials: credentials,
                  origin: CredentialOrigin.stored,
                );
              }
            } on CredentialMissingException {
              // A synced server may intentionally keep its credential device-local.
            }
            final draft = await _prompts.credentials(server, scope);
            if (draft == null) throw StateError('Connection cancelled.');
            final credentials = await resolver.resolve(server, draft: draft);
            return ResolvedCredentials(
              credentials: credentials,
              origin: CredentialOrigin.prompted,
            );
          },
          tofu: TofuVerifier(catalog.hostKeys),
          onHostKey: _prompts.trustHost,
          onKeyboardInteractive: _prompts.keyboardInteractive,
        );
    final store = ManagedRemoteFileStore(
      indexFile: File(paths.join(_directory.path, 'managed_remote_files.json')),
      checkoutRoot: Directory(paths.join(_directory.path, 'checkouts')),
    );
    final guarded = _FailWhileReconnecting(connections);
    final queue = TransferQueue(connections: guarded);
    final checkouts = CheckoutManager(
      store: store,
      connections: guarded,
      queue: queue,
      onError: onError,
    );
    try {
      await checkouts.start();
    } on Object {
      await checkouts.dispose();
      await queue.dispose();
      await store.close();
      await _disconnect(connections);
      rethrow;
    }
    _connections = connections;
    _guarded = guarded;
    _queue = queue;
    _store = store;
    _checkouts = checkouts;
    _changes = checkouts.changes.listen((_) {
      for (final publication in _publications.values) {
        publication.refresh();
      }
    });
  }

  /// Bind the endpoint and its jump route into the checkout identity. Editing
  /// a catalog record must never retarget an old working copy to another host.
  String _bind(ServerConfig server, [Set<String> ancestors = const {}]) {
    const maximumJumpHosts = 16;
    if (ancestors.contains(server.id) || ancestors.length >= maximumJumpHosts) {
      throw StateError('The server has a cyclic or overlong jump-host route.');
    }
    String? jumpId;
    if (server.jumpHostId case final id?) {
      final jump = catalog.serverById(id);
      if (jump == null) throw StateError('Jump host $id is unavailable.');
      jumpId = _bind(jump, {...ancestors, server.id});
    }
    final identity = jsonEncode([
      server.id,
      server.host.trim().toLowerCase(),
      server.port,
      server.username,
      jumpId,
    ]);
    final id = 'planchette:${base64Url.encode(utf8.encode(identity))}';
    final bound = ServerConfig.fromJson({
      ...server.toJson(),
      'id': id,
      'jumpHostId': jumpId,
    });
    _servers[id] = bound;
    final connections = _connections;
    if (connections is PooledConnectionManager) {
      connections.updateServerConfig(id, bound);
    }
    return id;
  }

  Future<RemoteWorkspaceConnection> connect(
    ServerConfig server, {
    required String windowId,
  }) async {
    await _start();
    final id = _bind(server);
    final connections = _guarded!;
    final channel = await connections.openBrowseChannel(
      id,
      paneTabId: windowId,
    );
    return (
      server: _servers[id]!,
      channel: channel,
      status: connections.watchServer(id),
    );
  }

  Future<RemoteWorkspaceDocument> openFile(
    ServerConfig server,
    RemoteFileEntry entry,
  ) async {
    await _start();
    if (!_servers.containsKey(server.id)) {
      throw StateError('Open the server workspace before editing its files.');
    }
    final checkouts = _checkouts!;
    final previous = checkouts.checkoutFor(server.id, entry.path);
    if (previous != null) {
      await checkouts.reconcile(previous);
      final current = checkouts.checkoutFor(server.id, entry.path)!;
      final localPath = checkouts.localFile(current).path;
      if (_isDocumentOpen?.call(localPath) == false &&
          !current.dirty &&
          !current.missing) {
        await checkouts.discard(current);
        _publications.remove(current.id)?.dispose();
      }
    }
    final record = await checkouts.checkout(
      serverId: server.id,
      entry: entry,
      maximumBytes: textDocumentMaximumBytes,
    );
    final publication = _publications.putIfAbsent(
      record.id,
      () => _RemotePublication(checkouts, record, server),
    );
    publication.refresh();
    return (path: checkouts.localFile(record).path, publication: publication);
  }

  Future<void> reconcile() async => _checkouts?.reconcileOnResume();

  /// Recovery reads durable copies even while the server is unreachable. A
  /// restored target cannot connect until its matching server is opened.
  Future<List<RemoteWorkspaceDocument>> localCopies() async {
    await _start();
    final checkouts = _checkouts!;
    return [
      for (final record in checkouts.records)
        if (record.dirty && !record.missing)
          (
            path: checkouts.localFile(record).path,
            publication: _publications.putIfAbsent(record.id, () {
              final encoded = record.serverId;
              const prefix = 'planchette:';
              if (!encoded.startsWith(prefix)) {
                throw const FormatException(
                  'Unrecognized remote-copy identity.',
                );
              }
              final identity = jsonDecode(
                utf8.decode(base64Url.decode(encoded.substring(prefix.length))),
              );
              if (identity is! List ||
                  identity.length != 5 ||
                  identity[0] is! String ||
                  identity[1] is! String ||
                  identity[2] is! int ||
                  identity[3] is! String) {
                throw const FormatException('Invalid remote-copy identity.');
              }
              final server = ServerConfig(
                id: record.serverId,
                label:
                    catalog.serverById(identity[0] as String)?.label ??
                    identity[1] as String,
                host: identity[1] as String,
                port: identity[2] as int,
                username: identity[3] as String,
                authMethod: AuthMethod.agent,
                createdAt: 0,
                updatedAt: 0,
              );
              return _RemotePublication(checkouts, record, server)..refresh();
            }),
          ),
    ];
  }

  Future<void> close() async {
    await _changes?.cancel();
    await _checkouts?.dispose();
    await _queue?.dispose();
    await _store?.close();
    final connections = _connections;
    if (connections != null) await _disconnect(connections);
    for (final publication in _publications.values) {
      publication.dispose();
    }
  }

  Future<void> _disconnect(ConnectionManager connections) async {
    for (final id in _servers.keys) {
      await connections.disconnectServer(id);
    }
  }
}

/// The pool parks lease and browse requests until a dropped server reconnects,
/// which may be never. A parked save keeps its tab busy and a parked Open
/// Server keeps the window locked, both refusing quit, so remote work fails
/// instead; the saved local copy stays pending for the next save.
final class _FailWhileReconnecting implements ConnectionManager {
  _FailWhileReconnecting(this._pool);
  final ConnectionManager _pool;

  static const _reconnecting = RemoteFileException(
    kind: RemoteFileErrorKind.disconnected,
    operation: 'connect',
    message: 'The server is reconnecting. Try again once it is connected.',
  );

  @override
  Future<TransferChannelLease> leaseTransferChannel(String serverId) =>
      _failIfDropped(
        serverId,
        () => _pool.leaseTransferChannel(serverId),
        // A parked request is granted after reconnecting; return its channel.
        onLate: (granted) => granted.release(),
      );

  @override
  Future<PaneChannel> openBrowseChannel(
    String serverId, {
    required String paneTabId,
  }) => _failIfDropped(
    serverId,
    () => _pool.openBrowseChannel(serverId, paneTabId: paneTabId),
    // Opens are idempotent per pane-tab, so a late grant may be the binding
    // the window still browses; closing it would unbind that. It stays bound
    // for the window's next open; [WorkspaceRemoteFiles.close] disconnects it.
    onLate: (_) {},
  );

  /// Races [request] against the server entering `reconnecting`. The pool's
  /// status stream replays the current state, so an already-dropped server
  /// fails at once.
  Future<T> _failIfDropped<T>(
    String serverId,
    Future<T> Function() request, {
    required void Function(T granted) onLate,
  }) async {
    final dropped = Completer<Never>();
    final watch = _pool.watchServer(serverId).listen((status) {
      if (status.state != ServerConnectionState.reconnecting) return;
      if (!dropped.isCompleted) dropped.completeError(_reconnecting);
    });
    final pending = request();
    try {
      return await Future.any([pending, dropped.future]);
    } on Object {
      pending.then(onLate, onError: (Object _) {}).ignore();
      rethrow;
    } finally {
      await watch.cancel();
    }
  }

  @override
  Stream<ServerStatus> watchServer(String serverId) =>
      _pool.watchServer(serverId);
  @override
  Stream<ConnectLogLine> get connectLog => _pool.connectLog;
  @override
  Future<Set<String>> connectedServerIds() => _pool.connectedServerIds();
  @override
  Future<void> disconnectServer(String serverId) =>
      _pool.disconnectServer(serverId);
  @override
  Future<void> removeBookmark(String serverId) =>
      _pool.removeBookmark(serverId);
}

final class _CatalogCredentials implements CredentialSource {
  _CatalogCredentials(this.catalog);
  final WorkspaceCatalog catalog;

  @override
  Future<Secret?> storedSecret(String secretRef) =>
      catalog.secretById(secretRef);

  @override
  Future<String> identityFile(ServerConfig config, CredentialDraft? draft) =>
      File(
        expandHomePath(
          config.identityFilePath!,
          environment: Platform.environment,
        ),
      ).readAsString();
}

final class _RemotePublication extends DocumentPublication {
  _RemotePublication(this._checkouts, this._record, this._server)
    : _digest = _record.baselineSha256;

  final CheckoutManager _checkouts;
  final ServerConfig _server;
  ManagedRemoteFile _record;
  String _digest;
  bool _pending = false;

  @override
  String get displayPath =>
      '${_server.label} (${_server.username}@${_server.host}:${_server.port})${_record.remotePath}';
  @override
  String get sourcePath => _record.remotePath;
  @override
  bool get pending => _pending;

  void refresh() {
    final current = _checkouts.checkoutFor(
      _record.serverId,
      _record.remotePath,
    );
    if (current == null) return;
    _record = current;
    _setPending(current.dirty || _digest != current.baselineSha256);
  }

  void _setPending(bool value) {
    if (_pending == value) return;
    _pending = value;
    notifyListeners();
  }

  @override
  void localSaved(String digest) {
    _digest = digest;
    _setPending(digest != _record.baselineSha256);
  }

  @override
  Future<bool> publish() async {
    final uploaded = await _checkouts.uploadLocalCopy(_record);
    refresh();
    return uploaded;
  }

  @override
  Future<void> discard() async {
    await _checkouts.discard(_record);
    _setPending(false);
  }
}
