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
}) async {
  tester.view.physicalSize = Size(width, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final logs = LogViewController();
  final search = LogSearch(logs);
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
}
