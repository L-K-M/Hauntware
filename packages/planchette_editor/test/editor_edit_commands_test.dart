import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

EditorController controller(
  String text, {
  String path = 'notes.txt',
  int caret = 0,
  bool locked = false,
}) {
  final editor = EditorController(
    displayPath: path,
    initialText: text,
    undoQuiet: Duration.zero,
  );
  addTearDown(editor.dispose);
  if (locked) editor.setEditingLocked(true);
  editor.text.selection = TextSelection.collapsed(offset: caret);
  return editor;
}

void mockClipboard({String? getText, void Function(String? setText)? onSet}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') {
          return getText == null ? null : {'text': getText};
        }
        if (call.method == 'Clipboard.setData') {
          onSet?.call((call.arguments as Map)['text'] as String?);
        }
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('selectLine selects the caret line and works while locked', () {
    final editor = controller('one\ntwo\nthree', caret: 5, locked: true);
    expect(editor.canEditText, isFalse);
    expect(editor.selectLine(), isTrue);
    expect(
      editor.text.selection,
      const TextSelection(baseOffset: 4, extentOffset: 7),
    );
  });

  test('selectParagraph selects the run of non-blank lines', () {
    final editor = controller('a\nb\n\nc\nd', caret: 0);
    expect(editor.selectParagraph(), isTrue);
    expect(
      editor.text.selection,
      const TextSelection(baseOffset: 0, extentOffset: 3),
    );
  });

  test('selectEnclosingBrackets balances and expands', () {
    final editor = controller('a(b[c]d)e', caret: 4);
    expect(editor.selectEnclosingBrackets(), isTrue);
    expect(
      editor.text.text.substring(
        editor.text.selection.start,
        editor.text.selection.end,
      ),
      '[c]',
    );
    expect(editor.selectEnclosingBrackets(), isTrue);
    expect(
      editor.text.text.substring(
        editor.text.selection.start,
        editor.text.selection.end,
      ),
      '(b[c]d)',
    );
  });

  test('selectEnclosingBrackets is false with no pair', () {
    final editor = controller('abc', caret: 1);
    expect(editor.selectEnclosingBrackets(), isFalse);
  });

  test('insertLineBelow inserts an indented line', () {
    final editor = controller('  ab', caret: 4);
    expect(editor.insertLineBelow(), isTrue);
    expect(editor.text.text, '  ab\n  ');
    expect(editor.text.selection.isCollapsed, isTrue);
  });

  test('insertLineAbove keeps CRLF', () {
    final editor = controller('a\r\nb', caret: 3);
    expect(editor.insertLineAbove(), isTrue);
    expect(editor.text.text, 'a\r\n\r\nb');
  });

  test('increment and decrement keep literal shape', () {
    final editor = controller('n009', caret: 4);
    expect(editor.incrementNumber(), isTrue);
    expect(editor.text.text, 'n010');
    expect(editor.decrementNumber(), isTrue);
    expect(editor.text.text, 'n009');
  });

  test('increment is false with no number and while locked', () {
    final editor = controller('abc', caret: 1);
    expect(editor.incrementNumber(), isFalse);
    final locked = controller('a1', caret: 2, locked: true);
    expect(locked.incrementNumber(), isFalse);
  });

  test('copyLine copies the caret line', () async {
    String? copied;
    mockClipboard(onSet: (text) => copied = text);
    final editor = controller('a\nb\nc', caret: 2);
    expect(await editor.copyLine(), isTrue);
    expect(copied, 'b\n');
    expect(editor.text.text, 'a\nb\nc');
  });

  test('copyLine works while locked', () async {
    String? copied;
    mockClipboard(onSet: (text) => copied = text);
    final editor = controller('a\nb', caret: 0, locked: true);
    expect(await editor.copyLine(), isTrue);
    expect(copied, 'a\n');
  });

  test('cutLine copies and removes the line', () async {
    String? copied;
    mockClipboard(onSet: (text) => copied = text);
    final editor = controller('a\nb\nc', caret: 2);
    expect(await editor.cutLine(), isTrue);
    expect(copied, 'b\n');
    expect(editor.text.text, 'a\nc');
  });

  test('cutLine keeps the text when the buffer moves mid-copy', () async {
    final editor = controller('a\nb\nc', caret: 2);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            editor.text.text = 'changed';
          }
          return null;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null),
    );
    expect(await editor.cutLine(), isFalse);
    expect(editor.text.text, 'changed');
  });

  test('pasteAndMatchIndentation reindents later lines', () async {
    mockClipboard(getText: 'x\n  y');
    final editor = controller('  a', caret: 3);
    expect(await editor.pasteAndMatchIndentation(), isTrue);
    expect(editor.text.text, '  ax\n  y');
  });

  test('pasteAndMatchIndentation refuses an empty clipboard', () async {
    mockClipboard(getText: null);
    final editor = controller('  a', caret: 3);
    expect(await editor.pasteAndMatchIndentation(), isFalse);
    expect(editor.text.text, '  a');
  });

  test('toggleComment falls back to block markers in XML', () {
    final editor = controller('<a>hi</a>', path: 'page.html', caret: 4);
    expect(editor.canToggleComment, isTrue);
    expect(editor.toggleComment(), isTrue);
    expect(editor.text.text, '<!-- <a>hi</a> -->');
    expect(editor.toggleComment(), isTrue);
    expect(editor.text.text, '<a>hi</a>');
  });

  test('toggleComment falls back to block markers in CSS', () {
    final editor = controller('a { color: red; }', path: 'style.css', caret: 3);
    expect(editor.canToggleComment, isTrue);
    expect(editor.toggleComment(), isTrue);
    expect(editor.text.text.contains('/*'), isTrue);
  });

  test('selection commands refuse composition', () {
    final editor = controller('one\ntwo', caret: 2);
    editor.text.value = const TextEditingValue(
      text: 'one\ntwo',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 3),
    );
    expect(editor.selectLine(), isFalse);
    expect(editor.insertLineBelow(), isFalse);
  });
}
