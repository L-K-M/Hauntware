// Settings → Editing's Configure Editors… edit dialog (06 §8): Return in
// the extensions field saves under the same validation as Save, an
// invalid name still reports inline instead of closing, and Return in
// the name field moves on to the extensions.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/external_file_opener.dart';
import 'package:poltergeist_app/services/settings_models.dart';
import 'package:poltergeist_app/ui/settings/editor_settings.dart';

/// The registry holding one host-available editor; mutations land in the
/// registry and are recorded for the assertions.
final class _FakeEditors extends ChangeNotifier implements EditorRegistryModel {
  _FakeEditors(ExternalEditorDefinition editor)
    : registry = EditorRegistry(editors: [editor]);

  @override
  EditorRegistry registry;

  final calls = <String>[];

  @override
  Future<void> register(ExternalEditorDefinition editor) async {
    calls.add('register');
    registry.put(editor);
    notifyListeners();
  }

  @override
  Future<void> remove(String id) async {
    calls.add('remove');
    registry.remove(id);
    notifyListeners();
  }

  @override
  Future<void> setDefault(String id) async {
    calls.add('setDefault');
    registry.defaultEditorId = id;
    notifyListeners();
  }
}

ExternalEditorDefinition _editor({
  String id = 'editor.test',
  String displayName = 'Test Editor',
  List<String> acceptedExtensions = const ['dart'],
}) => ExternalEditorDefinition(
  id: id,
  displayName: displayName,
  platform: currentEditorHostPlatform!,
  launchTarget: '/test/editor',
  acceptedExtensions: acceptedExtensions,
);

Future<void> _pumpSection(WidgetTester tester, EditorRegistryModel model) =>
    tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: EditorsSettingsSection(controller: model),
          ),
        ),
      ),
    );

Finder _fieldWithLabel(String label) => find.widgetWithText(TextField, label);

void main() {
  testWidgets('Return in the extensions field saves like Save', (tester) async {
    final model = _FakeEditors(_editor());
    addTearDown(model.dispose);
    await _pumpSection(tester, model);
    await tester.tap(find.byKey(const ValueKey('editors.edit.editor.test')));
    await tester.pumpAndSettle();

    await tester.enterText(_fieldWithLabel('Display name'), 'Renamed Editor');
    await tester.enterText(
      _fieldWithLabel('Accepted file extensions (optional)'),
      'dart, json',
    );
    await tester.pump();

    await tester.showKeyboard(
      _fieldWithLabel('Accepted file extensions (optional)'),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('Edit external editor'), findsNothing);
    expect(model.calls, ['register']);
    final saved = model.registry.byId('editor.test')!;
    expect(saved.displayName, 'Renamed Editor');
    expect(saved.acceptedExtensions, ['dart', 'json']);
  });

  testWidgets('Return with an invalid name reports inline and saves nothing', (
    tester,
  ) async {
    final model = _FakeEditors(_editor());
    addTearDown(model.dispose);
    await _pumpSection(tester, model);
    await tester.tap(find.byKey(const ValueKey('editors.edit.editor.test')));
    await tester.pumpAndSettle();

    await tester.enterText(_fieldWithLabel('Display name'), '');
    await tester.enterText(
      _fieldWithLabel('Accepted file extensions (optional)'),
      'json',
    );
    await tester.pump();

    await tester.showKeyboard(
      _fieldWithLabel('Accepted file extensions (optional)'),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(find.text('Invalid editor name'), findsOneWidget);
    expect(find.text('Edit external editor'), findsOneWidget);
    expect(model.calls, isEmpty);

    // The same action saves once the name is valid.
    await tester.enterText(_fieldWithLabel('Display name'), 'Valid Name');
    await tester.pump();
    await tester.showKeyboard(
      _fieldWithLabel('Accepted file extensions (optional)'),
    );
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(model.calls, ['register']);
    expect(model.registry.byId('editor.test')!.displayName, 'Valid Name');
  });

  testWidgets('Return in the name field moves on to the extensions', (
    tester,
  ) async {
    final model = _FakeEditors(_editor());
    addTearDown(model.dispose);
    await _pumpSection(tester, model);
    await tester.tap(find.byKey(const ValueKey('editors.edit.editor.test')));
    await tester.pumpAndSettle();

    await tester.showKeyboard(_fieldWithLabel('Display name'));
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pump();

    expect(find.text('Edit external editor'), findsOneWidget);
    expect(
      tester
          .widget<EditableText>(
            find.descendant(
              of: _fieldWithLabel('Accepted file extensions (optional)'),
              matching: find.byType(EditableText),
            ),
          )
          .focusNode
          .hasFocus,
      isTrue,
    );
    expect(model.calls, isEmpty);
  });
}
