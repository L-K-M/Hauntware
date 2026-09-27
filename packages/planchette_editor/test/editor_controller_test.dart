import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

TextDocument document(String text) => TextDocument(
  file: File('/tmp/example.env'),
  text: text,
  hasUtf8Bom: true,
  lineEnding: LineEnding.crlf,
  sha256: 'original',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  _gotoLineTests();
  _gotoLineRevealTests();
  test(
    'save retains new edits and updates the next conflict baseline',
    () async {
      final committed = Completer<String>();
      final baselines = <String?>[];
      final editor = EditorController(
        displayPath: '.env',
        loadDocument: () async => document('before'),
        saveDocument: (text, baseline) {
          baselines.add(baseline?.sha256);
          return baselines.length == 1
              ? committed.future
              : Future.value('second');
        },
      );
      addTearDown(editor.dispose);
      await editor.initialize();
      editor.text.text = 'saved';
      final saving = editor.save();
      editor.text.text = 'newer';
      committed.complete('first');
      expect((await saving)!.hasUnsavedChanges, isTrue);
      expect(editor.isDirty, isTrue);
      await editor.save();
      expect(baselines, ['original', 'first']);
      expect(editor.isDirty, isFalse);
      expect(editor.document!.hasUtf8Bom, isTrue);
      expect(editor.document!.lineEnding, LineEnding.crlf);
    },
  );
  for (final publication in ['none', 'declined', 'failed', 'success']) {
    test('post-save $publication bookkeeping survives disposal', () async {
      final commit = Completer<String>();
      var reconciled = 0;
      var published = 0;
      final editor = EditorController(
        displayPath: 'test.txt',
        initialText: 'before',
        saveDocument: (_, _) => commit.future,
        onSaved: () async {
          reconciled++;
        },
        onPublish: publication == 'none'
            ? null
            : () async {
                published++;
                if (publication == 'failed') throw StateError('upload failed');
                return publication == 'success';
              },
      );
      editor.text.text = 'after';
      final pending = editor.save();
      final outcome = expectLater(
        pending,
        publication == 'failed' ? throwsStateError : completes,
      );
      editor.dispose();
      commit.complete('digest');
      await outcome;
      expect(reconciled, publication == 'success' ? 0 : 1);
      expect(published, publication == 'none' ? 0 : 1);
    });
  }
  test('close rechecks a save begun while discard is pending', () async {
    final discard = Completer<bool>();
    final commit = Completer<String>();
    final editor = EditorController(
      displayPath: 'test',
      initialText: '',
      saveDocument: (_, _) => commit.future,
    );
    addTearDown(editor.dispose);
    editor.text.text = 'dirty';
    final closing = editor.confirmClose(() => discard.future);
    final saving = editor.save();
    discard.complete(true);
    expect(await closing, isFalse);
    commit.complete('digest');
    await saving;
    expect(await editor.confirmClose(() async => false), isTrue);
  });
  test('a discarded revision never authorizes newer edits', () async {
    final decision = Completer<bool>();
    final editor = EditorController(displayPath: 'test', initialText: '');
    addTearDown(editor.dispose);
    editor.text.text = 'first';
    final pending = editor.confirmClose(() => decision.future);
    editor.text.text = 'second';
    decision.complete(true);
    expect(await pending, isFalse);
  });
  test(
    'edit lock blocks replacements and ordinary saves, permits confirmed close save',
    () async {
      var saves = 0;
      final editor = EditorController(
        displayPath: 'test',
        initialText: 'aaa',
        saveDocument: (_, _) async {
          saves++;
          return 'digest';
        },
      );
      addTearDown(editor.dispose);
      editor.openSearch(replace: true);
      editor.search.text = 'a';
      editor.replacement.text = 'b';
      editor.editingLocked = true;
      editor.replaceCurrent();
      editor.replaceAll();
      expect(editor.text.text, 'aaa');
      expect(await editor.save(), isNull);
      await editor.save(access: EditorSaveAccess.confirmedClose);
      expect(saves, 1);
    },
  );
  test(
    'replace all covers beyond the highlight cap using original offsets',
    () {
      final editor = EditorController(
        displayPath: '.env',
        initialText: List.filled(1205, 'a').join(' '),
      );
      addTearDown(editor.dispose);
      editor.openSearch(replace: true);
      editor.search.text = 'a';
      editor.replacement.text = r'a$1';
      expect(editor.matches.length, searchMatchLimit);
      editor.replaceAll();
      expect(editor.text.text, List.filled(1205, r'a$1').join(' '));
      expect(editor.isDirty, isTrue);
    },
  );
  test('replacement respects case mode and preserves search navigation', () {
    final editor = EditorController(
      displayPath: 'test',
      initialText: 'cat CAT cat',
    );
    addTearDown(editor.dispose);
    editor.openSearch(replace: true);
    editor.search.text = 'cat';
    editor.toggleCaseSensitive();
    expect(editor.matches.length, 2);
    editor.replacement.text = 'dog';
    editor.replaceCurrent();
    expect(editor.text.text, 'dog CAT cat');
    editor.nextMatch();
    expect(
      editor.text.selection,
      const TextSelection(baseOffset: 8, extentOffset: 11),
    );
    editor.replaceAll();
    expect(editor.text.text, 'dog CAT dog');
  });
  test('Save As metadata preserves selection and detects the new language', () {
    final editor = EditorController(
      displayPath: 'Untitled',
      initialText: 'APP=true',
    );
    addTearDown(editor.dispose);
    editor.text.selection = const TextSelection.collapsed(offset: 4);
    editor.adoptDocument(document('APP=true'));
    editor.displayPath = '/tmp/.env.local';
    expect(editor.text.language!.id, 'dotenv');
    expect(editor.text.selection.extentOffset, 4);
  });
  test(
    'save snapshots upload ownership while host capabilities change',
    () async {
      final commit = Completer<String>();
      var oldOwnerUploads = 0;
      var newOwnerUploads = 0;
      final editor = EditorController(
        displayPath: 'test',
        initialText: '',
        saveDocument: (_, _) => commit.future,
        onPublish: () async {
          oldOwnerUploads++;
          return true;
        },
      );
      addTearDown(editor.dispose);
      editor.text.text = 'edit';
      final pending = editor.save();
      editor.onPublish = () async {
        newOwnerUploads++;
        return true;
      };
      commit.complete('digest');
      await pending;
      expect(oldOwnerUploads, 1);
      expect(newOwnerUploads, 0);
      editor.onPublish = null;
      expect(editor.canPublish, isFalse);
    },
  );
  test('statistics count UTF-8 and trailing empty lines', () {
    final editor = EditorController(
      displayPath: 'test',
      initialText: 'é\n😀\n',
    );
    addTearDown(editor.dispose);
    expect(editor.byteCount, 8);
    expect(editor.lineStarts, [0, 2, 5]);
    editor.text.selection = const TextSelection.collapsed(offset: 4);
    expect(editor.caretLineColumn, (2, 3));
  });
}

