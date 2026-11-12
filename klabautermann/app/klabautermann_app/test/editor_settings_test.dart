import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/editor_display.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/settings/editor_settings.dart';

void main() {
  testWidgets(
    'choosing a font retains a size changed while the picker is open',
    (tester) async {
      final display = EditorDisplayController();
      addTearDown(display.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SingleChildScrollView(
              child: EditorSettingsSection(model: display),
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('editor.font')));
      await tester.pumpAndSettle();
      expect(find.text('Choose a font'), findsOneWidget);

      // Another settings surface changes a field the font picker does not edit.
      await display.setEditorDisplay(display.value.copyWith(textSize: 24));
      await tester.pump();
      await tester.tap(find.text('Use font'));
      await tester.pumpAndSettle();

      expect(display.value.textSize, 24);
      expect(find.text('Choose a font'), findsNothing);
    },
  );
}
