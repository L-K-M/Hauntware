// The external editors Settings section: the edit dialog (Return saves
// under Save's validation, an invalid name reports inline), Add editor,
// removal, the per-extension defaults, the mobile note and failures.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_editors/ghost_editors.dart';

import 'support/fakes.dart';

final _errors = <Object>[];

Future<void> _pumpSection(
  WidgetTester tester,
  EditorRegistryModel model, {
  EditorPicker? picker,
}) => tester.pumpWidget(
  MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: GhostEditorsSettingsSection(
          model: model,
          picker: picker ?? ({required dialogTitle}) async => null,
          strings: testStrings,
          onError: (_, error, _) => _errors.add(error),
        ),
      ),
    ),
  ),
);

Finder _fieldWithLabel(String label) => find.widgetWithText(TextField, label);

void main() {
  setUp(_errors.clear);
  tearDown(() => debugEditorHostPlatform = null);

  testWidgets('Return in the extensions field saves like Save', (tester) async {
    final model = FakeEditors([testEditor()]);
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
    final model = FakeEditors([testEditor()]);
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
    final model = FakeEditors([testEditor()]);
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

  testWidgets('Add editor picks, scopes in the edit dialog, then registers', (
    tester,
  ) async {
    final model = FakeEditors();
    addTearDown(model.dispose);
    String? title;
    await _pumpSection(
      tester,
      model,
      picker: ({required dialogTitle}) async {
        title = dialogTitle;
        return testEditor(id: 'editor.new', acceptedExtensions: const []);
      },
    );
    expect(find.text('No external editors'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('editors.add')));
    await tester.pumpAndSettle();
    expect(title, 'Choose an editor application');
    expect(find.text('Add external editor'), findsOneWidget);
    await tester.enterText(
      _fieldWithLabel('Accepted file extensions (optional)'),
      'md',
    );
    await tester.tap(find.byKey(const ValueKey('editors.edit.save')));
    await tester.pumpAndSettle();

    expect(model.calls, ['register']);
    expect(model.registry.byId('editor.new')!.acceptedExtensions, ['md']);
    expect(find.byKey(const ValueKey('editors.row.editor.new')), findsOne);
  });

  testWidgets('removing the default names the consequence', (tester) async {
    final model = FakeEditors([testEditor()]);
    model.registry.setDefault('editor.test');
    addTearDown(model.dispose);
    await _pumpSection(tester, model);

    await tester.tap(find.byKey(const ValueKey('editors.remove.editor.test')));
    await tester.pumpAndSettle();
    expect(find.text('Resets the default.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editors.remove.confirm')));
    await tester.pumpAndSettle();

    expect(model.calls, ['remove']);
    expect(model.registry.defaultEditorId, EditorRegistry.systemDefaultId);
  });

  testWidgets('a per-extension default is added and removed', (tester) async {
    final model = FakeEditors([
      testEditor(acceptedExtensions: const ['md']),
    ]);
    addTearDown(model.dispose);
    await _pumpSection(tester, model);
    expect(find.text('No per-extension defaults'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('editors.binding.add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('editors.binding.extension')),
      ' .MD ',
    );
    await tester.tap(find.byKey(const ValueKey('editors.binding.editor')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Editor').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editors.binding.save')));
    await tester.pumpAndSettle();

    expect(model.calls, ['setExtensionDefault:md=editor.test']);
    expect(find.byKey(const ValueKey('editors.binding.md')), findsOneWidget);
    expect(find.text('*.md'), findsWidgets);

    await tester.tap(find.byKey(const ValueKey('editors.binding.remove.md')));
    await tester.pumpAndSettle();
    expect(model.registry.extensionDefaults, isEmpty);
    expect(model.calls.last, 'setExtensionDefault:md=null');
  });

  testWidgets('the binding dialog refuses a list and an editor that does not '
      'accept the extension', (tester) async {
    final model = FakeEditors([
      testEditor(acceptedExtensions: const ['md']),
    ]);
    addTearDown(model.dispose);
    await _pumpSection(tester, model);
    await tester.tap(find.byKey(const ValueKey('editors.binding.add')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('editors.binding.extension')),
      'txt, md',
    );
    await tester.tap(find.byKey(const ValueKey('editors.binding.save')));
    await tester.pumpAndSettle();
    expect(find.text('Enter one extension'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('editors.binding.extension')),
      'txt',
    );
    await tester.tap(find.byKey(const ValueKey('editors.binding.editor')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Test Editor').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editors.binding.save')));
    await tester.pumpAndSettle();
    expect(find.text('Test Editor does not open .txt'), findsOneWidget);
    expect(model.calls, isEmpty);
  });

  testWidgets('a host without desktop editors explains instead of adding', (
    tester,
  ) async {
    debugEditorHostPlatform = () => null;
    final model = FakeEditors();
    addTearDown(model.dispose);
    await _pumpSection(tester, model);

    expect(find.byKey(const ValueKey('editors.add')), findsNothing);
    expect(find.byKey(const ValueKey('editors.binding.add')), findsNothing);
    expect(find.text('Desktop only'), findsOneWidget);
  });

  testWidgets('a failed write reaches onError', (tester) async {
    final model = FakeEditors([testEditor()]);
    addTearDown(model.dispose);
    await _pumpSection(tester, model);
    model.failNext = StateError('disk full');

    await tester.tap(find.byKey(const ValueKey('editors.default')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Built-in text editor').last);
    await tester.pumpAndSettle();

    expect(_errors.single, isA<StateError>());
    expect(model.registry.defaultEditorId, EditorRegistry.systemDefaultId);
  });
}
