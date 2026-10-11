import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/ui/panes/batch_rename_command.dart';
import 'package:poltergeist_app/ui/panes/batch_rename_dialog.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../support/shell_commands.dart';
import 'built_in_editor_checkout_test.dart';
import 'external_editor_checkout_test.dart' show serverBookmark;

/// Rename Items through the real WorkspaceShell: the registered command
/// opens the dialog on the live pane's selection, and confirming sends
/// the renames over the tab's browse channel and reselects the results.
void main() {
  testWidgets('Rename Items renames two selected files from the shell', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final harness = await EditorCheckoutHarness.open();
      try {
        harness.bookmarks.bookmarks = [serverBookmark()];
        await mountEditorShell(tester, harness);
        await pollFor(tester, find.text('config.txt'));
        final pane = leftPane(tester);
        int row(String path) {
          final index = pane.entries.indexWhere((entry) => entry.path == path);
          expect(index, isNonNegative, reason: '$path missing from listing');
          return index;
        }

        expect(shellCommandEnabled(tester, kFileBatchRenameCommandId), isFalse);
        pane.setCursorIndex(row(remoteConfigPath));
        pane.setCursorIndex(
          row(remoteNotesPath),
          update: SelectionUpdate.toggle,
        );
        await tester.pump();
        expect(shellCommandEnabled(tester, kFileBatchRenameCommandId), isTrue);

        await runShellCommand(tester, kFileBatchRenameCommandId, settle: false);
        await pollFor(tester, find.byKey(const ValueKey(BatchRenameKey.find)));

        await tester.enterText(
          find.byKey(const ValueKey(BatchRenameKey.find)),
          'o',
        );
        await tester.enterText(
          find.byKey(const ValueKey(BatchRenameKey.replace)),
          '0',
        );
        await tester.pump();
        expect(find.text('c0nfig.txt'), findsOneWidget);
        expect(find.text('n0tes.txt'), findsOneWidget);

        // What the server lists once the renames land.
        final channel = harness.appEngine.channel!;
        channel.listings['/srv/www'] = [
          for (final entry in channel.listings['/srv/www']!)
            RemoteFileEntry(
              path: entry.path
                  .replaceAll('/config.txt', '/c0nfig.txt')
                  .replaceAll('/notes.txt', '/n0tes.txt'),
              name: entry.name
                  .replaceAll('config.txt', 'c0nfig.txt')
                  .replaceAll('notes.txt', 'n0tes.txt'),
              type: entry.type,
              size: entry.size,
              modifiedAt: entry.modifiedAt,
              mode: entry.mode,
            ),
        ];

        await tester.tap(find.byKey(const ValueKey(BatchRenameKey.confirm)));
        for (var i = 0; i < 160; i++) {
          await tester.pump();
          final selected = {
            for (final entry in pane.selectedEntries) entry.name,
          };
          // The pre-run selection is also two items: wait for the
          // renamed names, not just the count.
          if (find
                  .byKey(const ValueKey(BatchRenameKey.dialog))
                  .evaluate()
                  .isEmpty &&
              selected.length == 2 &&
              selected.containsAll(['c0nfig.txt', 'n0tes.txt'])) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }

        expect(channel.renameCalls, [
          (remoteConfigPath, remoteConfigPath.replaceAll('config', 'c0nfig')),
          (remoteNotesPath, remoteNotesPath.replaceAll('notes', 'n0tes')),
        ]);
        expect(find.byKey(const ValueKey(BatchRenameKey.dialog)), findsNothing);
        expect(
          [for (final entry in pane.selectedEntries) entry.name],
          ['c0nfig.txt', 'n0tes.txt'],
        );
      } finally {
        await tester.pumpWidget(const SizedBox());
        await harness.close();
      }
    });
  });
}
