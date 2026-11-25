import 'package:ghost_ui/ghost_ui.dart' show PersistedSetting;

import 'double_click_action.dart';
import 'settings_models.dart';

/// The "Double-click action" preference (02 §2.6) in the app's isolate:
/// what every pane's file open follows, and the model Settings → Editing
/// writes through. `AppPreferences` stores it.
/// The next open follows a change at once ([PersistedSetting]).
final class DoubleClickActionController
    extends PersistedSetting<DoubleClickAction>
    implements DoubleClickActionModel {
  DoubleClickActionController({
    DoubleClickAction initial = DoubleClickAction.open,
    Future<void> Function(DoubleClickAction action)? save,
  }) : _persist = save,
       super(initial);

  final Future<void> Function(DoubleClickAction action)? _persist;

  @override
  Future<void>? save(DoubleClickAction value) => _persist?.call(value);

  @override
  Future<void> setAction(DoubleClickAction action) => change(action);
}
