import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/ui/panes/pane_column_header.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

void main() {
  testWidgets('metadata sorts do not mark Name as sorted', (tester) async {
    for (final key in FileSortKey.values.where(
      (key) => !{
        FileSortKey.name,
        FileSortKey.size,
        FileSortKey.modified,
      }.contains(key),
    )) {
      FileSortKey? selected;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: PaneColumnHeader(
              paneTabId: 'pane',
              sortKey: key,
              sortDirection: FileSortDirection.ascending,
              onSort: (key) => selected = key,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.keyboard_arrow_up), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
      await tester.tap(find.byKey(const ValueKey('pane.column.name')));
      expect(selected, FileSortKey.name);
    }
  });
}
