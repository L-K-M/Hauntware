import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/double_click_action_controller.dart';

import '../compact/compact_harness.dart';

/// Settings → Editing's Double-click action reaches every pane: both strips
/// and their tabs follow the app's model, at startup and on each change.
void main() {
  testWidgets('both panes follow the double-click action as it changes', (
    tester,
  ) async {
    final action = DoubleClickActionController(initial: DoubleClickAction.edit);
    addTearDown(action.dispose);
    final harness = CompactHarness();
    await harness.pump(tester, doubleClickAction: action);
    final workspace = harness.workspace(tester);

    expect(workspace.left.doubleClickAction, DoubleClickAction.edit);
    expect(workspace.right.doubleClickAction, DoubleClickAction.edit);
    expect(
      workspace.left.activeTabController!.doubleClickAction,
      DoubleClickAction.edit,
    );

    await action.setAction(DoubleClickAction.nothing);

    expect(workspace.left.doubleClickAction, DoubleClickAction.nothing);
    expect(workspace.right.doubleClickAction, DoubleClickAction.nothing);
    expect(
      workspace.left.activeTabController!.doubleClickAction,
      DoubleClickAction.nothing,
    );
  });
}
