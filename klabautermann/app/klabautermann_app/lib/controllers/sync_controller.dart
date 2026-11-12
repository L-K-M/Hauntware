import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'account_size.dart';
import 'pin_publication_controller.dart' show PinPublicationSettings;

/// What Settings reads and resolves of the host-key quarantine diff, apart
/// from where it runs: [SyncController] in the app, and a copy kept over the
/// settings link in the desktop settings window.
abstract interface class PinConflictsSettings implements Listenable {
  /// The conflicts the engine reports, in its order.
  List<SyncPinConflict> get conflicts;

  /// Whether a resolution is in flight; the cards disable their buttons
  /// while it is, so a double tap cannot send two.
  bool get resolving;

  /// Resolves the conflict at [locator]: [keepLocal] keeps this device's pin
  /// and re-pushes it, false trusts the pulled key. Throws
  /// [PinConflictNotResolvedException] when the engine refuses or the
  /// conflict no longer stands.
  Future<void> resolvePinConflict(
    SyncPinConflict conflict, {
    required bool keepLocal,
  });
}

/// A resolution the engine refused or did not apply.
final class PinConflictNotResolvedException implements Exception {
  const PinConflictNotResolvedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The sync account concern (03 §4.3, §10.1): the account this device is
/// enrolled in, the sign-in, and the rounds the user asks for. A round
/// pushes what the engine sealed since (03 §4.4, [engineSyncPushPolicy]);
/// a sign-in pushes nothing.
final class SyncController extends ChangeNotifier
    implements PinConflictsSettings {
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
  bool _disposed = false;

  /// The answers still to come, by request id. The engine ends each
  /// operation with one final [SyncStatus] that echoes its request's id;
  /// the rounds it starts itself after a catalog write carry none, so
  /// they answer nobody here.
  final Map<String, (SyncOperation, Completer<SyncStatus>)> _waiting = {};
  var _count = 0;

  /// Whether an operation is running, whether or not it was asked for
  /// here.
  bool _running = false;

  /// The pin-conflict reads and resolutions still to come, oldest first.
  /// A null locator is a read, and every one is answered by the engine's
  /// next [PinConflictsChanged] or a refusal, in request order.
  final List<(String?, Completer<void>)> _pinRequests = [];

  /// The locators whose resolution is in flight, so a second tap on the
  /// same card is refused rather than queued.
  final Set<String> _resolving = {};

  List<SyncPinConflict> _conflicts = const [];

  /// The enrolled account, or null.
  SyncAccountInfo? get account => _account;

  @override
  List<SyncPinConflict> get conflicts => List.unmodifiable(_conflicts);

  @override
  bool get resolving => _resolving.isNotEmpty;

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

  /// Asks the engine for the quarantine diff as it stands and updates
  /// [conflicts] with its answer. A read the engine refuses leaves the
  /// list as it is, since a startup read must not stop the app.
  Future<void> readPinConflicts() {
    if (_engineStopped) return Future.value();
    final answered = Completer<void>();
    _pinRequests.add((null, answered));
    try {
      _engine.send(const ReadPinConflicts());
    } on StateError {
      _pinRequests.removeWhere(
        (pending) => identical(pending.$2, answered),
      );
      return Future.value();
    }
    return answered.future.catchError((Object _) {});
  }

  @override
  Future<void> resolvePinConflict(
    SyncPinConflict conflict, {
    required bool keepLocal,
  }) async {
    if (_engineStopped) {
      throw const PinConflictNotResolvedException('The engine stopped');
    }
    if (_resolving.contains(conflict.locator)) {
      throw const PinConflictNotResolvedException(
        'That conflict is already being resolved',
      );
    }
    final answered = Completer<void>();
    _resolving.add(conflict.locator);
    _pinRequests.add((conflict.locator, answered));
    notifyListeners();
    try {
      _engine.send(
        ResolvePinConflict(
          conflict.locator,
          keepLocal: keepLocal,
          localFingerprintSha256: conflict.localFingerprintSha256,
          pulledFingerprintSha256: conflict.pulledFingerprintSha256,
        ),
      );
    } on StateError {
      _pinRequests.removeWhere(
        (pending) => identical(pending.$2, answered),
      );
      _resolving.remove(conflict.locator);
      notifyListeners();
      throw const PinConflictNotResolvedException('The engine stopped');
    }
    try {
      await answered.future;
    } finally {
      _resolving.remove(conflict.locator);
      if (!_disposed) notifyListeners();
    }
  }

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
    switch (event) {
      case SyncStatus():
        _onSyncStatus(event);
      case PinConflictsChanged(:final conflicts):
        _setConflicts(conflicts);
        if (_pinRequests.isNotEmpty) {
          _pinRequests.removeAt(0).$2.complete();
        }
      case RequestRejected(:final requestName, :final reason)
          when requestName == 'ResolvePinConflict' ||
              requestName == 'ReadPinConflicts':
        if (_pinRequests.isNotEmpty) {
          _pinRequests.removeAt(0).$2.completeError(
            PinConflictNotResolvedException(reason),
          );
        }
      case _:
    }
  }

  void _onSyncStatus(SyncStatus event) {
    _account = event.account;
    if (_account == null) {
      _accountSize.value = null;
    } else if (event.prefixBudget case final budget?) {
      _accountSize.value = accountSizeOf(budget);
    }
    if (event.pinConflicts case final conflicts?) {
      _setConflicts(conflicts);
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

  void _setConflicts(List<SyncPinConflict> conflicts) {
    if (listEquals(_conflicts, conflicts)) return;
    _conflicts = List.unmodifiable(conflicts);
    notifyListeners();
  }

  void _onEngineDone() {
    _engineStopped = true;
    _running = false;
    for (final (operation, answer) in _waiting.values) {
      answer.complete(_stopped(operation));
    }
    _waiting.clear();
    for (final (_, answer) in _pinRequests) {
      answer.completeError(
        const PinConflictNotResolvedException('The engine stopped'),
      );
    }
    _pinRequests.clear();
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
    _disposed = true;
    _engineStopped = true;
    _running = false;
    for (final (operation, answer) in _waiting.values) {
      answer.complete(_stopped(operation));
    }
    _waiting.clear();
    for (final (_, answer) in _pinRequests) {
      answer.completeError(
        const PinConflictNotResolvedException('The engine stopped'),
      );
    }
    _pinRequests.clear();
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
