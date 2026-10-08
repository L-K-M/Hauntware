import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/double_click_action_controller.dart';

/// The app's side of "Double-click action": what every pane's file open
/// follows, and what Settings → Editing writes through to the preferences.
void main() {
  DoubleClickActionController controller({
    DoubleClickAction initial = DoubleClickAction.open,
    Future<void> Function(DoubleClickAction action)? save,
  }) {
    final created = DoubleClickActionController(initial: initial, save: save);
    addTearDown(created.dispose);
    return created;
  }

  test('starts from the stored action', () {
    expect(
      controller(initial: DoubleClickAction.edit).value,
      DoubleClickAction.edit,
    );
  });

  test(
    'hands the panes the change, then saves; the same value does nothing',
    () async {
      final events = <String>[];
      late DoubleClickActionController action;
      action = controller(
        save: (value) async => events.add('save ${action.value.name}'),
      );
      action.addListener(() => events.add('notify'));

      await action.setAction(DoubleClickAction.open);
      await action.setAction(DoubleClickAction.nothing);

      expect(events, ['notify', 'save nothing']);
    },
  );

  test('a failed write keeps the change and throws', () async {
    final action = controller(save: (_) async => throw StateError('disk full'));

    await expectLater(
      action.setAction(DoubleClickAction.edit),
      throwsStateError,
    );
    expect(action.value, DoubleClickAction.edit);
  });
}
