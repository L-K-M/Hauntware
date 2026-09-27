import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

Widget app(
  EditorController c, {
  bool locked = false,
  EditorIndent indent = const EditorIndent(),
}) => MaterialApp(
  home: Scaffold(
    body: PlanchetteEditor(
      controller: c,
      editingLocked: locked,
      indent: indent,
    ),
  ),
);

Finder field(EditorController c) =>
    find.byKey(const ValueKey('planchette.document'));

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

Future<void> mount(
  WidgetTester tester,
  EditorController c, {
  bool locked = false,
  EditorIndent indent = const EditorIndent(),
}) async {
  await tester.pumpWidget(app(c, locked: locked, indent: indent));
  await tester.pump();
  c.editorFocus.requestFocus();
  await tester.pump();
}

Future<void> pressTab(WidgetTester tester, {bool shift = false}) async {
  if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
}

void main() {
  group('Tab', () {
    testWidgets('inserts one indent unit at the line start', (tester) async {
      final c = editorFor('one');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await pressTab(tester);
      expect(c.text.text, '  one');
      expect(c.text.selection.extentOffset, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('adds a level rather than replacing the existing indent', (
      tester,
    ) async {
      final c = editorFor('    one');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await pressTab(tester);
      expect(c.text.text, '      one');
      expect(tester.takeException(), isNull);
    });

    testWidgets('indents every line a selection spans', (tester) async {
      final c = editorFor('one\ntwo\nthree');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection(baseOffset: 0, extentOffset: 8);
      await tester.pump();

      await pressTab(tester);
      expect(c.text.text, '  one\n  two\nthree');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a selection ending on a line start leaves that line alone', (
      tester,
    ) async {
      final c = editorFor('one\ntwo');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection(baseOffset: 0, extentOffset: 4);
      await tester.pump();

      await pressTab(tester);
      expect(c.text.text, '  one\ntwo');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Shift+Tab removes one level', (tester) async {
      final c = editorFor('    one');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await pressTab(tester, shift: true);
      expect(c.text.text, '  one');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Shift+Tab on an unindented line does nothing', (tester) async {
      final c = editorFor('one');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await pressTab(tester, shift: true);
      expect(c.text.text, 'one');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tab-indented file keeps using tabs', (tester) async {
      final c = editorFor('one');
      addTearDown(c.dispose);
      await mount(tester, c, indent: const EditorIndent(usesTabs: true));
      c.text.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await pressTab(tester);
      expect(c.text.text, '\tone');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a four-space document indents by four', (tester) async {
      final c = editorFor('one');
      addTearDown(c.dispose);
      await mount(tester, c, indent: const EditorIndent(size: 4));
      c.text.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await pressTab(tester);
      expect(c.text.text, '    one');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a locked editor does not indent', (tester) async {
      final c = editorFor('one');
      addTearDown(c.dispose);
      await mount(tester, c, locked: true);
      c.text.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await pressTab(tester);
      expect(c.text.text, 'one');
      expect(tester.takeException(), isNull);
    });

    testWidgets('Tab stays in the document rather than moving focus', (
      tester,
    ) async {
      final c = editorFor('one');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();

      await pressTab(tester);
      expect(c.editorFocus.hasFocus, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('Enter', () {
    testWidgets('carries the current indentation', (tester) async {
      final c = editorFor('    one');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 7);
      await tester.pump();

      type(c, '\n');
      await tester.pump();
      expect(c.text.text, '    one\n    ');
      expect(c.text.selection.extentOffset, 12);
      expect(tester.takeException(), isNull);
    });

    testWidgets('indents a block opened by a brace', (tester) async {
      final c = editorFor('  {', path: 'a.json');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();

      type(c, '\n');
      await tester.pump();
      expect(c.text.text, '  {\n    ');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a YAML key indents its block', (tester) async {
      final c = editorFor('services:', path: 'docker-compose.yml');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 9);
      await tester.pump();

      type(c, '\n');
      await tester.pump();
      expect(c.text.text, 'services:\n  ');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a colon in Dart is punctuation, not a block', (tester) async {
      final c = editorFor('var x:', path: 'a.dart');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 6);
      await tester.pump();

      type(c, '\n');
      await tester.pump();
      expect(c.text.text, 'var x:\n');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a blank line keeps its own spacing and gains nothing', (
      tester,
    ) async {
      final c = editorFor('   ');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();

      type(c, '\n');
      await tester.pump();
      expect(c.text.text, '   \n   ');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a locked editor does not auto-indent', (tester) async {
      final c = editorFor('  x');
      addTearDown(c.dispose);
      await mount(tester, c, locked: true);
      c.text.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();

      type(c, '\n');
      await tester.pump();
      expect(c.text.text, '  x\n');
      expect(tester.takeException(), isNull);
    });
  });

  group('bracket pairing', () {
    testWidgets('an opener brings its closer and leaves the caret inside', (
      tester,
    ) async {
      final c = editorFor('', path: 'a.json');
      addTearDown(c.dispose);
      await mount(tester, c);

      type(c, '{');
      await tester.pump();
      expect(c.text.text, '{}');
      expect(c.text.selection.extentOffset, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('typing the closer moves over it', (tester) async {
      final c = editorFor('{}', path: 'a.json');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      type(c, '}');
      await tester.pump();
      expect(c.text.text, '{}');
      expect(c.text.selection.extentOffset, 2);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a closer with something else after it is a real bracket', (
      tester,
    ) async {
      final c = editorFor('x)y', path: 'a.json');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 1);
      await tester.pump();

      type(c, ')');
      await tester.pump();
      expect(c.text.text, 'x))y');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a quote pairs', (tester) async {
      final c = editorFor('', path: 'a.yaml');
      addTearDown(c.dispose);
      await mount(tester, c);

      type(c, "'");
      await tester.pump();
      expect(c.text.text, "''");
      expect(c.text.selection.extentOffset, 1);
      expect(tester.takeException(), isNull);
    });

    testWidgets('prose is left alone', (tester) async {
      // Markdown has brackets as content, not as syntax. Pairing there is noise.
      final c = editorFor('', path: 'notes.md');
      addTearDown(c.dispose);
      await mount(tester, c);

      type(c, '(');
      await tester.pump();
      expect(c.text.text, '(');
      expect(tester.takeException(), isNull);
    });

    testWidgets('an unknown file type is left alone', (tester) async {
      final c = editorFor('', path: 'mystery');
      addTearDown(c.dispose);
      await mount(tester, c);

      type(c, '{');
      await tester.pump();
      expect(c.text.text, '{');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a locked editor does not pair', (tester) async {
      final c = editorFor('', path: 'a.json');
      addTearDown(c.dispose);
      await mount(tester, c, locked: true);

      type(c, '{');
      await tester.pump();
      expect(c.text.text, '{');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a pasted block is left exactly as it arrived', (tester) async {
      final c = editorFor('', path: 'a.json');
      addTearDown(c.dispose);
      await mount(tester, c);
      final pasted = '{\n  "a": 1\n}';
      c.text.value = TextEditingValue(
        text: pasted,
        selection: TextSelection.collapsed(offset: pasted.length),
      );
      await tester.pump();

      expect(c.text.text, pasted);
      expect(tester.takeException(), isNull);
    });

    testWidgets('undo removes an automatic indent', (tester) async {
      final c = editorFor('  x');
      addTearDown(c.dispose);
      await mount(tester, c);
      c.text.selection = const TextSelection.collapsed(offset: 3);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      type(c, '\n');
      await tester.pump(const Duration(milliseconds: 600));
      expect(c.text.text, '  x\n  ');

      c.undoController.undo();
      await tester.pump();
      expect(c.text.text, '  x');
      expect(tester.takeException(), isNull);
    });
  });

  test('the indent unit is what the settings say', () {
    expect(const EditorIndent().unit, '  ');
    expect(const EditorIndent(size: 4).unit, '    ');
    expect(const EditorIndent(size: 8).unit, '        ');
    expect(const EditorIndent(usesTabs: true).unit, '\t');
    expect(const EditorIndent(usesTabs: true, size: 4).unit, '\t');
    // A hostile size must not allocate a gigabyte of spaces.
    expect(const EditorIndent(size: 1000).unit.length, 16);
    expect(const EditorIndent(size: -4).unit, '');
  });
}
