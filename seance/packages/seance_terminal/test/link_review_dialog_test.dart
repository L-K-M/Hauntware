import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_terminal/seance_terminal.dart';

// The shared review a terminal hyperlink whose text hides its target shows
// before it opens (TerminalView.onHiddenLinkTap), in Séance's English and
// in the strings an app passes.
void main() {
  final target = Uri.parse('https://login.evil.test/auth?code=1');

  Future<Future<bool>> open(
    WidgetTester tester, {
    Uri? uri,
    TerminalLinkReviewStrings strings = const TerminalLinkReviewStrings(),
  }) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SizedBox.expand())),
    );
    final answer = showTerminalLinkReview(
      tester.element(find.byType(SizedBox)),
      uri ?? target,
      strings: strings,
    );
    await tester.pumpAndSettle();
    return answer;
  }

  testWidgets('shows the host and the full URL, and answers each button', (
    tester,
  ) async {
    for (final (button, choice) in [('Open', true), ('Cancel', false)]) {
      final answer = await open(tester);
      expect(find.text('Open this link?'), findsOneWidget);
      expect(find.text('login.evil.test'), findsOneWidget);
      expect(find.text('https://login.evil.test/auth?code=1'), findsOneWidget);
      await tester.tap(find.text(button));
      await tester.pumpAndSettle();
      expect(await answer, choice, reason: button);
    }
  });

  testWidgets('a dismissed review opens nothing', (tester) async {
    final answer = await open(tester);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();

    expect(find.byType(TerminalLinkReviewDialog), findsNothing);
    expect(await answer, isFalse);
  });

  testWidgets('a hidden character in the target shows as an escape', (
    tester,
  ) async {
    await open(tester, uri: Uri.parse('https://a.test/\u202Egpj.exe'));

    expect(find.textContaining('\u202E'), findsNothing);
    expect(find.text('https://a.test/%E2%80%AEgpj.exe'), findsOneWidget);
  });

  testWidgets('uses the strings the app passes', (tester) async {
    await open(
      tester,
      strings: const TerminalLinkReviewStrings(
        title: 'T',
        explanation: 'E',
        open: 'O',
        cancel: 'C',
      ),
    );

    for (final text in ['T', 'E', 'O', 'C']) {
      expect(find.text(text), findsOneWidget, reason: text);
    }
  });
}
