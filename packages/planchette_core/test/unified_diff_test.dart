import 'package:planchette_core/planchette_core.dart';
import 'package:test/test.dart';

void main() {
  group('unifiedDiff', () {
    test('equal texts are identical, without labels', () {
      final result = unifiedDiff('one\ntwo\n', 'one\ntwo\n');
      expect(result.status, UnifiedDiffStatus.identical);
      expect(result.text, isEmpty);
    });

    test('empty texts are identical', () {
      final result = unifiedDiff('', '');
      expect(result.status, UnifiedDiffStatus.identical);
    });

    test('a changed line becomes one hunk with context', () {
      final result = unifiedDiff(
        'one\ntwo\nthree\nfour\nfive\n',
        'one\ntwo\nTHREE\nfour\nfive\n',
        oldLabel: 'a.txt (on disk)',
        newLabel: 'a.txt (in the editor)',
      );
      expect(result.status, UnifiedDiffStatus.differs);
      expect(result.text, '''
--- a.txt (on disk)
+++ a.txt (in the editor)
@@ -1,5 +1,5 @@
 one
 two
-three
+THREE
 four
 five
''');
    });

    test('an inserted line reports both ranges', () {
      final result = unifiedDiff('a\nb\n', 'a\nX\nb\n');
      expect(result.status, UnifiedDiffStatus.differs);
      expect(result.text, '''
--- old file
+++ new file
@@ -1,2 +1,3 @@
 a
+X
 b
''');
    });

    test('a deleted line reports both ranges', () {
      final result = unifiedDiff('a\nb\nc\n', 'a\nc\n');
      expect(result.text, '''
--- old file
+++ new file
@@ -1,3 +1,2 @@
 a
-b
 c
''');
    });

    test('an insertion into an empty text is 0,0 on the old side', () {
      final result = unifiedDiff('', 'x\ny\n');
      expect(result.text, '''
--- old file
+++ new file
@@ -0,0 +1,2 @@
+x
+y
''');
    });

    test('a deletion to an empty text is 0,0 on the new side', () {
      final result = unifiedDiff('x\ny\n', '');
      expect(result.text, '''
--- old file
+++ new file
@@ -1,2 +0,0 @@
-x
-y
''');
    });

    test('distant changes split into hunks that share no context', () {
      final oldText = [for (var i = 1; i <= 40; i++) 'l$i'].join('\n');
      final newText = [
        for (var i = 1; i <= 40; i++)
          switch (i) {
            5 => 'FIVE',
            _ => 'l$i',
          },
      ].join('\n');
      final result = unifiedDiff(oldText, '$newText\n');
      expect(result.status, UnifiedDiffStatus.differs);
      // Change 1 at line 5, change 2 the missing final newline at line 40;
      // more than twice the context separates them.
      expect(
        result.text,
        contains('@@ -2,7 +2,7 @@\n l2\n l3\n l4\n-l5\n+FIVE\n'),
      );
      expect(RegExp('@@ .* @@').allMatches(result.text).length, 2);
    });

    test('changes separated by twice the context share a hunk', () {
      // Six equal lines between two changes is exactly 2 * context, so the
      // context windows touch and the hunks merge.
      final oldText = List.generate(10, (i) => 'l$i').join('\n');
      final newText = List.generate(
        10,
        (i) => i == 1 || i == 8 ? 'X' : 'l$i',
      ).join('\n');
      final result = unifiedDiff('$oldText\n', '$newText\n');
      expect(RegExp('@@ .* @@').allMatches(result.text).length, 1);
    });

    test('a missing final newline is marked', () {
      final result = unifiedDiff('a\nb\n', 'a\nb');
      expect(result.text, '''
--- old file
+++ new file
@@ -1,2 +1,2 @@
 a
-b
+b
\\ No newline at end of file
''');
    });

    test('a context line missing its newline is marked once', () {
      final result = unifiedDiff('a\nz', 'b\nz');
      expect(result.text, '''
--- old file
+++ new file
@@ -1,2 +1,2 @@
-a
+b
 z
\\ No newline at end of file
''');
    });

    test('carriage returns stay part of the line content', () {
      final result = unifiedDiff('a\r\nb\n', 'a\r\nB\n');
      expect(result.text, '''
--- old file
+++ new file
@@ -1,2 +1,2 @@
 a\r
-b
+B
''');
    });

    test('a lone change in a large file is a small hunk', () {
      final base = [for (var i = 0; i < 100000; i++) 'line $i'].join('\n');
      final edited = base.replaceFirst('line 50000', 'line 50000 edited');
      final result = unifiedDiff('$base\n', '$edited\n');
      expect(result.status, UnifiedDiffStatus.differs);
      expect(result.text, contains('-line 50000\n+line 50000 edited\n'));
      // One small hunk, not a whole-file replacement.
      expect(result.text.length, lessThan(400));
    });

    test('middles beyond the line limit fall back to one replace hunk', () {
      // The texts differ on every line, so no prefix or suffix is trimmed
      // and the combined middle exceeds the minimal-diff line limit.
      final oldText = List.generate(1500, (i) => 'a$i').join('\n');
      final newText = List.generate(1500, (i) => 'b$i').join('\n');
      final result = unifiedDiff('$oldText\n', '$newText\n');
      expect(result.status, UnifiedDiffStatus.differs);
      expect(RegExp('@@ .* @@').allMatches(result.text).length, 1);
      expect(result.text, contains('@@ -1,1500 +1,1500 @@'));
      // All old lines removed, then all new lines added: no interleaving.
      expect(
        result.text.indexOf('+b0'),
        greaterThan(result.text.indexOf('-a1499')),
      );
    });

    test('an output limit refusal never claims the texts match', () {
      final oldText = List.generate(1000, (i) => 'x$i'.padRight(60, 'x'));
      final newText = List.generate(1000, (i) => 'y$i'.padRight(60, 'y'));
      final result = unifiedDiff(
        '${oldText.join('\n')}\n',
        '${newText.join('\n')}\n',
        outputLimit: 1000,
      );
      expect(result.status, UnifiedDiffStatus.tooLarge);
      expect(result.text, isEmpty);
    });

    test('scattered edits inside a middle become minimal hunks', () {
      final oldLines = [
        for (var i = 0; i < 20; i++)
          switch (i) {
            3 => 'x',
            _ => 'l$i',
          },
      ];
      final newLines = [
        for (var i = 0; i < 20; i++)
          switch (i) {
            3 => 'y',
            _ => 'l$i',
          },
      ];
      newLines.insert(12, 'inserted');
      final result = unifiedDiff(
        '${oldLines.join('\n')}\n',
        '${newLines.join('\n')}\n',
      );
      expect(result.status, UnifiedDiffStatus.differs);
      expect(result.text, '''
--- old file
+++ new file
@@ -1,7 +1,7 @@
 l0
 l1
 l2
-x
+y
 l4
 l5
 l6
@@ -10,6 +10,7 @@
 l9
 l10
 l11
+inserted
 l12
 l13
 l14
''');
    });
  });

  group('boundedUnifiedDiff', () {
    test('computes in the worker and reports the diff', () async {
      final result = await boundedUnifiedDiff(
        'a\nb\n',
        'a\nB\n',
        oldLabel: 'disk',
        newLabel: 'editor',
      );
      expect(result.status, UnifiedDiffStatus.differs);
      expect(result.text, contains('-b\n+B\n'));
      expect(result.text.startsWith('--- disk\n+++ editor\n'), isTrue);
    });

    test('identical texts stay identical through the worker', () async {
      final result = await boundedUnifiedDiff('same\n', 'same\n');
      expect(result.status, UnifiedDiffStatus.identical);
    });

    test('an exhausted budget reports a timeout, never equality', () async {
      final result = await boundedUnifiedDiff(
        'a\n',
        'b\n',
        budget: Duration.zero,
      );
      expect(result.status, UnifiedDiffStatus.timedOut);
    });
  }, timeout: const Timeout(Duration(seconds: 20)));
}
