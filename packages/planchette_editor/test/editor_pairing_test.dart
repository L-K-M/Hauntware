import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

EditorController editorFor(String text, {String path = 'a.txt'}) =>
    EditorController(displayPath: path, initialText: text);

/// Type [typed] the way the platform delivers a keystroke: any active
/// selection is replaced, and the caret lands after what was typed.
///
/// A raw key event cannot stand in for this. Enter and the bracket keys reach
/// the buffer as a text-input update from the platform, not as a shortcut, so
/// `sendKeyEvent` inserts nothing at all in a widget test.
void type(EditorController c, String typed) {
  final value = c.text.value;
  final base = value.selection.baseOffset.clamp(0, value.text.length);
  final extent = value.selection.extentOffset.clamp(0, value.text.length);
  final at = base <= extent ? base : extent;
  final end = base <= extent ? extent : base;
  c.text.value = value.copyWith(
    text: value.text.replaceRange(at, end, typed),
    selection: TextSelection.collapsed(offset: at + typed.length),
  );
}

/// Mounts an editor holding [text] with the caret at its end and reports the
/// platform answers [clipboard] should give until the returned reset runs.
Future<EditorController> _editorWithClipboard(
  WidgetTester tester,
  String text,
  Future<Object?> Function(MethodCall call) clipboard,
) async {
  final c = editorFor(text, path: 'a.json');
  addTearDown(c.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: PlanchetteEditor(controller: c)),
    ),
  );
  c.editorFocus.requestFocus();
  c.text.selection = TextSelection.collapsed(offset: c.text.text.length);
  await tester.pump();
  await tester.showKeyboard(find.byType(TextField));
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async => call.method == 'Clipboard.getData' ? clipboard(call) : null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return c;
}

/// Invokes the field's paste intent from inside the editable, the way a real
/// Ctrl+V reaches it from the focused context.
void _paste(WidgetTester tester) {
  BuildContext? inner;
  tester
      .element(find.byType(EditableText))
      .visitChildElements((element) => inner ??= element);
  Actions.invoke(inner!, const PasteTextIntent(SelectionChangedCause.keyboard));
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

    test('a closer at the buffer start is a real bracket', () {
      // No opener can sit before offset 0, so the ) before ) inserts.
      final c = editorFor(')', path: 'a.json');
      addTearDown(c.dispose);
      c.text.selection = const TextSelection.collapsed(offset: 0);

      type(c, ')');
      expect(c.text.text, '))');
      expect(c.text.selection.extentOffset, 1);
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

    test('an apostrophe mid-word does not pair', () {
      // don| typed ' grows the contraction don't, not a stranded don''.
      final c = editorFor('don', path: 'a.yaml');
      addTearDown(c.dispose);
      c.text.selection = const TextSelection.collapsed(offset: 3);

      type(c, "'");
      expect(c.text.text, "don'");
      expect(c.text.selection.extentOffset, 4);
    });

    test('a quote before the same quote steps over it', () {
      // Typing " before '"x"' closes 'log"' — inserting would strand one.
      final c = editorFor('"x"', path: 'a.json');
      addTearDown(c.dispose);
      c.text.selection = const TextSelection.collapsed(offset: 0);

      type(c, '"');
      expect(c.text.text, '"x"');
      expect(c.text.selection.extentOffset, 1);
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

  group('programmatic writes are verbatim', () {
    test('an initial buffer of a single opener stays one character', () {
      final c = editorFor('(', path: 'a.json');
      addTearDown(c.dispose);
      expect(c.text.text, '(');
    });

    test('a loaded document is installed exactly as it arrived', () async {
      final c = EditorController(
        displayPath: 'a.json',
        loadDocument: () async => TextDocument(
          file: File('${Directory.systemTemp.path}/paired.json'),
          text: '(',
          hasUtf8Bom: false,
          lineEnding: LineEnding.lf,
          sha256: 'one',
        ),
      );
      addTearDown(c.dispose);
      await c.initialize();
      expect(c.text.text, '(');
    });

    test('a replace that lands a bracket stays verbatim', () async {
      // 'a' -> 'a(' is a one-character growth at a collapsed caret — the
      // same shape a keystroke has — but a command result is not typing.
      final c = editorFor('a', path: 'a.json');
      addTearDown(c.dispose);
      c.openSearch();
      c.search.text = 'a';
      c.replacement.text = 'a(';
      expect(await c.replaceAll(), isTrue);
      expect(c.text.text, 'a(');
    });
  });

  group('paste', () {
    testWidgets('a one-character paste lands verbatim, never a pair', (
      tester,
    ) async {
      final c = await _editorWithClipboard(
        tester,
        'x',
        (_) async => <String, dynamic>{'text': '('},
      );
      _paste(tester);
      await tester.pump();
      expect(c.text.text, 'x(');
    });

    testWidgets('an empty clipboard leaves the next typed bracket pairing', (
      tester,
    ) async {
      // Paste suppression marks the paste's own write, so a paste that never
      // writes must not hold anything back: the next keystroke pairs as usual.
      final c = await _editorWithClipboard(tester, 'x', (_) async => null);
      _paste(tester);
      await tester.pump();

      type(c, '(');
      await tester.pump();
      expect(c.text.text, 'x()');
    });

    testWidgets('a bracket typed during a pending paste still pairs', (
      tester,
    ) async {
      // The clipboard has not answered when the keystroke lands — the
      // keystroke pairs, and the paste's own write still lands verbatim
      // behind it rather than completing the pair the keystroke opened.
      final clipboard = Completer<Object?>();
      final c = await _editorWithClipboard(
        tester,
        'x',
        (_) => clipboard.future,
      );
      _paste(tester);

      type(c, '(');
      await tester.pump();
      expect(c.text.text, 'x()');

      clipboard.complete(<String, dynamic>{'text': '('});
      await tester.pump();
      expect(c.text.text, 'x(()');
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

  testWidgets('one undo removes the whole auto-pair', (tester) async {
    // The closer lands microseconds after the platform's keystroke, inside
    // the undo merge window — a single undo must take the pair away rather
    // than strand the closer.
    final c = editorFor('x', path: 'a.json');
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlanchetteEditor(controller: c)),
      ),
    );
    c.editorFocus.requestFocus();
    c.text.selection = TextSelection.collapsed(offset: c.text.text.length);
    await tester.pump();
    // Let the undo history's merge window close so the mounted buffer is a
    // step of its own before the keystroke arrives.
    await tester.pump(const Duration(milliseconds: 600));

    type(c, '{');
    await tester.pump();
    expect(c.text.text, 'x{}');
    await tester.pump(const Duration(milliseconds: 600));

    c.undo();
    await tester.pump();
    expect(c.text.text, 'x');
  });
}
