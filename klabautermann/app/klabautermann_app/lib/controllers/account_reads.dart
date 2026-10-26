import 'dart:async';

import 'package:klabautermann_core/klabautermann_core.dart';

/// ACC-01 and ACC-02's reads (03 §7.9): each [read] asks the engine for a
/// server's accounts and logins and completes with its [AccountsReport].
/// A concern of its own for one engine run, beside the monitoring
/// controller. A stopped engine, or one that stops before it answers,
/// answers [AccountsReportFailure.noLink].
final class AccountReads {
  AccountReads(this._engine) {
    _events = _engine.events.listen(_onEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;
  final Map<String, (String, Completer<AccountsReport>)> _pending = {};
  var _count = 0;
  bool _engineStopped = false;

  /// [serverId]'s accounts and logins as they are now.
  Future<AccountsReport> read(String serverId) {
    final requestId = 'accounts-${_count++}';
    if (_engineStopped) return Future.value(_noLink(serverId, requestId));
    final answer = Completer<AccountsReport>();
    _pending[requestId] = (serverId, answer);
    try {
      _engine.send(ReadAccounts(serverId, requestId: requestId));
    } on StateError {
      _pending.remove(requestId);
      return Future.value(_noLink(serverId, requestId));
    }
    return answer.future;
  }

  static AccountsReport _noLink(String serverId, String requestId) =>
      AccountsReport(
        serverId: serverId,
        requestId: requestId,
        failure: AccountsReportFailure.noLink,
      );

  void _onEvent(EngineEvent event) {
    if (event case AccountsReport(:final requestId)) {
      _pending.remove(requestId)?.$2.complete(event);
    }
  }

  void _onEngineDone() {
    _engineStopped = true;
    for (final MapEntry(key: requestId, value: (serverId, answer))
        in _pending.entries) {
      answer.complete(_noLink(serverId, requestId));
    }
    _pending.clear();
  }

  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
  }
}
