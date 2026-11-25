import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/l10n/editor_localizations_en.dart';
import 'package:planchette_editor/planchette_editor.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/ui/poltergeist_editor_strings.dart';

void main() {
  testWidgets('keeps the host dirty wording over the package catalog', (
    tester,
  ) async {
    late EditorStrings strings;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: <LocalizationsDelegate<dynamic>>[
          ...AppLocalizations.localizationsDelegates,
          EditorLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            strings = PoltergeistEditorStrings.of(context);
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pump();

    expect(strings, isA<PoltergeistEditorStrings>());
    expect(strings.unsaved, 'Unsaved edits');
    // Everything else still comes from the shared catalog.
    expect(strings.findHint, 'Find in file');
  });

  test('the override reads only the unsaved getter from the host catalog', () {
    final strings = PoltergeistEditorStrings(
      EditorLocalizationsEn(),
      AppLocalizationsEn(),
    );
    expect(strings.unsaved, 'Unsaved edits');
    expect(strings.findHint, 'Find in file');
    expect(strings.languageName(null), 'Plain Text');
  });
}
