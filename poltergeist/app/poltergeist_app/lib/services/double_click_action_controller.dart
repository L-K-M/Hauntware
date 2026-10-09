import 'package:flutter/foundation.dart';

import 'double_click_action.dart';
import 'settings_models.dart';

/// The "Double-click action" preference (02 §2.6) in the app's isolate:
/// what every pane's file open follows, and the model Settings → Editing
/// writes through. `AppPreferences` stores it.
///
/// Applies a change before persisting it, like
/// `DirectoryGroupingController`: the next open follows it at once. A
/// failed write keeps the change and throws; the next write carries it.
final class DoubleClickActionController extends ChangeNotifier
    implements DoubleClickActionModel {
  DoubleClickActionController({
    DoubleClickAction initial = DoubleClickAction.open,
    this._save,
  }) : _value = initial;

  DoubleClickAction _value;
  final Future<void> Function(DoubleClickAction action)? _save;

  @override
  DoubleClickAction get value => _value;

  @override
  Future<void> setAction(DoubleClickAction action) async {
    if (action == _value) return;
    _value = action;
    notifyListeners();
    await _save?.call(action);
  }
}
