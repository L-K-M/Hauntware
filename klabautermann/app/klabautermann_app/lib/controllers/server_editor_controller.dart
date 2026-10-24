import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// A catalog write the engine refused (03 §4.4): why, and the engine's
/// words for [CatalogWriteFailure.other].
final class ServerEditRefused implements Exception {
  const ServerEditRefused(this.failure, [this.detail]);

  final CatalogWriteFailure failure;
  final String? detail;
}

/// The engine stopped before it answered an edit.
final class ServerEditEngineStopped implements Exception {
  const ServerEditEngineStopped();
}

/// In-app server editing over the engine (FL-03, M5 plan M09a): reads a
/// synced server back as a draft, saves one, duplicates one, deletes one
/// and tests a draft's connection (M09b). The engine
/// plans the credential and seals the records; a round pushes them. One
/// engine run's, like the fleet.
///
/// Each request carries an id of its own and the engine answers it once,
/// with [ServerDraftRead], [CatalogWritten], [CatalogWriteRefused] or
/// [ServerConnectionTested].
final class ServerEditorController {
  ServerEditorController(this._engine) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  int _count = 0;
  final Map<String, Completer<ServerDraft?>> _reads = {};
  final Map<String, Completer<CatalogWritten>> _writes = {};
  final Map<String, Completer<ServerConnectionTested>> _tests = {};
  bool _stopped = false;

  /// The synced server [serverId] as the editor shows it, or null when the
  /// catalog no longer lists it.
  Future<ServerDraft?> read(String serverId) {
    final requestId = _nextId();
    final answer = _reads[requestId] = Completer<ServerDraft?>();
    _send(ReadServerDraft(requestId: requestId, serverId: serverId), requestId);
    return answer.future;
  }

  /// Saves [draft], with [credential]'s boxes as typed, and completes with
  /// whether a credential was written. Throws [ServerEditRefused] when the
  /// engine refuses it.
  Future<bool> save(ServerDraft draft, ServerCredentialEntry? credential) {
    final requestId = _nextId();
    final answer = _writes[requestId] = Completer<CatalogWritten>();
    _send(
      SaveServer(requestId: requestId, draft: draft, credential: credential),
      requestId,
    );
    return answer.future.then((written) => written.credentialWritten);
  }

  /// Copies the synced server [serverId] as a new one with a credential of
  /// its own, and completes with the copy's id. Throws [ServerEditRefused]
  /// when the engine refuses it.
  Future<String?> duplicate(String serverId) {
    final requestId = _nextId();
    final answer = _writes[requestId] = Completer<CatalogWritten>();
    _send(DuplicateServer(requestId: requestId, serverId: serverId), requestId);
    return answer.future.then((written) => written.serverId);
  }

  /// Deletes the synced server [serverId] from the account. Throws
  /// [ServerEditRefused] when the engine refuses it.
  Future<void> delete(String serverId) {
    final requestId = _nextId();
    final answer = _writes[requestId] = Completer<CatalogWritten>();
    _send(DeleteServer(requestId: requestId, serverId: serverId), requestId);
    return answer.future;
  }

  /// Tries [draft] with [credential]'s boxes, saving neither. Throws
  /// [ServerEditRefused] when the engine cannot test, such as while its
  /// links are off.
  Future<ServerConnectionTested> test(
    ServerDraft draft,
    ServerCredentialEntry credential,
  ) {
    final requestId = _nextId();
    final answer = _tests[requestId] = Completer<ServerConnectionTested>();
    _send(
      TestServerConnection(
        requestId: requestId,
        draft: draft,
        credential: credential,
      ),
      requestId,
    );
    return answer.future;
  }

  String _nextId() => 'server-edit-${_count++}';

  void _send(EngineRequest request, String requestId) {
    if (_stopped) {
      _fail(requestId, const ServerEditEngineStopped());
      return;
    }
    try {
      _engine.send(request);
    } on StateError {
      _fail(requestId, const ServerEditEngineStopped());
    }
  }

  void _fail(String requestId, Object error) {
    _reads.remove(requestId)?.completeError(error);
    _writes.remove(requestId)?.completeError(error);
    _tests.remove(requestId)?.completeError(error);
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case ServerDraftRead(:final requestId, :final draft):
        _reads.remove(requestId)?.complete(draft);
      case CatalogWritten(:final requestId):
        _writes.remove(requestId)?.complete(event);
      case CatalogWriteRefused(:final requestId, :final failure, :final detail):
        _writes
            .remove(requestId)
            ?.completeError(ServerEditRefused(failure, detail));
      case ServerConnectionTested(:final requestId):
        _tests.remove(requestId)?.complete(event);
      // A rejection names no request, but tests are the only requests here
      // the engine rejects, and only all of them alike.
      case RequestRejected(:final requestName, :final reason)
          when requestName == '$TestServerConnection':
        for (final id in [..._tests.keys]) {
          _fail(id, ServerEditRefused(CatalogWriteFailure.other, reason));
        }
      default:
        break;
    }
  }

  /// Settles every pending request as failed: no answer comes after the
  /// engine stops.
  void _onEngineDone() {
    _stopped = true;
    for (final id in [..._reads.keys, ..._writes.keys, ..._tests.keys]) {
      _fail(id, const ServerEditEngineStopped());
    }
  }

  void dispose() {
    _onEngineDone();
    unawaited(_events.cancel());
  }
}
