import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'pin_publication_controller.dart' show PinPublicationSettings;

/// The sync account concern (03 §4.3, §10.1): the account this device is
/// enrolled in, the sign-in, and the rounds the user asks for. A round
/// pushes what the engine sealed since (03 §4.4, [engineSyncPushPolicy]);
/// a sign-in pushes nothing.
final class SyncController extends ChangeNotifier {
  /// [account] is the one the engine started with
  /// ([EngineReady.syncAccount]). [pinPublication] is what the sign-in
  /// offers to assert, when a release is named (M5 plan M07).
  SyncController(this._engine, {this._account, this.pinPublication}) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  final PinPublicationSettings? pinPublication;

  SyncAccountInfo? _account;
  bool _passphraseUnverified = false;
  SyncFailure? _lastFailure;
  bool _engineStopped = false;

  /// The answers still to come, oldest first. The engine runs sync
  /// operations one at a time in request order and ends each with one
  /// final [SyncStatus], so the next one always answers the oldest.
  final List<(SyncOperation, Completer<SyncStatus>)> _waiting = [];

  /// The enrolled account, or null.
  SyncAccountInfo? get account => _account;

  /// Whether a sign-in or round is under way.
  bool get busy => _waiting.isNotEmpty;

  /// Whether the next sync action should be a sign-in rather than a round:
  /// no account yet, no record has confirmed the encryption passphrase
  /// (03 §4.5), or the server refused the stored session.
  bool get needsSignIn =>
      _account == null ||
      _passphraseUnverified ||
      _lastFailure == SyncFailure.sessionRejected;

  /// Signs in to the Séance account (03 §4.3 step 1) and completes with the
  /// engine's answer.
  Future<SyncStatus> signIn({
    required String baseUrl,
    required String username,
    required String password,
    required String encryptionPassphrase,
  }) => _send(
    SyncOperation.enroll,
    EnrollSync(
      baseUrl: baseUrl,
      username: username,
      password: password,
      encryptionPassphrase: encryptionPassphrase,
    ),
  );

  /// Runs one round and completes with the engine's answer.
  Future<SyncStatus> syncNow() =>
      _send(SyncOperation.round, const RunSyncRound());

  Future<SyncStatus> _send(SyncOperation operation, EngineRequest request) {
    if (_engineStopped) {
      return Future.value(_stopped(operation));
    }
    final answer = Completer<SyncStatus>();
    try {
      _engine.send(request);
    } on StateError {
      return Future.value(_stopped(operation));
    }
    _waiting.add((operation, answer));
    notifyListeners();
    return answer.future;
  }

  void _onEngineEvent(EngineEvent event) {
    if (event is! SyncStatus) return;

    _account = event.account;
    if (event.phase == SyncPhase.running) {
      notifyListeners();
      return;
    }
    _lastFailure = event.failure;
    if (event.phase == SyncPhase.succeeded) {
      _passphraseUnverified = event.passphraseUnverified;
    }
    if (_waiting.isNotEmpty) _waiting.removeAt(0).$2.complete(event);
    notifyListeners();
  }

  void _onEngineDone() {
    _engineStopped = true;
    for (final (operation, answer) in _waiting) {
      answer.complete(_stopped(operation));
    }
    _waiting.clear();
    notifyListeners();
  }

  SyncStatus _stopped(SyncOperation operation) => SyncStatus(
    SyncPhase.failed,
    operation: operation,
    account: _account,
    failure: SyncFailure.other,
    detail: 'the engine stopped',
  );

  /// Settles every pending call as the engine stopping would, since no
  /// answer can reach a disposed controller, and refuses later calls.
  @override
  void dispose() {
    _engineStopped = true;
    for (final (operation, answer) in _waiting) {
      answer.complete(_stopped(operation));
    }
    _waiting.clear();
    unawaited(_events.cancel());
    super.dispose();
  }
}
