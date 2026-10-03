import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

EditorController editorFor(String text, {String path = 'a.txt'}) =>
    EditorController(displayPath: path, initialText: text);

/// Type [typed] at the caret, the way the platform delivers a keystroke: the
/// buffer changes and the caret lands after what was typed.
///
/// A raw key event cannot stand in for this. Enter and the bracket keys reach
/// the buffer as a text-input update from the platform, not as a shortcut, so
/// `sendKeyEvent` inserts nothing at all in a widget test.
void type(EditorController c, String typed) {
  final value = c.text.value;
  final at = value.selection.extentOffset.clamp(0, value.text.length);
  c.text.value = value.copyWith(
    text: value.text.replaceRange(at, at, typed),
    selection: TextSelection.collapsed(offset: at + typed.length),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bracket pairing', () {
    test('an opener brings its closer and leaves the caret inside', () {
      final c = editorFor('', path: 'a.json');
      addTearDown(c.dispose);

      type(c, '{');
      expect(c.text.text, '{}');
      expect(c.text.selection.extentOffset, 1);

      type(c, '(');
      expect(c.text.text, '{()}');
      expect(c.text.selection.extentOffset, 2);
    });

    test('typing the closer moves over it', () {
      final c = editorFor('{}', path: 'a.json');
      addTearDown(c.dispose);
      c.text.selection = const TextSelection.collapsed(offset: 1);

      type(c, '}');
      expect(c.text.text, '{}');
      expect(c.text.selection.extentOffset, 2);
    });

    test('a closer with something else after it is a real bracket', () {
      final c = editorFor('x)y', path: 'a.json');
      addTearDown(c.dispose);
      c.text.selection = const TextSelection.collapsed(offset: 1);

      type(c, ')');
      expect(c.text.text, 'x))y');
      expect(c.text.selection.extentOffset, 2);
    });

    test('a closer in prose is a character, not a skip request', () {
      // Markdown brackets are content. Stepping over one would delete what
      // the user typed for no reason.
      final c = editorFor('a {} b', path: 'notes.md');
      addTearDown(c.dispose);
      // Between the brace and the brace, which is exactly where a skip would
      // fire in a language that pairs.
      c.text.selection = const TextSelection.collapsed(offset: 3);

      type(c, '}');
      expect(c.text.text, 'a {}} b');
      expect(c.text.selection.extentOffset, 4);
    });
  });

  group('quote pairing', () {
    test('a quote pairs', () {
      final c = editorFor('', path: 'a.yaml');
      addTearDown(c.dispose);

      type(c, "'");
      expect(c.text.text, "''");
      expect(c.text.selection.extentOffset, 1);
    });

    test('typing the closing quote moves over it', () {
      final c = editorFor("''", path: 'a.yaml');
      addTearDown(c.dispose);
      c.text.selection = const TextSelection.collapsed(offset: 1);

      type(c, "'");
      expect(c.text.text, "''");
      expect(c.text.selection.extentOffset, 2);
    });
  });

  group('what does not pair', () {
    test('prose is left alone', () {
      // Markdown has brackets as content, not as syntax. Pairing there is
      // noise.
      final c = editorFor('', path: 'notes.md');
      addTearDown(c.dispose);

      type(c, '(');
      expect(c.text.text, '(');
    });

    test('an unknown file type is left alone', () {
      final c = editorFor('', path: 'mystery');
      addTearDown(c.dispose);

      type(c, '{');
      expect(c.text.text, '{');
    });

    test('a locked editor does not pair', () {
      final c = editorFor('', path: 'a.json');
      addTearDown(c.dispose);
      c.setEditingLocked(true);

      type(c, '{');
      expect(c.text.text, '{');
    });

    test('a pasted block is left exactly as it arrived', () {
      final c = editorFor('', path: 'a.json');
      addTearDown(c.dispose);
      const pasted = '{\n  "a": 1\n}';
      c.text.value = TextEditingValue(
        text: pasted,
        selection: TextSelection.collapsed(offset: pasted.length),
      );
      expect(c.text.text, pasted);
    });

    test('an active selection is left alone', () {
      // Replacing a selection is not a single-character insertion.
      final c = editorFor('x', path: 'a.json');
      addTearDown(c.dispose);
      c.text.selection = const TextSelection(baseOffset: 0, extentOffset: 1);

      final value = c.text.value;
      c.text.value = value.copyWith(
        text: value.text.replaceRange(0, 1, '('),
        selection: const TextSelection.collapsed(offset: 1),
      );
      expect(c.text.text, '(');
    });
  });

  testWidgets('pairing works through the mounted editor', (tester) async {
    final c = editorFor('void f', path: 'a.dart');
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlanchetteEditor(controller: c)),
      ),
    );
    await tester.pump();
    c.text.selection = TextSelection.collapsed(offset: c.text.text.length);
    await tester.pump();

    type(c, '(');
    await tester.pump();
    expect(c.text.text, 'void f()');
    expect(c.text.selection.extentOffset, 7);
    expect(tester.takeException(), isNull);
  });
}
