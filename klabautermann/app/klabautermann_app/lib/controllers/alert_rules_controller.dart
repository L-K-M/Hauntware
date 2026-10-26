import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// A rule write the engine refused or never answered (03 §4.8).
final class AlertRuleNotSavedException implements Exception {
  const AlertRuleNotSavedException(this.failure, [this.detail]);

  /// Null when the engine stopped before it answered.
  final CatalogWriteFailure? failure;
  final String? detail;

  /// A diagnostic; a null failure means the engine stopped.
  @override
  String toString() => 'AlertRuleNotSavedException: $failure, $detail';
}

/// The account's alert rules (ALR-01, 03 §4.8, §7.19) as the engine
/// reports their `rule` records, and the writes that add, change or
/// remove one. Rules sync, so writing one needs an enrolled account; the
/// engine refuses it otherwise.
final class AlertRulesController extends ChangeNotifier {
  AlertRulesController(this._engine) {
    _events = _engine.events.listen(_onEngineEvent, onDone: _onEngineDone);
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  List<SyncedRule> _rules = const [];
  final Map<String, Completer<void>> _writes = {};
  var _count = 0;

  /// Every live rule, by id.
  List<SyncedRule> get rules => _rules;

  /// Seals [rule] as the rule [id], or as a new rule when [id] is null;
  /// completes once the engine wrote it, after the [AlertRulesChanged]
  /// that shows it, and throws [AlertRuleNotSavedException] when it was
  /// refused.
  Future<void> put(ThresholdRule rule, {String? id, String? target}) => _send(
    (requestId) => PutRule(
      requestId: requestId,
      ruleId: id ?? uuidV4(),
      rule: rule,
      target: target,
    ),
  );

  /// Seals the removal of the rule [id], as [put] completes.
  Future<void> remove(String id) =>
      _send((requestId) => RemoveRule(requestId: requestId, ruleId: id));

  Future<void> _send(EngineRequest Function(String requestId) request) {
    final requestId = 'rule-${_count++}';
    final written = Completer<void>();
    _writes[requestId] = written;
    try {
      _engine.send(request(requestId));
    } on StateError {
      _writes.remove(requestId);
      return Future.error(const AlertRuleNotSavedException(null));
    }
    return written.future;
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case AlertRulesChanged(:final rules):
        _rules = List.unmodifiable(rules);
        notifyListeners();
      case CatalogWritten(:final requestId):
        _writes.remove(requestId)?.complete();
      case CatalogWriteRefused(:final requestId, :final failure, :final detail):
        _writes
            .remove(requestId)
            ?.completeError(AlertRuleNotSavedException(failure, detail));
      case _:
    }
  }

  void _onEngineDone() {
    for (final written in _writes.values) {
      written.completeError(const AlertRuleNotSavedException(null));
    }
    _writes.clear();
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    _onEngineDone();
    super.dispose();
  }
}
