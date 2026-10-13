import 'package:flutter/foundation.dart';

import 'skip_rule_sets.dart';

/// Writes [set] in place of the set named `replacing`, or as a new set,
/// and completes with every set now stored.
typedef SkipRuleSetPut =
    Future<List<SkipRuleSet>> Function(SkipRuleSet set, {String? replacing});

/// Removes the set named `name` and completes with every set now stored.
typedef SkipRuleSetRemove = Future<List<SkipRuleSet>> Function(String name);

/// This device's skip rule sets (05 §3), shared by every workspace
/// window: the Skip Rules dialog and the pair editor add them to a pair,
/// and Manage Rule Sets edits them.
///
/// A change persists first and publishes second, like the editor
/// registry: a dialog never lists a set that failed to save, and a failed
/// write throws with the list unchanged. Each write edits the list as
/// stored rather than this copy, which may be empty after a launch whose
/// read failed. Without writers (tests) changes stay in memory.
final class SkipRuleSetsController extends ChangeNotifier
    implements ValueListenable<List<SkipRuleSet>> {
  SkipRuleSetsController({
    List<SkipRuleSet> initial = const [],
    this._put,
    this._remove,
  }) : _value = List.unmodifiable(initial);

  final SkipRuleSetPut? _put;
  final SkipRuleSetRemove? _remove;
  List<SkipRuleSet> _value;

  @override
  List<SkipRuleSet> get value => _value;

  /// Saves [set], in place of the set named [replacing] when it edits or
  /// renames one. Throws [SkipRuleSetNameTaken] when another set holds
  /// the name: callers check [value] first, but the stored list can hold
  /// sets this copy missed after a launch whose read failed.
  Future<void> put(SkipRuleSet set, {String? replacing}) async {
    final persist = _put;
    _publish(
      persist == null
          ? putSkipRuleSetInto(_value, set, replacing: replacing)
          : await persist(set, replacing: replacing),
    );
  }

  /// Deletes the set named [name]. Pairs that copied its lines keep them.
  Future<void> remove(String name) async {
    final persist = _remove;
    _publish(
      persist == null
          ? removeSkipRuleSetFrom(_value, name)
          : await persist(name),
    );
  }

  void _publish(List<SkipRuleSet> sets) {
    _value = List.unmodifiable(sets);
    notifyListeners();
  }
}
