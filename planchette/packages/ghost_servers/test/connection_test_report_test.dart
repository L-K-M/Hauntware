// Moved from Séance app/seance_app/test/connection_test_report_test.dart
// with the report (docs/design/ghost-servers-part1.md, section 6, PR 5);
// Séance keeps its copy as the proof that its wrapper reads the same.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart';

/// The report is what a user reads when a server will not connect, so it has
/// to carry the reason, the caveats, and the transcript — not just a colour.
void main() {
  Future<void> pump(WidgetTester tester, GhostTestReport report) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: GhostConnectionTestReport(
                report: report,
                monoStyle: const TextStyle(fontFamily: 'monospace'),
              ),
            ),
          ),
        ),
      );

  testWidgets('a failure shows the reason, not only that it failed', (
    tester,
  ) async {
    await pump(
      tester,
      const GhostTestReport(
        ok: false,
        summary: 'Public key rejected by prod.example.com.',
        log: 'Auth method: public key\nrejected',
      ),
    );

    expect(
      find.text('Public key rejected by prod.example.com.'),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
  });

  testWidgets('the outcome is spoken, not only coloured', (tester) async {
    // Success and failure differ by hue, which is the one difference some
    // readers do not get.
    await pump(
      tester,
      const GhostTestReport(ok: true, summary: 'Authenticated.', log: ''),
    );
    expect(
      tester
          .widget<Icon>(find.byIcon(Icons.check_circle_outline))
          .semanticLabel,
      'Connection test succeeded',
    );

    await pump(
      tester,
      const GhostTestReport(ok: false, summary: 'Refused.', log: ''),
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.error_outline)).semanticLabel,
      'Connection test failed',
    );
  });

  testWidgets('notes qualify a success the summary would overstate', (
    tester,
  ) async {
    await pump(
      tester,
      const GhostTestReport(
        ok: true,
        summary: 'Authenticated as deploy@prod:22 (public key).',
        notes: ['Séance does not execute the jump host yet.'],
        log: '',
      ),
    );
    expect(
      find.text('Séance does not execute the jump host yet.'),
      findsOneWidget,
    );
  });

  testWidgets('notes qualify a failure the summary understates', (
    tester,
  ) async {
    // The notes are what carry the remediation, and a failure is when the
    // user needs them most. Rendered outside any `ok` branch today; this is
    // what keeps a future one from gating them on success.
    await pump(
      tester,
      const GhostTestReport(
        ok: false,
        summary: 'Connection refused.',
        notes: ['A firewall may be blocking port 22.'],
        log: '',
      ),
    );

    expect(find.text('A firewall may be blocking port 22.'), findsOneWidget);
  });

  testWidgets('the transcript is there but folded away', (tester) async {
    await pump(
      tester,
      const GhostTestReport(
        ok: false,
        summary: 'Could not reach prod.example.com:22.',
        log: 'Auth method: password\nConnection refused',
      ),
    );

    // Folded: the summary is the answer, the transcript is the evidence.
    expect(find.text('Connection log'), findsOneWidget);
    expect(find.textContaining('Connection refused'), findsNothing);

    await tester.tap(find.text('Connection log'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Connection refused'), findsOneWidget);
  });

  testWidgets('an empty transcript says so rather than showing a blank box', (
    tester,
  ) async {
    await pump(
      tester,
      const GhostTestReport(ok: false, summary: 'Refused.', log: ''),
    );
    await tester.tap(find.text('Connection log'));
    await tester.pumpAndSettle();
    expect(find.text('(no log captured)'), findsOneWidget);
    // Nothing to copy, so the button says so by being unavailable.
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Copy'))
          .onPressed,
      isNull,
    );
  });
}
