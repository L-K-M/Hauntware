import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'account_size.dart';
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

  /// The answers still to come, by request id. The engine ends each
  /// operation with one final [SyncStatus] that echoes its request's id;
  /// the rounds it starts itself after a catalog write carry none, so
  /// they answer nobody here.
  final Map<String, (SyncOperation, Completer<SyncStatus>)> _waiting = {};
  var _count = 0;

  /// Whether an operation is running, whether or not it was asked for
  /// here.
  bool _running = false;

  /// The enrolled account, or null.
  SyncAccountInfo? get account => _account;

  /// The account's size after the latest operation that succeeded in this
  /// engine run (SYN-09); null before one, and while no account is
  /// enrolled.
  ValueListenable<AccountSize?> get accountSize => _accountSize;
  final _accountSize = ValueNotifier<AccountSize?>(null);

  /// Whether a sign-in or round is under way, including one the engine
  /// started itself.
  bool get busy => _waiting.isNotEmpty || _running;

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
    (requestId) => EnrollSync(
      baseUrl: baseUrl,
      username: username,
      password: password,
      encryptionPassphrase: encryptionPassphrase,
      requestId: requestId,
    ),
  );

  /// Runs one round and completes with the engine's answer.
  Future<SyncStatus> syncNow() => _send(
    SyncOperation.round,
    (requestId) => RunSyncRound(requestId: requestId),
  );

  Future<SyncStatus> _send(
    SyncOperation operation,
    EngineRequest Function(String requestId) request,
  ) {
    if (_engineStopped) {
      return Future.value(_stopped(operation));
    }
    final requestId = 'sync-${_count++}';
    final answer = Completer<SyncStatus>();
    try {
      _engine.send(request(requestId));
    } on StateError {
      return Future.value(_stopped(operation));
    }
    _waiting[requestId] = (operation, answer);
    notifyListeners();
    return answer.future;
  }

  void _onEngineEvent(EngineEvent event) {
    if (event is! SyncStatus) return;

    _account = event.account;
    if (_account == null) {
      _accountSize.value = null;
    } else if (event.prefixBudget case final budget?) {
      _accountSize.value = accountSizeOf(budget);
    }
    _running = event.phase == SyncPhase.running;
    if (_running) {
      notifyListeners();
      return;
    }
    _lastFailure = event.failure;
    if (event.phase == SyncPhase.succeeded) {
      _passphraseUnverified = event.passphraseUnverified;
    }
    if (event.requestId case final id?) _waiting.remove(id)?.$2.complete(event);
    notifyListeners();
  }

  void _onEngineDone() {
    _engineStopped = true;
    _running = false;
    for (final (operation, answer) in _waiting.values) {
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
    _running = false;
    for (final (operation, answer) in _waiting.values) {
      answer.complete(_stopped(operation));
    }
    _waiting.clear();
    unawaited(_events.cancel());
    _accountSize.dispose();
    super.dispose();
  }
}

/// [budget] for the account size view.
AccountSize accountSizeOf(SyncPrefixBudget budget) => AccountSize(
  prefixBytes: budget.usedBytes,
  budgetBytes: kSyncPrefixBudgetBytes,
  warnBytes: (kSyncPrefixBudgetBytes * kSyncPrefixWarnFraction).ceil(),
  rows: [
    for (final MapEntry(:key, :value) in budget.byPrefix.entries)
      AccountSizeRow(prefix: key, records: value.records, bytes: value.bytes),
  ],
);
