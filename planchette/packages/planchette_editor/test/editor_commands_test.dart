import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

/// A shell script, so Toggle Comment has a marker. The caret sits inside
/// `41`, inside the parentheses, on the middle line: every command finds
/// something to act on.
const _script = 'one\n  f(x, 41)\nthree';
const _insideNumber = 12;

EditorController _controller({bool locked = false, String path = 'a.sh'}) {
  final editor = EditorController(
    displayPath: path,
    initialText: _script,
    undoQuiet: Duration.zero,
  );
  addTearDown(editor.dispose);
  if (locked) editor.setEditingLocked(true);
  editor.text.selection = const TextSelection.collapsed(offset: _insideNumber);
  return editor;
}

void _mockClipboard() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'p\n q'};
        return null;
      });
  addTearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );
}

/// The controller method each command stands for.
final Map<EditorCommand, Future<bool> Function(EditorController)> _direct = {
  EditorCommand.duplicateLines: (c) async => c.duplicateLines(),
  EditorCommand.moveLinesUp: (c) async => c.moveLines(LineDirection.up),
  EditorCommand.moveLinesDown: (c) async => c.moveLines(LineDirection.down),
  EditorCommand.deleteLines: (c) async => c.deleteLines(),
  EditorCommand.joinLines: (c) async => c.joinLines(),
  EditorCommand.toggleComment: (c) async => c.toggleComment(),
  EditorCommand.selectLine: (c) async => c.selectLine(),
  EditorCommand.selectParagraph: (c) async => c.selectParagraph(),
  EditorCommand.selectEnclosingBrackets: (c) async =>
      c.selectEnclosingBrackets(),
  EditorCommand.insertLineAbove: (c) async => c.insertLineAbove(),
  EditorCommand.insertLineBelow: (c) async => c.insertLineBelow(),
  EditorCommand.copyLine: (c) => c.copyLine(),
  EditorCommand.cutLine: (c) => c.cutLine(),
  EditorCommand.incrementNumber: (c) async => c.incrementNumber(),
  EditorCommand.decrementNumber: (c) async => c.decrementNumber(),
  EditorCommand.pasteAndMatchIndentation: (c) => c.pasteAndMatchIndentation(),
  EditorCommand.goToMatchingBracket: (c) async => c.goToMatchingBracket(),
  EditorCommand.selectToMatchingBracket: (c) async =>
      c.goToMatchingBracket(extend: true),
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every command runs the controller method it names', () async {
    _mockClipboard();
    // Find in Selection returns nothing to compare, and the script has no
    // problems to step through; each has its own test.
    expect(
      _direct.keys.toSet(),
      EditorCommand.values.toSet()..removeAll({
        EditorCommand.findInSelection,
        EditorCommand.nextProblem,
        EditorCommand.previousProblem,
      }),
    );
    for (final MapEntry(key: command, value: direct) in _direct.entries) {
      final viaCommand = _controller();
      final viaMethod = _controller();

      final ran = await viaCommand.runCommand(command);
      expect(ran, isTrue, reason: '$command found nothing to act on');
      expect(ran, await direct(viaMethod), reason: '$command');
      expect(viaCommand.text.text, viaMethod.text.text, reason: '$command');
      expect(
        viaCommand.text.selection,
        viaMethod.text.selection,
        reason: '$command',
      );
    }
  });

  test('Find in Selection scopes the find bar to the selection', () async {
    final editor = _controller();
    expect(await editor.runCommand(EditorCommand.findInSelection), isFalse);
    expect(editor.searchOpen, isFalse);

    editor.text.selection = const TextSelection(
      baseOffset: 4,
      extentOffset: 14,
    );
    expect(await editor.runCommand(EditorCommand.findInSelection), isTrue);
    expect(editor.searchOpen, isTrue);
    expect(editor.searchScope, const TextRange(start: 4, end: 14));
  });

  test('a lock refuses edits but not caret moves', () async {
    final editor = _controller(locked: true);
    const caretOnly = {
      EditorCommand.selectLine,
      EditorCommand.selectParagraph,
      EditorCommand.selectEnclosingBrackets,
      EditorCommand.copyLine,
      EditorCommand.goToMatchingBracket,
      EditorCommand.selectToMatchingBracket,
    };

    // Find in Selection is off too: the caret is collapsed.
    for (final command in EditorCommand.values) {
      expect(
        editor.canRunCommand(command),
        caretOnly.contains(command),
        reason: '$command',
      );
    }
    // Each refused command's own guard agrees with its row.
    _mockClipboard();
    for (final command in EditorCommand.values) {
      if (caretOnly.contains(command)) continue;
      expect(await editor.runCommand(command), isFalse, reason: '$command');
    }
    expect(editor.text.text, _script);
  });

  test('a locked document still finds in its selection', () async {
    // Find reads the document; the lock only refuses edits.
    final editor = _controller(locked: true);
    editor.text.selection = const TextSelection(
      baseOffset: 4,
      extentOffset: 14,
    );

    expect(editor.canRunCommand(EditorCommand.findInSelection), isTrue);
    expect(await editor.runCommand(EditorCommand.findInSelection), isTrue);
    expect(editor.searchScope, const TextRange(start: 4, end: 14));
  });

  test('Toggle Comment needs a language with a comment marker', () {
    expect(
      _controller(path: 'notes.txt').canRunCommand(EditorCommand.toggleComment),
      isFalse,
    );
    expect(_controller().canRunCommand(EditorCommand.toggleComment), isTrue);
  });

  test('every command has its own label', () {
    const strings = EditorStrings();
    final labels = {
      for (final command in EditorCommand.values)
        strings.editorCommandLabel(command),
    };
    expect(labels, hasLength(EditorCommand.values.length));
    expect(labels, everyElement(isNotEmpty));
  });
}
