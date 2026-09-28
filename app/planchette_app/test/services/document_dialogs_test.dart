import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_app/services/document_dialogs.dart';
import 'package:planchette_app/services/document_workspace.dart';

void main() {
  for (final (button, choice) in [
    ('Cancel', ReadOnlyChoice.cancel),
    ('Save Anyway', ReadOnlyChoice.saveAnyway),
    ('Save As…', ReadOnlyChoice.saveAs),
  ]) {
    testWidgets('the read-only prompt answers $choice for $button', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()),
      );

      final answer = AppDocumentDialogs(
        navigator,
      ).chooseReadOnlySave('locked.txt');
      await tester.pumpAndSettle();
      expect(find.text('“locked.txt” is read-only'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();

      expect(await answer, choice);
    });
  }

  for (final (button, choice) in [
    ('Don’t Save', BulkCloseChoice.discardAll),
    ('Cancel', BulkCloseChoice.cancel),
    ('Save All', BulkCloseChoice.saveAll),
  ]) {
    testWidgets('the bulk close prompt answers $choice for $button', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox()),
      );

      final answer = AppDocumentDialogs(
        navigator,
      ).chooseBulkClose(['a.txt', 'b.txt', 'c.txt']);
      await tester.pumpAndSettle();
      expect(find.text('Save changes to 3 documents?'), findsOneWidget);
      expect(find.textContaining('a.txt\nb.txt\nc.txt'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();

      expect(await answer, choice);
    });
  }

  testWidgets('the bulk close prompt lists eight names, then a count', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(navigatorKey: navigator, home: const SizedBox()),
    );
    final dialogs = AppDocumentDialogs(navigator);
    final names = [for (var i = 1; i <= 9; i++) 'doc$i.txt'];

    final eight = dialogs.chooseBulkClose(names.take(8).toList());
    await tester.pumpAndSettle();
    expect(find.textContaining('doc8.txt'), findsOneWidget);
    expect(find.textContaining('more'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await eight, BulkCloseChoice.cancel);

    final nine = dialogs.chooseBulkClose(names);
    await tester.pumpAndSettle();
    expect(find.textContaining('doc8.txt\nand 1 more'), findsOneWidget);
    expect(find.textContaining('doc9.txt'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await nine, BulkCloseChoice.cancel);
  });
}
