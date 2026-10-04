import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planchette_editor/planchette_editor.dart';

const crlfBom = TextDocumentMetadata(
  lineEnding: LineEnding.crlf,
  utf8Bom: Utf8Bom.present,
);
const cleanup = TextSaveOptions(
  trailingWhitespace: TrailingWhitespacePolicy.trim,
  finalNewline: FinalNewlinePolicy.ensure,
);

TextDocument disk(String text) => TextDocument(
  file: File('/tmp/metadata.txt'),
  text: text,
  hasUtf8Bom: true,
  lineEnding: LineEnding.crlf,
  sha256: 'loaded',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loaded CRLF/BOM is clean; property changes can be reverted', () async {
    final c = EditorController(
      displayPath: 'test',
      loadDocument: () async => disk('é\n'),
    );
    addTearDown(c.dispose);
    await c.initialize();
    expect(c.metadata, crlfBom);
    expect(c.isDirty, isFalse);
    expect(c.fileByteCount, 7);
    c.setMetadata(const TextDocumentMetadata());
    expect(c.isDirty, isTrue);
    expect(c.text.text, 'é\n');
    expect(c.fileByteCount, 3);
    c.indentation = const Indentation.spaces(2);
    c.setMetadata(crlfBom);
    expect(c.isDirty, isFalse);
  });

  test(
    'untitled metadata counts as unsaved and saves without a fake file',
    () async {
      final c = EditorController(
        displayPath: 'Untitled',
        initialText: '',
        saveDocument: (_, baseline) async {
          expect(baseline, isNull);
          return 'saved';
        },
      );
      addTearDown(c.dispose);
      c.setMetadata(crlfBom);
      expect(c.document, isNull);
      expect(c.fileByteCount, 3);
      expect(c.isDirty, isTrue);
      await c.save();
      expect(c.isDirty, isFalse);
    },
  );

  test(
    'saving metadata snapshots the format, keeps newer typing dirty',
    () async {
      final commit = Completer<String>();
      TextDocument? snapshot;
      final c = EditorController(
        displayPath: 'test',
        loadDocument: () async => disk('old'),
        saveDocument: (_, baseline) {
          snapshot = baseline;
          return commit.future;
        },
      );
      addTearDown(c.dispose);
      await c.initialize();
      c.setMetadata(const TextDocumentMetadata());
      final saving = c.save();
      expect(c.setMetadata(crlfBom), isFalse);
      c.text.text = 'new';
      commit.complete('saved');
      expect((await saving)!.hasUnsavedChanges, isTrue);
      expect(snapshot!.metadata, const TextDocumentMetadata());
      expect(snapshot!.sha256, 'loaded');
      expect(c.document!.sha256, 'saved');
      c.text.text = 'old';
      expect(c.isDirty, isFalse);
    },
  );

  test(
    'failed save keeps metadata dirty; reload restores disk choices',
    () async {
      final c = EditorController(
        displayPath: 'test',
        loadDocument: () async => disk('old'),
        saveDocument: (_, _) async => throw StateError('failed'),
      );
      addTearDown(c.dispose);
      await c.initialize();
      c.setMetadata(const TextDocumentMetadata());
      await expectLater(c.save(), throwsStateError);
      expect(c.isDirty, isTrue);
      await c.reload();
      expect(c.metadata, crlfBom);
      expect(c.isDirty, isFalse);
      c.editingLocked = true;
      expect(c.setMetadata(const TextDocumentMetadata()), isFalse);
    },
  );

  test('metadata changes invalidate a pending discard decision', () async {
    final decision = Completer<bool>();
    final c = EditorController(displayPath: 'Untitled', initialText: '');
    addTearDown(c.dispose);
    c.setMetadata(crlfBom);
    final closing = c.confirmClose(() => decision.future);
    c.setMetadata(const TextDocumentMetadata(utf8Bom: Utf8Bom.present));
    decision.complete(true);
    expect(await closing, isFalse);
  });

  test(
    'Normalize follows the host buffer mode rather than the disk ending',
    () async {
      for (final mode in TextNormalization.values) {
        final c = EditorController(
          displayPath: 'test',
          initialText: 'a\r\nb\rc\n',
          normalization: mode,
          undoQuiet: Duration.zero,
        );
        c.setMetadata(crlfBom);
        await c.runTextTool('normalizeLineEndings');
        expect(
          c.text.text,
          mode == TextNormalization.normalize ? 'a\nb\nc\n' : 'a\r\nb\r\nc\r\n',
        );
        c.dispose();
      }
    },
  );

  test('growth preflight includes BOM and CRLF expansion', () async {
    final c = EditorController(
      displayPath: 'test',
      initialText: 'a\n',
      maximumBytes: 7,
      undoQuiet: Duration.zero,
    );
    addTearDown(c.dispose);
    c.setMetadata(crlfBom);
    final outcome = await c.runTextTool(
      'prefixSuffixLines',
      options: {'text': 'xx'},
    );
    expect(outcome, isA<TextToolRefused>());
    expect(c.text.text, 'a\n');
  });

  test('save cleanup remains visible after failure', () async {
    final c = EditorController(
      displayPath: 'test',
      initialText: 'a  ',
      undoQuiet: Duration.zero,
      saveDocument: (text, _) async {
        expect(text, 'a\n');
        throw StateError('failed');
      },
    )..saveOptions = cleanup;
    addTearDown(c.dispose);
    await expectLater(c.save(), throwsStateError);
    expect(c.text.text, 'a\n');
    expect(c.isDirty, isTrue);
  });

  test(
    'conversion adopts indentation even when no text needs conversion',
    () async {
      final c = EditorController(
        displayPath: 'Untitled',
        initialText: '',
        undoQuiet: Duration.zero,
      );
      addTearDown(c.dispose);
      final outcome = await c.runTextTool('convertIndentationToTabs');
      expect(outcome, isA<TextToolUnchanged>());
      expect(c.indentation.style, IndentStyle.tabs);
      expect(c.isDirty, isFalse);
    },
  );

  test(
    'cleanup refuses an active composition without claiming a save',
    () async {
      var writes = 0;
      final c = EditorController(
        displayPath: 'test',
        initialText: 'old',
        saveDocument: (_, _) async {
          writes++;
          return 'saved';
        },
      )..saveOptions = cleanup;
      addTearDown(c.dispose);
      c.text.value = const TextEditingValue(
        text: 'word  ',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange(start: 0, end: 4),
      );
      expect(await c.save(), isNull);
      expect(writes, 0);
      expect(c.text.text, 'word  ');
      expect(c.isDirty, isTrue);
    },
  );

  testWidgets(
    'cleanup follows newer typing before save and retains edits during write',
    (tester) async {
      final commit = Completer<String>();
      String? saved;
      final c = EditorController(
        displayPath: 'test',
        initialText: 'old',
        saveDocument: (text, _) {
          saved = text;
          return commit.future;
        },
      )..saveOptions = cleanup;
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PlanchetteEditor(controller: c)),
        ),
      );
      await tester.pump(EditorController.defaultUndoQuiet);
      c.text.value = const TextEditingValue(
        text: 'first  ',
        selection: TextSelection.collapsed(offset: 7),
      );
      final saving = c.save();
      final halfQuiet = EditorController.defaultUndoQuiet ~/ 2;
      await tester.pump(halfQuiet);
      c.text.value = const TextEditingValue(
        text: 'second  ',
        selection: TextSelection.collapsed(offset: 8),
      );
      await tester.pump(halfQuiet);
      expect(saved, isNull);
      await tester.pump(halfQuiet);
      expect(saved, 'second\n');
      c.text.value = const TextEditingValue(
        text: 'newer',
        selection: TextSelection.collapsed(offset: 5),
      );
      commit.complete('saved');
      expect((await saving)!.hasUnsavedChanges, isTrue);
      expect(c.text.text, 'newer');
      c.text.value = const TextEditingValue(
        text: 'second\n',
        selection: TextSelection.collapsed(offset: 7),
      );
      expect(c.isDirty, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('cleanup is one undo step and preserves typing before save', (
    tester,
  ) async {
    final c = EditorController(
      displayPath: 'test',
      initialText: 'old',
      saveDocument: (_, _) async => 'saved',
    )..saveOptions = cleanup;
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PlanchetteEditor(controller: c)),
      ),
    );
    await tester.pump(EditorController.defaultUndoQuiet);
    c.text.value = const TextEditingValue(
      text: 'new  ',
      selection: TextSelection.collapsed(offset: 5),
    );
    final saving = c.save();
    await tester.pump(EditorController.defaultUndoQuiet);
    await saving;
    expect(c.text.text, 'new\n');
    expect(c.isDirty, isFalse);
    await tester.pump(EditorController.defaultUndoQuiet);
    c.undoController.undo();
    await tester.pump();
    expect(c.text.text, 'new  ');
    expect(c.isDirty, isTrue);
    c.undoController.redo();
    await tester.pump();
    expect(c.text.text, 'new\n');
    expect(c.isDirty, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
