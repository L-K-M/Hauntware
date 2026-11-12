import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_terminal/seance_terminal.dart';

// The shared review a flagged multi-line paste shows (TerminalPastePolicy's
// confirm), in Séance's English and in the strings an app passes.
void main() {
  const review = TerminalPasteReview(
    text: 'cd /tmp\nrm -rf /',
    lineCount: 2,
    findings: [
      TerminalPasteFinding(
        severity: TerminalPasteSeverity.critical,
        line: 2,
        explanation: 'deletes everything',
      ),
    ],
  );

  Future<Future<TerminalPasteChoice>> open(
    WidgetTester tester, {
    TerminalPasteReview subject = review,
    TerminalPasteReviewStrings strings = const TerminalPasteReviewStrings(),
  }) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    final answer = showTerminalPasteReview(
      tester.element(find.byType(SizedBox)),
      subject,
      strings: strings,
    );
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('names the lines and the findings, and answers each button', (
    tester,
  ) async {
    for (final (button, choice) in [
      ('Paste all', TerminalPasteChoice.pasteAll),
      ('First line only', TerminalPasteChoice.firstLineOnly),
      ('Cancel', TerminalPasteChoice.cancel),
    ]) {
      final answer = await open(tester);
      expect(find.text('Paste 2 lines?'), findsOneWidget);
      expect(find.text('Line 2: deletes everything'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(await answer, choice, reason: button);
    }
  });

  testWidgets('says when the text could not be checked', (tester) async {
    await open(
      tester,
      subject: const TerminalPasteReview(
        text: 'a\nb',
        lineCount: 1,
        findings: null,
      ),
    );
    expect(find.text('Paste 1 line?'), findsOneWidget);
    expect(find.textContaining('could not be checked'), findsOneWidget);
  });

  testWidgets('says why it asks about a clean paste', (tester) async {
    await open(
      tester,
      subject: const TerminalPasteReview(
        text: 'a\nb',
        lineCount: 2,
        findings: [],
      ),
    );
    expect(find.text('Paste 2 lines?'), findsOneWidget);
    expect(find.textContaining('runs each line as it arrives'), findsOneWidget);
    expect(find.textContaining('look dangerous'), findsNothing);
  });

  testWidgets('a dismissed review pastes nothing', (tester) async {
    final answer = await open(tester);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(await answer, TerminalPasteChoice.cancel);
  });

  testWidgets('an app passes its own strings', (tester) async {
    await open(
      tester,
      strings: TerminalPasteReviewStrings(
        title: (count) => '$count Zeilen einfügen?',
        pasteAll: 'Alle einfügen',
      ),
    );
    expect(find.text('2 Zeilen einfügen?'), findsOneWidget);
    expect(find.text('Alle einfügen'), findsOneWidget);
  });
}
