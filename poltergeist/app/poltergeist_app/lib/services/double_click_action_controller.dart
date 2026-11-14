import 'double_click_action.dart';
import 'persisted_value_controller.dart';
import 'settings_models.dart';

/// The "Double-click action" preference (02 §2.6) in the app's isolate:
/// what every pane's file open follows, and the model Settings → Editing
/// writes through. `AppPreferences` stores it.
/// The next open follows a change at once ([PersistedValueController]).
final class DoubleClickActionController
    extends PersistedValueController<DoubleClickAction>
    implements DoubleClickActionModel {
  DoubleClickActionController({
    DoubleClickAction initial = DoubleClickAction.open,
    Future<void> Function(DoubleClickAction action)? save,
  }) : super(initial, save);

  @override
  Future<void> setAction(DoubleClickAction action) => write(action);
}
