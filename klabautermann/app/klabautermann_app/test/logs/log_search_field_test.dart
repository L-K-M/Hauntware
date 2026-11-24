import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/logs/log_search.dart';
import 'package:klabautermann_app/ui/logs/log_view_controller.dart';
import 'package:klabautermann_app/ui/logs/logs_panel.dart';

Future<LogSearch> _pump(
  WidgetTester tester, {
  required ValueChanged<String>? onSearchServer,
  double width = 320,
  List<String> lines = const [],
  Duration patternLimit = const Duration(seconds: 30),
}) async {
  tester.view.physicalSize = Size(width, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final logs = LogViewController()..add(lines);
  final search = LogSearch(logs, patternLimit: patternLimit);
  addTearDown(() {
    search.dispose();
    logs.dispose();
  });
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: LogSearchField(
            search: search,
            onSearchServer: onSearchServer,
            compact: width < 600,
          ),
        ),
      ),
    ),
  );
  return search;
}

void main() {
  testWidgets('the text field keeps a usable width at 320 px', (tester) async {
    await _pump(tester, onSearchServer: (_) {});
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(TextField)).width, greaterThan(150));
  });

  testWidgets('Search on server sends what is typed, not the debounced text', (
    tester,
  ) async {
    final sent = <String>[];
    await _pump(tester, onSearchServer: sent.add, width: 800);

    await tester.enterText(find.byType(TextField), 'oom');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.travel_explore));
    await tester.pump(const Duration(seconds: 1));

    expect(sent, ['(?i)oom']);
  });

  testWidgets('Search on server stays available for a pattern PCRE2 may take', (
    tester,
  ) async {
    final sent = <String>[];
    final search = await _pump(tester, onSearchServer: sent.add, width: 800);
    search.setRegex(true);

    // Dart has no inline flags, journalctl -g (PCRE2) does.
    await tester.enterText(find.byType(TextField), '(?i)err');
    await tester.pump(const Duration(seconds: 1));
    expect(search.invalidPattern, isTrue);

    await tester.tap(find.byIcon(Icons.travel_explore));
    await tester.pump();
    expect(sent, ['(?i)(?i)err']);
  });

  testWidgets('a pattern says it is searching, then how many it found', (
    tester,
  ) async {
    final search = await _pump(
      tester,
      onSearchServer: null,
      width: 800,
      lines: ['GET /a 200', 'GET /b 502', 'none'],
    );
    search.setRegex(true);

    await tester.enterText(find.byType(TextField), r'GET \S+');
    await tester.pump(const Duration(seconds: 1));
    // The worker answers on the real event loop, which has not run yet.
    expect(search.searching, isTrue);
    expect(find.text('Searching…'), findsOneWidget);
    expect(find.text('No matches'), findsNothing);

    while (search.searching) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump();
    }
    await tester.pump();
    expect(find.text('Searching…'), findsNothing);
    expect(find.text('2 matches'), findsOneWidget);
  });

  testWidgets('a pattern that does not finish is stopped with a reason', (
    tester,
  ) async {
    final search = await _pump(
      tester,
      onSearchServer: null,
      width: 800,
      lines: ['${'word ' * 12}${'a' * 50}!'],
      patternLimit: const Duration(seconds: 2),
    );
    search.setRegex(true);

    await tester.enterText(find.byType(TextField), r'(\w+\s?)+$');
    await tester.pump(const Duration(seconds: 1));
    // Let the worker start on the row, then let the limit pass.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump(const Duration(seconds: 2));

    expect(search.tooCostly, isTrue);
    expect(
      find.text(
        'The search stopped: this pattern takes too long to match these lines',
      ),
      findsOneWidget,
    );
    expect(find.text('Searching…'), findsNothing);
    expect(find.text('No matches'), findsNothing);
  });
}
