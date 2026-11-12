// 03 §8.5: every file editor's font and text size, kept per device and set
// in Settings → Appearance.
import 'dart:io' show Directory, File, FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/ghost_fonts.dart' show resolveMonoFamily;
import 'package:klabautermann_app/controllers/editor_display.dart';
import 'package:klabautermann_app/ui/edit/editor_display_scope.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_editor/planchette_editor.dart'
    show EditorController, EditorLigatures, EditorTextSize, PlanchetteEditor;

void main() {
  test('a text size outside the offered ones is clamped', () {
    expect(EditorDisplay(textSize: 4).textSize, EditorTextSize.minimum);
    expect(EditorDisplay(textSize: 99).textSize, EditorTextSize.maximum);
    expect(EditorDisplay().textSize, EditorTextSize.standard);
  });

  test('a blank family is the editor default', () {
    expect(EditorDisplay(family: '  ').chosenFamily, isNull);
    expect(EditorDisplay(family: 'Fira Code').chosenFamily, 'Fira Code');
  });

  test('a change applies before it is saved, says when it was not saved, '
      'and picking it again retries the save', () async {
    final saved = <(String?, bool, int)>[];
    var failing = true;
    final display = EditorDisplayController(
      save: (family, ligatures, textSize) async {
        if (failing) throw const FileSystemException('disk full');
        saved.add((family, ligatures == EditorLigatures.on, textSize));
      },
    );
    addTearDown(display.dispose);
    final big = EditorDisplay(
      family: 'Fira Code',
      ligatures: EditorLigatures.off,
      textSize: 24,
    );

    await expectLater(
      display.setEditorDisplay(big),
      throwsA(isA<EditorDisplayNotSavedException>()),
    );
    expect(display.value, big, reason: 'it still applies');

    failing = false;
    await display.setEditorDisplay(big);
    expect(saved, [('Fira Code', false, 24)]);
    await display.setEditorDisplay(big);
    expect(saved, hasLength(1), reason: 'in force and saved');
  });

  test('the store round-trips the editor display', () async {
    final directory = Directory.systemTemp.createTempSync(
      'klab-editor-display-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/$deviceSettingsFileName');

    final first = await DeviceSettingsStore.open(file);
    await first.setEditorDisplay('Fira Code', false, 24);
    expect(first.editorFontFamily, 'Fira Code');
    expect(first.editorLigatures, isFalse);
    expect(first.editorTextSize, 24);

    final second = await DeviceSettingsStore.open(file);
    expect(second.issue, isNull);
    expect(second.editorFontFamily, 'Fira Code');
    expect(second.editorLigatures, isFalse);
    expect(second.editorTextSize, 24);

    // A null family removes the key and reads as the default.
    await second.setEditorDisplay(null, true, EditorTextSize.standard);
    final third = await DeviceSettingsStore.open(file);
    expect(third.editorFontFamily, isNull);
    expect(third.editorLigatures, isTrue);
    expect(third.editorTextSize, EditorTextSize.standard);
  });

  testWidgets('an editor picks up a display change from its scope', (
    tester,
  ) async {
    final display = EditorDisplayController();
    final controller = EditorController(
      displayPath: '/srv/notes.txt',
      initialText: 'one\ntwo\n',
    );
    addTearDown(() {
      display.dispose();
      controller.dispose();
    });
    Future<void> pump() => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditorDisplayScope(
            display: display,
            child: Builder(
              builder: (context) {
                final scope = EditorDisplayScope.maybeOf(context) ??
                    EditorDisplay.standard;
                return PlanchetteEditor(
                  controller: controller,
                  textStyle: editorDisplayTextStyle(scope),
                  ligatures: scope.ligatures,
                );
              },
            ),
          ),
        ),
      ),
    );

    await pump();
    final editor = find.byType(PlanchetteEditor);
    expect(
      tester.widget<PlanchetteEditor>(editor).ligatures,
      EditorLigatures.on,
    );
    expect(
      tester.widget<PlanchetteEditor>(editor).textStyle.fontSize,
      EditorTextSize.standard.toDouble(),
    );

    await display.setEditorDisplay(
      EditorDisplay(
        family: 'Fira Code',
        ligatures: EditorLigatures.off,
        textSize: 24,
      ),
    );
    await tester.pump();

    final updated = tester.widget<PlanchetteEditor>(editor);
    expect(updated.ligatures, EditorLigatures.off);
    expect(updated.textStyle.fontSize, 24);
    expect(updated.textStyle.fontFamily, resolveMonoFamily('Fira Code'));
  });
}