void _gotoLineTests() {
  group('gotoLine', () {
    test('moves the caret to the line start and requests a reveal', () {
      final editor = EditorController(
        displayPath: 'notes.txt',
        initialText: 'one\ntwo\nthree',
      );
      addTearDown(editor.dispose);
      final before = editor.revealRequest;
      editor.gotoLine(3);
      expect(editor.text.selection.extentOffset, 8);
      expect(editor.caretLineColumn, (3, 1));
      expect(editor.revealRequest, greaterThan(before));
    });

    test('clamps out-of-range lines into the document', () {
      final editor = EditorController(
        displayPath: 'notes.txt',
        initialText: 'one\ntwo\n',
      );
      addTearDown(editor.dispose);
      editor.gotoLine(99);
      expect(editor.caretLineColumn.$1, 3);
      editor.gotoLine(0);
      expect(editor.caretLineColumn, (1, 1));
    });

    test('deactivates the find match so the reveal targets the caret', () {
      final editor = EditorController(
        displayPath: 'notes.txt',
        initialText: 'one\ntwo cat\nthree cat',
      );
      addTearDown(editor.dispose);
      editor.openSearch();
      editor.search.text = 'cat';
      editor.nextMatch();
      expect(editor.activeMatch, greaterThanOrEqualTo(0));
      editor.gotoLine(3);
      expect(editor.activeMatch, -1);
      expect(editor.text.activeMatchIndex, -1);
      expect(editor.caretLineColumn.$1, 3);
      // Cycling still works from the reset state.
      editor.nextMatch();
      expect(editor.activeMatch, greaterThanOrEqualTo(0));
    });
  });
}


void _gotoLineRevealTests() {
  testWidgets('gotoLine scrolls the caret line into view', (tester) async {
    final lines = List.generate(120, (i) => 'line ${i + 1}');
    final editor = EditorController(
      displayPath: 'notes.txt',
      initialText: lines.join('\n'),
    );
    addTearDown(editor.dispose);
    await tester.binding.setSurfaceSize(const Size(300, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlanchetteEditor(controller: editor, showStatus: false),
        ),
      ),
    );
    await tester.pump();
    expect(editor.scroll.hasClients, isTrue);
    expect(editor.scroll.offset, 0);
    editor.gotoLine(100);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(editor.scroll.offset, greaterThan(0));

    // And back up: the first line must be reachable again.
    editor.gotoLine(1);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(editor.scroll.offset, 0);
  });
}
