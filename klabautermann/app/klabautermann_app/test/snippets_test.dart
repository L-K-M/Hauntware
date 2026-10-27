// AUT-01 (03 §7.21): Séance's synced snippets, listed and searched, their
// placeholders filled, and each run as an action whose preview shows the
// filled command; the header offers them only where actions are allowed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/controllers/snippets_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_app/ui/snippets.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _restart = Snippet(
  id: 's-1',
  title: 'Restart a unit',
  body: 'systemctl restart {{unit}} && journalctl -u {{unit}} -n {{lines}}',
  createdAt: 1,
  updatedAt: 1,
);
const _disk = Snippet(
  id: 's-2',
  title: 'Disk',
  body: 'df -h',
  createdAt: 1,
  updatedAt: 1,
);
const _untitled = Snippet(
  id: 's-3',
  title: '',
  body: 'uptime',
  createdAt: 1,
  updatedAt: 1,
);

const _allowed = SafetyPolicy(
  servers: {'srv-1': ServerSafety(management: true)},
);

void main() {
  late FakeEngineClient engine;
  late SnippetsController snippets;
  late OperationsController operations;

  setUp(() {
    engine = FakeEngineClient();
    snippets = SnippetsController(engine);
    operations = OperationsController(engine);
    addTearDown(() async {
      snippets.dispose();
      operations.dispose();
      await engine.close();
    });
  });

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    SafetyPolicy policy = _allowed,
  }) async {
    final safety = SafetyController(initial: policy, apply: (_) {});
    addTearDown(safety.dispose);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SafetyScope(
          safety: safety,
          child: OperationsScope(
            operations: operations,
            child: SnippetsScope(snippets: snippets, child: child),
          ),
        ),
      ),
    );
  }

  Widget page() =>
      SnippetsPage(snippets: snippets, serverId: 'srv-1', serverName: 'web-1');

  RunSnippet planned() =>
      engine.sentOfType<PlanAction>().cast<PlanAction>().single.intent
          as RunSnippet;

  test('the controller keeps what the engine last sent', () async {
    final heard = <List<Snippet>>[];
    snippets.addListener(() => heard.add(snippets.snippets));

    engine.emit(const SnippetsChanged([_disk, _restart]));
    await pumpEventQueue();

    expect(heard.single.map((s) => s.id), ['s-2', 's-1']);
  });

  testWidgets('an account without snippets says where they come from', (
    tester,
  ) async {
    await pump(tester, page());

    expect(find.textContaining('save in Séance'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('the search keeps the snippets whose title or command holds '
      'every term', (tester) async {
    engine.emit(const SnippetsChanged([_disk, _restart, _untitled]));
    await pump(tester, page());
    await tester.pump();

    expect(find.text('Snippets on web-1'), findsOneWidget);
    expect(find.text('Untitled snippet'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'JOURNALCTL unit');
    await tester.pump();
    expect(find.text('Restart a unit'), findsOneWidget);
    expect(find.text('Disk'), findsNothing);

    await tester.enterText(find.byType(TextField), 'nothing-like-it');
    await tester.pump();
    expect(find.text('No snippet matches your search.'), findsOneWidget);
  });

  testWidgets('a snippet without placeholders goes straight to the '
      'preview as typed', (tester) async {
    engine.emit(const SnippetsChanged([_disk]));
    await pump(tester, page());
    await tester.pump();

    await tester.tap(find.text('Disk'));
    await tester.pump();

    final intent = planned();
    expect(intent.serverId, 'srv-1');
    expect(intent.title, 'Disk');
    expect(intent.command, 'df -h');
  });

  testWidgets('placeholders are filled, each name once, and the preview '
      'waits until every value is in', (tester) async {
    engine.emit(const SnippetsChanged([_restart]));
    await pump(tester, page());
    await tester.pump();

    await tester.tap(find.text('Restart a unit'));
    await tester.pumpAndSettle();

    expect(find.text('Fill in Restart a unit'), findsOneWidget);
    final fields = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(fields, findsNWidgets(2));
    final preview = find.widgetWithText(FilledButton, 'Preview');
    expect(tester.widget<FilledButton>(preview).onPressed, isNull);
    expect(find.text('Fill in every value to continue.'), findsOneWidget);

    await tester.enterText(fields.at(0), 'nginx.service');
    await tester.pump();
    expect(tester.widget<FilledButton>(preview).onPressed, isNull);
    await tester.enterText(fields.at(1), '50');
    await tester.pump();
    expect(
      find.text(
        'systemctl restart nginx.service && '
        'journalctl -u nginx.service -n 50',
      ),
      findsOneWidget,
    );

    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(
      planned().command,
      'systemctl restart nginx.service && journalctl -u nginx.service -n 50',
    );
  });

  testWidgets('cancelling the placeholders plans nothing', (tester) async {
    engine.emit(const SnippetsChanged([_restart]));
    await pump(tester, page());
    await tester.pump();

    await tester.tap(find.text('Restart a unit'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(engine.sentOfType<PlanAction>(), isEmpty);
  });

  testWidgets('the header button shows only where actions are allowed', (
    tester,
  ) async {
    const button = SnippetsButton(serverId: 'srv-1', serverName: 'web-1');
    await pump(tester, const Scaffold(body: button));
    expect(find.byTooltip('Snippets'), findsOneWidget);

    await pump(
      tester,
      const Scaffold(body: button),
      policy: const SafetyPolicy(
        servers: {'srv-1': ServerSafety(management: true, readOnly: true)},
      ),
    );
    expect(find.byTooltip('Snippets'), findsNothing);
  });
}
