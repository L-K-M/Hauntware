import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'catalog_writes.dart';

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
    _writes = CatalogWrites(
      _engine,
      (failure, detail) => AlertRuleNotSavedException(failure, detail),
    );
  }

  final EngineClient _engine;
  late final StreamSubscription<EngineEvent> _events;

  List<SyncedRule> _rules = const [];
  late final CatalogWrites _writes;
  var _count = 0;
  bool _engineStopped = false;

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

  Future<void> _send(EngineRequest Function(String requestId) request) async {
    // A stopped engine's port may still take a request without an error,
    // and nothing would ever answer it.
    if (_engineStopped) throw const AlertRuleNotSavedException(null);
    final requestId = 'rule-${_count++}';
    await _writes.write(requestId, request(requestId));
  }

  void _onEngineEvent(EngineEvent event) {
    switch (event) {
      case AlertRulesChanged(:final rules):
        _rules = List.unmodifiable(rules);
        notifyListeners();
      case _:
    }
  }

  void _onEngineDone() {
    _engineStopped = true;
  }

  @override
  void dispose() {
    unawaited(_events.cancel());
    _writes.dispose();
    super.dispose();
  }
}
