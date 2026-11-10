// CRED-05's recovery settings model for Klabautermann: the app-side
// controller over the engine's recovery requests, with requestId
// correlation, bounded waits and fixed failures. A code and an export's
// bytes come straight from the correlated reply; nothing is cached, and
// no code, key material or export text is logged or put in a snapshot.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import '../services/recovery_files.dart';

/// What Settings reads and changes of this device's recovery code
/// (CRED-05), apart from where it runs: [RecoveryController] in the app,
/// `RemoteRecovery` in the Settings window. The section renders
/// [configured] and calls the explicit actions; the file panels and the
/// vault key stay in the app's isolate.
abstract interface class RecoverySettings implements Listenable {
  /// Whether this device has a recovery code an export can use; null
  /// until the first answer.
  bool? get configured;

  /// Refetches the status, reporting a failure rather than treating it as
  /// an absent code. The section can retry this explicitly.
  Future<void> refresh();

  /// A new recovery code, formatted, to be shown once. Nothing is stored
  /// until [saveCode].
  Future<String> newCode();

  /// Keeps [code] as this device's recovery code, replacing an earlier
  /// one; exports made with that one still open with it.
  Future<void> saveCode(String code);

  /// Builds the encrypted export and saves it where the user chooses.
  /// The saved location, or null when the user cancelled.
  Future<String?> exportSecrets();

  /// Opens the chosen export with [code] and merges its credentials into
  /// this device's vault. Null when the user cancelled the file panel.
  Future<SecretsRestoreSummary?> restoreSecrets({
    required String code,
    required VaultRestorePolicy policy,
  });
}

/// A recovery operation failed. [failure] is the engine's fixed protocol
/// kind; no diagnostic text, code or key material crosses.
final class RecoveryException implements Exception {
  const RecoveryException(this.failure);

  final VaultRecoveryFailure failure;

  @override
  String toString() => 'RecoveryException: ${failure.name}';
}

/// The app's recovery settings over the engine's vault, with the file
/// panels beside it. The controller lasts one engine run, like the other
/// controllers: a restarted engine is a new client and a new controller.
final class RecoveryController extends ChangeNotifier
    implements RecoverySettings {
  RecoveryController(
    this._engine,
    this._files, {
    DateTime Function()? now,
    this._requestTimeout = const Duration(seconds: 20),
  }) : _now = now ?? DateTime.now {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
    unawaited(_loadConfigured().catchError((Object _) {}));
  }

  final EngineClient _engine;
  final RecoveryFiles _files;
  final DateTime Function() _now;
  final Duration _requestTimeout;

  late final StreamSubscription<EngineEvent> _events;
  final Map<String, Completer<EngineEvent>> _pending = {};
  int _nextRequestId = 0;
  bool? _configured;
  bool _disposed = false;
  Future<void>? _firstLoad;

  @override
  bool? get configured => _configured;

  /// The configured answer, loading it when the first answer has not
  /// arrived. An unsuccessful status read remains a failure, not an
  /// absent code; [refresh] can retry it.
  Future<bool> recoveryConfigured() async {
    final configured = _configured;
    if (configured != null) return configured;
    await _loadConfigured();
    return _configured ?? false;
  }

  /// Reads the configured flag again, after the app lock releases a
  /// keystore that was locked at launch.
  @override
  Future<void> refresh() => _requestStatus();

  String _id(String prefix) => '$prefix-${_nextRequestId++}';

  @override
  Future<String> newCode() async {
    final event = await _request(
      NewRecoveryCode(requestId: _id('recovery-new-code')),
      (event) => event is RecoveryCodeGenerated ? event : null,
    );
    return event.code;
  }

  @override
  Future<void> saveCode(String code) async {
    final event = await _request(
      SetRecoveryCode(requestId: _id('recovery-save-code'), code: code),
      (event) => event is RecoveryStatus ? event : null,
    );
    _applyConfigured(event.configured);
  }

  @override
  Future<String?> exportSecrets() async {
    final event = await _request(
      ExportVault(requestId: _id('recovery-export')),
      (event) => event is VaultExported ? event : null,
    );
    if (_disposed) return null;
    return _files.save(event.bytes, recoveryExportFileName(_now()));
  }

  @override
  Future<SecretsRestoreSummary?> restoreSecrets({
    required String code,
    required VaultRestorePolicy policy,
  }) async {
    final export = await _files.open();
    if (export == null || _disposed) return null;
    final event = await _request(
      RestoreVault(
        requestId: _id('recovery-restore'),
        export: export,
        code: code,
        policy: policy,
      ),
      (event) => event is VaultRestored ? event : null,
    );
    return SecretsRestoreSummary(
      added: event.added,
      replaced: event.replaced,
      kept: event.kept,
      unreadable: event.unreadable,
    );
  }

  Future<void> _loadConfigured() {
    final first = _firstLoad;
    if (first != null) return first;
    final load = _requestStatus();
    _firstLoad = load;
    return load;
  }

  Future<void> _requestStatus() async {
    if (_disposed) return;
    final event = await _request(
      RecoveryStatusRequest(requestId: _id('recovery-status')),
      (event) => event is RecoveryStatus ? event : null,
    );
    _applyConfigured(event.configured);
  }

  void _applyConfigured(bool configured) {
    if (_configured == configured) return;
    _configured = configured;
    notifyListeners();
  }

  Future<T> _request<T extends EngineEvent>(
    EngineRequest request,
    T? Function(EngineEvent event) select,
  ) async {
    if (_disposed) throw const RecoveryException(VaultRecoveryFailure.failed);
    final requestId = _requestIdOf(request);
    final answer = Completer<EngineEvent>();
    _pending[requestId] = answer;
    try {
      _engine.send(request);
    } on StateError {
      _pending.remove(requestId);
      throw const RecoveryException(VaultRecoveryFailure.failed);
    }
    try {
      final event = await answer.future.timeout(_requestTimeout);
      if (event is VaultRecoveryFailed) {
        throw RecoveryException(event.failure);
      }
      final selected = select(event);
      if (selected == null) {
        throw const RecoveryException(VaultRecoveryFailure.failed);
      }
      return selected;
    } on TimeoutException {
      throw const RecoveryException(VaultRecoveryFailure.failed);
    } finally {
      _pending.remove(requestId);
    }
  }

  String _requestIdOf(EngineRequest request) => switch (request) {
    NewRecoveryCode(:final requestId) => requestId,
    SetRecoveryCode(:final requestId) => requestId,
    RecoveryStatusRequest(:final requestId) => requestId,
    ExportVault(:final requestId) => requestId,
    RestoreVault(:final requestId) => requestId,
    _ => throw ArgumentError.value(
      request,
      'request',
      'not a recovery request',
    ),
  };

  void _onEngineEvent(EngineEvent event) {
    final String? requestId = switch (event) {
      RecoveryCodeGenerated(:final requestId) => requestId,
      RecoveryStatus(:final requestId) => requestId,
      VaultExported(:final requestId) => requestId,
      VaultRestored(:final requestId) => requestId,
      VaultRecoveryFailed(:final requestId) => requestId,
      _ => null,
    };
    if (requestId == null) return;
    _pending[requestId]?.complete(event);
  }

  void _onEngineDone() {
    _failPending(const RecoveryException(VaultRecoveryFailure.failed));
  }

  void _failPending(Object error) {
    for (final answer in _pending.values) {
      if (!answer.isCompleted) answer.completeError(error);
    }
    _pending.clear();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    unawaited(_events.cancel());
    _failPending(const RecoveryException(VaultRecoveryFailure.failed));
    super.dispose();
  }
}
