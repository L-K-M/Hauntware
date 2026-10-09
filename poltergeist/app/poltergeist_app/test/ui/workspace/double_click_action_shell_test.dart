import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/double_click_action.dart';
import 'package:poltergeist_app/services/double_click_action_controller.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/ui/compact/compact_posture.dart';
import 'package:poltergeist_core/poltergeist_core.dart' show TransferOperation;

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

  group('Transfer to other pane', () {
    Finder switcher() => find.byKey(const ValueKey(CompactKey.paneSwitcher));

    Future<CompactHarness> pumpTransfer(WidgetTester tester) async {
      final action = DoubleClickActionController(
        initial: DoubleClickAction.transfer,
      );
      addTearDown(action.dispose);
      final harness = CompactHarness();
      harness.rightChannel.listings['/home/deploy/backups'] = const [];
      await harness.pump(tester, doubleClickAction: action);
      await tester.tap(find.text('This device'));
      await tester.pumpAndSettle();
      return harness;
    }

    testWidgets('opening a file copies it into the other pane', (tester) async {
      final harness = await pumpTransfer(tester);
      // Pane B into its backups folder, then back to pane A.
      await tester.tap(switcher());
      await tester.pumpAndSettle();
      await tester.tap(compactRow('/home/deploy/backups'));
      await tester.pumpAndSettle();
      await tester.tap(switcher());
      await tester.pumpAndSettle();

      await tester.tap(compactRow('/home/deploy/photo.jpg'));
      // The queued copy knows no size yet: the pill's spinner is
      // indeterminate, so the frame never settles.
      await tester.pump();

      final spec = harness.queue.enqueuedSpecs.single;
      expect(spec.operation, TransferOperation.copy);
      expect(spec.rootPaths, ['/home/deploy/photo.jpg']);
      expect(spec.destinationDir, '/home/deploy/backups');
      expect(
        harness.workspace(tester).left.activeTabController!.notice,
        isNull,
      );
    });

    testWidgets('with the second pane hidden it says what it needs', (
      tester,
    ) async {
      final harness = await pumpTransfer(tester);
      final workspace = harness.workspace(tester);
      workspace.setSecondPaneHidden(true);
      await tester.pumpAndSettle();

      await tester.tap(compactRow('/home/deploy/photo.jpg'));
      await tester.pump();

      expect(harness.queue.enqueuedSpecs, isEmpty);
      expect(
        workspace.left.activeTabController!.notice,
        PaneNotice.transferNeedsOtherPane,
      );
      expect(
        find.text(
          'To transfer files, show the other pane and open a folder in it.',
        ),
        findsOneWidget,
      );
      // The notice's auto-hide timer.
      await tester.pumpAndSettle(const Duration(seconds: 5));
    });
  });
}
