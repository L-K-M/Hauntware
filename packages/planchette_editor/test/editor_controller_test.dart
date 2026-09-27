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
<<<<<<< HEAD

  test('a shebang typed into a buffer names its language', () {
    final editor = EditorController(displayPath: 'Untitled 1', initialText: '');
    addTearDown(editor.dispose);
    expect(editor.text.language, isNull);

    editor.text.text = '#!/usr/bin/env python';
    expect(editor.text.language, SyntaxLanguages.python);

    // The other direction too: undoing the shebang takes the language away.
    editor.text.text = 'print(1)';
    expect(editor.text.language, isNull);

    editor.text.text = '#!/bin/sh\necho hi\n';
    expect(editor.text.language, SyntaxLanguages.shell);
  });

  test(
    'language detection follows the first line of an extensionless file',
    () {
      final editor = EditorController(displayPath: 'script', initialText: '');
      addTearDown(editor.dispose);
      expect(editor.text.language, isNull);
      editor.text.text = 'echo hi\n';
      expect(editor.text.language, isNull);
      editor.text.text = '#!/usr/bin/env ruby\nputs 1\n';
      expect(editor.text.language, SyntaxLanguages.ruby);
    },
  );

  test('a known extension outranks the shebang', () {
    final editor = EditorController(displayPath: 'notes.md', initialText: '');
    addTearDown(editor.dispose);
    editor.text.text = '#!/usr/bin/env python\n';
    expect(editor.text.language, SyntaxLanguages.markdown);
  });

  test('first-line churn keeps a language that never changed', () {
    final editor = EditorController(displayPath: 'script', initialText: '');
    addTearDown(editor.dispose);

    // Every keystroke changes the lead, so detection runs each time and finds
    // nothing to name yet.
    for (final partial in ['#', '#!', '#!/usr', '#!/usr/bin/env pyth']) {
      editor.text.text = partial;
      expect(editor.text.language, isNull, reason: partial);
    }
    editor.text.text = '#!/usr/bin/env python\n';
    expect(editor.text.language, SyntaxLanguages.python);
  });

  test('edits away from the first line leave the language alone', () {
    final editor = EditorController(
      displayPath: 'Untitled 1',
      initialText: '#!/usr/bin/env node\n',
    );
    addTearDown(editor.dispose);
    expect(editor.text.language, SyntaxLanguages.javascript);
    editor.text.text = '#!/usr/bin/env node\nconst a = 1;\n';
    expect(editor.text.language, SyntaxLanguages.javascript);
  });

  test('the per-keystroke language check stays bounded', () {
    final editor = EditorController(displayPath: 'Untitled 1', initialText: '');
    addTearDown(editor.dispose);

    // A shebang past the bounded lead is not a shebang. Pinning the bound
    // keeps it from being widened without a reason.
    editor.text.text = '${'x' * 4096}#!/usr/bin/env python';
    expect(editor.text.language, isNull);
=======
  test('a limited case fold is reported instead of hidden', () {
    // Unicode full folding expands the sharp s to "ss", which changes
    // length. A host can supply that fold; the editor must then say the
    // search was not the case-insensitive one the user asked for.
    String fullFold(String value) =>
        value.replaceAll('\u00df', 'ss').replaceAll('\u1e9e', 'ss');
    final editor = EditorController(
      displayPath: 'notes.txt',
      initialText: 'Die Stra\u00dfe ist breit',
      caseFolder: fullFold,
    );
    addTearDown(editor.dispose);
    editor.openSearch();
    editor.search.text = 'STRASSE';
    expect(editor.caseFoldingLimited, isTrue);
    expect(editor.matches, isEmpty);

    // The default fold preserves length, so nothing is reported.
    final exact = EditorController(
      displayPath: 'notes.txt',
      initialText: 'Die Stra\u00dfe ist breit',
    );
    addTearDown(exact.dispose);
    exact.openSearch();
    exact.search.text = 'STRASSE';
    expect(exact.caseFoldingLimited, isFalse);

    // Closing the find bar clears the report.
    final closed = EditorController(
      displayPath: 'notes.txt',
      initialText: 'x',
      caseFolder: fullFold,
    );
    addTearDown(closed.dispose);
    closed.openSearch();
    closed.search.text = 'strasse';
    closed.closeSearch();
    expect(closed.caseFoldingLimited, isFalse);
>>>>>>> origin/fix/case-insensitive-search-reporting
  });
}
