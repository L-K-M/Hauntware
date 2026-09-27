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
}
