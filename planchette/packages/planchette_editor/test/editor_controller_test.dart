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
  test('opening search with a selection queries matches once', () {
    final editor = EditorController(
      displayPath: 'test',
      initialText: 'cat dog cat',
    );
    addTearDown(editor.dispose);
    editor.text.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    var notifications = 0;
    editor.addListener(() => notifications++);
    editor.openSearch();
    // The prefill assignment must not fire a first whole-document scan on
    // top of the explicit match update — one notification, two matches.
    expect(notifications, 1);
    expect(editor.search.text, 'cat');
    expect(editor.matches.length, 2);
  });

  test('re-opening search with a new selection also queries once', () {
    final editor = EditorController(
      displayPath: 'test',
      initialText: 'cat dog cat',
    );
    addTearDown(editor.dispose);
    editor.openSearch();
    editor.text.selection = const TextSelection(
      baseOffset: 8,
      extentOffset: 11,
    );
    var notifications = 0;
    editor.addListener(() => notifications++);
    editor.openSearch();
    // The prefill assignment goes through the live query listener on
    // re-entry — the guard keeps the explicit update the single scan.
    expect(notifications, 1);
    expect(editor.search.text, 'cat');
    expect(editor.matches.length, 2);
  });
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
  test('Find Next reaches matches beyond the highlight cap', () {
    final occurrences = searchMatchLimit + 3;
    final editor = EditorController(
      displayPath: 'log.txt',
      initialText: List.filled(occurrences, 'hit').join('\n'),
    );
    addTearDown(editor.dispose);
    editor.openSearch();
    editor.search.text = 'hit';
    expect(editor.matches.length, searchMatchLimit);

    // The first page is already selected; step to the end of the document.
    for (var i = 1; i < occurrences; i++) {
      editor.nextMatch();
    }
    final last = editor.matches.last;
    expect(
      editor.text.selection,
      TextSelection(baseOffset: last.start, extentOffset: last.end),
    );
    expect(editor.matches.first.start, greaterThan(0));

    // One more step wraps back to the first occurrence in the document.
    editor.nextMatch();
    expect(editor.text.selection.baseOffset, 0);
  });

  test('Find Previous walks back through the whole document', () {
    final occurrences = searchMatchLimit + 3;
    final editor = EditorController(
      displayPath: 'log.txt',
      initialText: List.filled(occurrences, 'hit').join('\n'),
    );
    addTearDown(editor.dispose);
    editor.openSearch();
    editor.search.text = 'hit';

    // From the first match, stepping back lands on the last occurrence.
    editor.previousMatch();
    final last = editor.matches.last;
    expect(
      editor.text.selection,
      TextSelection(baseOffset: last.start, extentOffset: last.end),
    );

    for (var i = 1; i < occurrences; i++) {
      editor.previousMatch();
    }
    expect(editor.text.selection.baseOffset, 0);
  });

  test('a window smaller than the cap wraps in both directions', () {
    final editor = EditorController(
      displayPath: 'test',
      initialText: 'cat CAT cat',
    );
    addTearDown(editor.dispose);
    editor.openSearch();
    editor.search.text = 'cat';

    for (var i = 0; i < 3; i++) {
      editor.nextMatch();
    }
    expect(editor.text.selection.baseOffset, 0);
    editor.previousMatch();
    expect(editor.text.selection.baseOffset, 8);
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
  test('toggle comment marks then lifts a single caret line', () {
    final editor = EditorController(
      displayPath: 'x.py',
      initialText: 'a = 1\nb = 2\n',
    );
    addTearDown(editor.dispose);
    editor.text.selection = const TextSelection.collapsed(offset: 2);
    editor.toggleComment();
    expect(editor.text.text, '# a = 1\nb = 2\n');
    expect(editor.text.selection.extentOffset, 4);
    editor.toggleComment();
    expect(editor.text.text, 'a = 1\nb = 2\n');
    expect(editor.text.selection.extentOffset, 2);
  });
  test('toggle comment preserves indent and skips blank lines', () {
    final editor = EditorController(
      displayPath: 'x.dart',
      initialText: 'void f() {\n  int a;\n\n  int b;\n}',
    );
    addTearDown(editor.dispose);
    editor.text.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 31,
    );
    editor.toggleComment();
    expect(editor.text.text, '// void f() {\n  // int a;\n\n  // int b;\n// }');
  });
  test('toggle comment skips whitespace-only lines like blank ones', () {
    final editor = EditorController(
      displayPath: 'x.py',
      initialText: 'one\n   \ntwo',
    );
    addTearDown(editor.dispose);
    editor.text.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 11,
    );
    editor.toggleComment();
    expect(editor.text.text, '# one\n   \n# two');
  });
  test('toggle comment keeps a backward selection pointing at its anchor', () {
    final editor = EditorController(
      displayPath: 'x.py',
      initialText: 'one\ntwo',
    );
    addTearDown(editor.dispose);
    editor.text.selection = const TextSelection(baseOffset: 7, extentOffset: 0);
    editor.toggleComment();
    expect(editor.text.text, '# one\n# two');
    expect(
      editor.text.selection,
      const TextSelection(baseOffset: 11, extentOffset: 0),
    );
  });
  test('toggle comment lifts marker and one space per line', () {
    final editor = EditorController(
      displayPath: 'x.py',
      initialText: '# one\n  # two\n#three\n',
    );
    addTearDown(editor.dispose);
    editor.text.selection = const TextSelection(
      baseOffset: 0,
      extentOffset: 21,
    );
    editor.toggleComment();
    expect(editor.text.text, 'one\n  two\nthree\n');
  });
  test('toggle comment is a no-op without a line comment marker', () {
    final editor = EditorController(
      displayPath: 'x.json',
      initialText: '{"a": 1}',
    );
    addTearDown(editor.dispose);
    editor.text.selection = const TextSelection.collapsed(offset: 1);
    editor.toggleComment();
    expect(editor.text.text, '{"a": 1}');
  });
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
    // `same`, not `equals`: the controller's per-keystroke guard compares
    // languages with `identical`, so the canonicality of these instances is
    // the thing under test, not their value.
    expect(editor.text.language, same(SyntaxLanguages.python));
  });

  test('language detection returns canonical instances', () {
    // The guard in EditorController._applyLanguage is `identical`, so a
    // recogniser that started building a fresh SyntaxLanguage per call would
    // silently turn the guard into an always-assign. Nothing enforces
    // canonicality, so pin it here, where a change to it would be visible.
    const paths = [
      'a.py',
      'a.js',
      'a.dart',
      // The C family is one member behind several extensions, so exercise a
      // couple: a branch that rebuilt only one of them would otherwise hide.
      'a.c',
      'a.h',
      'a.go',
      'a.rs',
      'a.cpp',
      'a.sh',
      'a.rb',
      'a.lua',
      'a.pl',
      'a.sql',
      'a.xml',
      'a.yaml',
      'a.ini',
      'a.json',
      'a.md',
      'a.css',
      '.env',
      'Dockerfile.dev',
      'Makefile',
      'a.diff',
      'a.patch',
    ];
    // Intended to be every member of `SyntaxLanguages`; this test cannot
    // enforce that, because the class exposes no list of its instances. When
    // you add a member to `SyntaxLanguages`, add it here and a path above.
    // A List, not a Set: a future `==`/`hashCode` on SyntaxLanguage would make
    // a set literal collapse equal members and quietly shrink the pool this
    // test exists to check against.
    final canonical = [
      SyntaxLanguages.dotenv,
      SyntaxLanguages.shell,
      SyntaxLanguages.python,
      SyntaxLanguages.javascript,
      SyntaxLanguages.dart,
      SyntaxLanguages.json,
      SyntaxLanguages.yaml,
      SyntaxLanguages.ini,
      SyntaxLanguages.dockerfile,
      SyntaxLanguages.sql,
      SyntaxLanguages.xml,
      SyntaxLanguages.markdown,
      SyntaxLanguages.css,
      SyntaxLanguages.ruby,
      SyntaxLanguages.perl,
      SyntaxLanguages.lua,
      SyntaxLanguages.cFamily,
      SyntaxLanguages.rust,
      SyntaxLanguages.go,
      SyntaxLanguages.diff,
    ];
    for (final path in paths) {
      final language = syntaxLanguageFor(path);
      expect(language, isNotNull, reason: path);
      expect(canonical, contains(same(language)), reason: path);
      // And the same answer twice, so a cache-free rebuild cannot pass.
      expect(syntaxLanguageFor(path), same(language), reason: path);
    }
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
  });

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
  });

  // Ported from #67, which counted the selection the way the line commands
  // pick their lines.
  group('selectionStats', () {
    ({int characters, int lines}) stats(String text, int base, int extent) {
      final editor = EditorController(
        displayPath: 'notes.txt',
        initialText: text,
      );
      addTearDown(editor.dispose);
      editor.text.selection = TextSelection(
        baseOffset: base,
        extentOffset: extent,
      );
      return editor.selectionStats;
    }

    test('counts code units and touched lines in either direction', () {
      expect(stats('one\ntwo\nthree', 2, 10), (characters: 8, lines: 3));
      expect(stats('one\ntwo\nthree', 10, 2), (characters: 8, lines: 3));
      expect(stats('one\ntwo\nthree', 0, 13), (characters: 13, lines: 3));
    });

    test('a selection ending at a line start does not count that line', () {
      expect(stats('one\ntwo\nthree', 0, 4), (characters: 4, lines: 1));
      expect(stats('one\ntwo\n', 0, 8), (characters: 8, lines: 2));
      expect(stats('one\n\ntwo', 3, 5), (characters: 2, lines: 2));
    });

    test('a collapsed selection counts nothing', () {
      expect(stats('one', 1, 1), (characters: 0, lines: 0));
    });
  });

  // Review fixes for #85's paging, and the test its force-push lost.
  group('paging past the highlight cap', () {
    EditorController hits(int count, {CaseFolder? fold, String word = 'hit'}) {
      final editor = EditorController(
        displayPath: 'log.txt',
        initialText: List.filled(count, word).join('\n'),
        caseFolder: fold,
      );
      addTearDown(editor.dispose);
      editor.openSearch(replace: true);
      editor.search.text = word;
      return editor;
    }

    /// The document-wide number of the active match, and the count so far.
    (int, int, bool) counter(EditorController editor) => (
      editor.matchOffset + editor.activeMatch + 1,
      editor.matchOffset + editor.matches.length,
      editor.matchesMayContinue,
    );

    test('review fix: an edit keeps a page reached backward', () {
      // Wrapping backward shows the last page, which starts mid-document.
      final editor = hits(searchMatchLimit + 3)..previousMatch();
      final before = editor.matches[editor.activeMatch];
      expect(counter(editor).$1, searchMatchLimit + 3);
      editor.text.value = TextEditingValue(
        text: '${editor.text.text}\nx',
        selection: editor.text.selection,
      );
      expect(editor.matches[editor.activeMatch], before);
      expect(counter(editor).$1, searchMatchLimit + 3);
    });

    test('review fix: typing above a later page keeps the active match', () {
      final editor = hits(searchMatchLimit + 5);
      for (var i = 0; i < searchMatchLimit + 1; i++) {
        editor.nextMatch();
      }
      final before = editor.matches[editor.activeMatch];
      editor.text.value = TextEditingValue(
        text: 'note: ${editor.text.text}',
        selection: const TextSelection.collapsed(offset: 6),
      );
      expect(editor.matches[editor.activeMatch].start, before.start + 6);
      expect(counter(editor).$1, searchMatchLimit + 2);
    });

    test('review fix: Replace after an edit replaces the active match', () {
      final editor = hits(searchMatchLimit + 3)..previousMatch();
      editor.replacement.text = 'HIT';
      editor.text.value = TextEditingValue(
        text: '${editor.text.text}\n',
        selection: editor.text.selection,
      );
      editor.replaceCurrent();
      final lines = editor.text.text.split('\n');
      expect(lines[searchMatchLimit + 2], 'HIT');
      expect(lines.where((line) => line == 'HIT'), hasLength(1));
    });

    test('paging back and forth returns to the same match', () {
      final editor = hits(searchMatchLimit + 2);
      for (var i = 0; i < searchMatchLimit + 1; i++) {
        editor.nextMatch();
      }
      final last = editor.text.selection;
      editor
        ..previousMatch()
        ..previousMatch()
        ..nextMatch()
        ..nextMatch();
      expect(editor.text.selection, last);
    });

    test('later pages use the host fold too', () {
      // Final sigma folded like sigma, which keeps the length.
      final editor = hits(
        searchMatchLimit + 3,
        fold: (value) => value.toLowerCase().replaceAll('ς', 'σ'),
        word: 'σοφος',
      );
      editor.search.text = 'ΣΟΦΟΣ';
      expect(editor.matches, hasLength(searchMatchLimit));
      for (var i = 0; i < searchMatchLimit; i++) {
        editor.nextMatch();
      }
      expect(editor.matches, hasLength(3));
      expect(editor.activeMatch, 0);
    });

    test('the counter numbers matches across the whole document', () {
      final editor = hits(searchMatchLimit + 3);
      expect(counter(editor), (1, searchMatchLimit, true));
      for (var i = 0; i < searchMatchLimit; i++) {
        editor.nextMatch();
      }
      expect(counter(editor), (
        searchMatchLimit + 1,
        searchMatchLimit + 3,
        false,
      ));
      editor.previousMatch();
      expect(counter(editor), (searchMatchLimit, searchMatchLimit, true));

      // Back from the first match wraps to the last page, which ends the
      // document, so its total is exact.
      for (var i = 0; i < searchMatchLimit - 1; i++) {
        editor.previousMatch();
      }
      expect(counter(editor), (1, searchMatchLimit, true));
      editor.previousMatch();
      expect(counter(editor), (
        searchMatchLimit + 3,
        searchMatchLimit + 3,
        false,
      ));
    });

    test('Replace on a later page moves on to the next match', () {
      final editor = hits(searchMatchLimit + 5)..replacement.text = 'HOT';
      for (var i = 0; i < searchMatchLimit + 1; i++) {
        editor.nextMatch();
      }
      final replaced = editor.text.selection.start;
      expect(replaced, (searchMatchLimit + 1) * 4);
      editor.replaceCurrent();
      final active = editor.matches[editor.activeMatch];
      expect(active.start, replaced + 4);
      expect(counter(editor).$1, searchMatchLimit + 2);
    });

    test('typing on a later page keeps the active match', () {
      final editor = hits(searchMatchLimit + 5);
      for (var i = 0; i < searchMatchLimit + 1; i++) {
        editor.nextMatch();
      }
      final before = editor.matches[editor.activeMatch];
      final number = counter(editor).$1;
      editor.text.value = TextEditingValue(
        text: '${editor.text.text}\nx',
        selection: editor.text.selection,
      );
      expect(editor.matches[editor.activeMatch], before);
      expect(counter(editor).$1, number);
    });
  });

  // From #12.
  test('whole word search filters partial hits and replace all', () {
    final editor = EditorController(
      displayPath: 'test',
      initialText: 'cat concat cat',
    );
    addTearDown(editor.dispose);
    editor.openSearch(replace: true);
    editor.search.text = 'cat';
    expect(editor.matches.length, 3);
    final revealed = editor.revealRequest;
    editor.toggleWholeWord();
    expect(editor.wholeWord, isTrue);
    expect(editor.revealRequest, revealed + 1);
    editor.toggleCaseSensitive();
    expect(editor.revealRequest, revealed + 2);
    expect(editor.matches.length, 2);
    editor.replacement.text = 'dog';
    editor.replaceAll();
    expect(editor.text.text, 'dog concat dog');
  });

  test('whole-word paging never offers a partial word', () {
    final editor = EditorController(
      displayPath: 'log.txt',
      initialText: List.filled(searchMatchLimit + 3, 'cat concat').join('\n'),
    );
    addTearDown(editor.dispose);
    editor
      ..openSearch()
      ..search.text = 'cat'
      ..toggleWholeWord();
    // From the first match, Find Previous wraps to the last page.
    editor.previousMatch();
    expect(editor.matches, hasLength(searchMatchLimit));
    for (final match in editor.matches) {
      expect(
        match.start == 0 || editor.text.text[match.start - 1] == '\n',
        isTrue,
        reason: 'partial word at ${match.start}',
      );
    }
  });

  // From #21: Find Next after the find bar closed did nothing.
  group('Find Next with the bar closed', () {
    EditorController closedOn(String text, String query) {
      final editor = EditorController(displayPath: 'a.txt', initialText: text);
      addTearDown(editor.dispose);
      editor
        ..openSearch()
        ..search.text = query
        ..closeSearch();
      return editor;
    }

    test('goes on from the match it left selected', () {
      final editor = closedOn('cat dog cat dog cat', 'cat')
        ..text.selection = const TextSelection(baseOffset: 8, extentOffset: 11);
      editor.nextMatch();
      expect(editor.searchOpen, isTrue);
      expect(editor.search.text, 'cat');
      expect(
        editor.text.selection,
        const TextSelection(baseOffset: 16, extentOffset: 19),
      );
    });

    test('takes the nearest match on either side of a moved caret', () {
      final editor = closedOn('cat dog cat dog cat', 'cat')
        ..text.selection = const TextSelection.collapsed(offset: 5);
      editor.nextMatch();
      expect(
        editor.text.selection,
        const TextSelection(baseOffset: 8, extentOffset: 11),
      );
      editor
        ..closeSearch()
        ..text.selection = const TextSelection.collapsed(offset: 5)
        ..previousMatch();
      expect(
        editor.text.selection,
        const TextSelection(baseOffset: 0, extentOffset: 3),
      );
    });

    test('keeps the remembered query rather than the selection', () {
      final editor = closedOn('Cat cat', 'cat')
        ..text.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
      editor.nextMatch();
      expect(editor.search.text, 'cat');
      expect(
        editor.text.selection,
        const TextSelection(baseOffset: 4, extentOffset: 7),
      );
    });

    test('with nothing remembered, opens the find field', () {
      final editor = closedOn('cat', '');
      editor.nextMatch();
      expect(editor.searchOpen, isTrue);
      expect(editor.search.text, isEmpty);
    });
  });
}
