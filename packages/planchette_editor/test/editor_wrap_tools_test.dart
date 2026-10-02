import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('untitled shebang language supplies wrap comment prefixes', () async {
    const source = '#!/usr/bin/python\n\n# one two three four';
    final c = EditorController(
      displayPath: 'Untitled',
      initialText: source,
      undoQuiet: Duration.zero,
    );
    addTearDown(c.dispose);
    c.text.selection = TextSelection.collapsed(offset: source.length);
    await c.runTextTool('hardWrap', options: {'width': 10});
    expect(c.text.text, '#!/usr/bin/python\n\n# one two\n# three\n# four');
  });
  test('raw-buffer hosts can match a conditional saved-EOL policy', () async {
    final c = EditorController(
      displayPath: 'notes.txt',
      initialText: 'a\nb\n',
      normalization: TextNormalization.preserve,
      saveNormalizationForLineEnding: (ending) => ending == LineEnding.crlf
          ? TextNormalization.normalize
          : TextNormalization.preserve,
      maximumBytes: 7,
      undoQuiet: Duration.zero,
    );
    addTearDown(c.dispose);
    c.setMetadata(const TextDocumentMetadata(lineEnding: LineEnding.crlf));
    expect(c.fileByteCount, 6);
    expect(c.bufferLineEnding, LineEnding.crlf);
    final result = await c.runTextTool(
      'prefixSuffixLines',
      options: {'text': 'x'},
    );
    expect(result, isA<TextToolRefused>());
    expect(c.text.text, 'a\nb\n');
    c.setMetadata(const TextDocumentMetadata());
    expect(c.fileByteCount, 4);
  });
  test(
    'tab conversion width starts with the chosen document setting',
    () async {
      final c = EditorController(
        displayPath: 'notes.txt',
        initialText: 'a\tb',
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      c.indentation = const Indentation.tabs(width: 8);
      c.openTextTool('convertTabsToSpaces');
      expect(c.toolBarOptions['width'], 8);
      await c.runTextTool('convertTabsToSpaces');
      expect(c.text.text, 'a       b');
      expect(
        const EditorStrings().repeatTextToolLabel(c.toolHistory.last),
        contains('Tab width 8'),
      );
    },
  );
  test(
    'hard wrap clamps invalid widths and records explicit options',
    () async {
      final c = EditorController(
        displayPath: 'notes.txt',
        initialText: 'one two',
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      await c.runTextTool('hardWrap', options: {'width': -1});
      expect(c.text.text, 'one\ntwo');
      expect(c.toolHistory.last!.options['width'], 1);
    },
  );
  testWidgets('new wrap tools remain one undo step', (tester) async {
    final c = EditorController(
      displayPath: 'notes.txt',
      initialText: 'one two three four',
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlanchetteEditor(controller: c)),
      ),
    );
    await tester.pump(EditorController.defaultUndoQuiet);
    await c.runTextTool('hardWrap', options: {'width': 10});
    await tester.pump(EditorController.defaultUndoQuiet);
    expect(c.text.text, 'one two\nthree four');
    c.undoController.undo();
    await tester.pump();
    expect(c.text.text, 'one two three four');
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
