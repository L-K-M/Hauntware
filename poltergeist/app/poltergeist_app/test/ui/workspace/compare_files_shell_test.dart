import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/ui/panes/compare_files_command.dart';

import '../../support/shell_commands.dart';
import 'built_in_editor_checkout_test.dart';
import 'external_editor_checkout_test.dart' show serverBookmark;

/// File ▸ Compare Files through the real WorkspaceShell: the registered
/// command resolves the live pane's selection and pushes 06 §6's view.
void main() {
  testWidgets('Compare Files opens two selected files side by side', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await EditorCheckoutHarness.open();
      try {
        harness.bookmarks.bookmarks = [serverBookmark()];
        await mountEditorShell(tester, harness);
        await pollFor(tester, find.text('config.txt'));
        final pane = leftPane(tester);
        int row(String path) =>
            pane.entries.indexWhere((entry) => entry.path == path);

        expect(
          shellCommandEnabled(tester, kFileCompareFilesCommandId),
          isFalse,
        );
        pane.setCursorIndex(row(remoteNotesPath));
        pane.setCursorIndex(
          row(remoteConfigPath),
          update: SelectionUpdate.toggle,
        );
        await tester.pump();
        expect(shellCommandEnabled(tester, kFileCompareFilesCommandId), isTrue);

        await runShellCommand(
          tester,
          kFileCompareFilesCommandId,
          settle: false,
        );
        await pollFor(tester, find.byKey(const ValueKey('sync.compare.view')));

        // Listing order, not selection order, puts config.txt on the left.
        expect(find.text('Compare config.txt and notes.txt'), findsOneWidget);
        final leftColumn = find.byKey(const ValueKey('sync.compare.left'));
        final rightColumn = find.byKey(const ValueKey('sync.compare.right'));
        expect(
          find.descendant(
            of: leftColumn,
            matching: find.text(remoteConfigPath),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: rightColumn,
            matching: find.text(remoteNotesPath),
          ),
          findsOneWidget,
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await harness.close();
      }
    });
  });
}
