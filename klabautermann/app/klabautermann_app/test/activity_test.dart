// The Activity page (SAF-11, M4 E24): the device audit log per server,
// newest first in the sortable table, each run's redacted steps in its
// details, older pages on request, and a copy that holds only what the
// log stored, secrets already removed.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/activity_page.dart';
import 'package:klabautermann_app/ui/server_header.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

const _server = 'srv-1';
final _ended = DateTime.utc(2026, 10, 18, 12);

AuditRecord _record(
  int minutes, {
  ActionOutcome outcome = ActionOutcome.succeeded,
}) => AuditRecord(
  serverId: _server,
  action: 'UnitAction',
  targetName: 'nginx.service',
  steps: const ['env API_TOKEN=«redacted» systemctl restart nginx.service'],
  tier: ConfirmationTier.acknowledge,
  outcome: outcome,
  startedAt: _ended.subtract(Duration(minutes: minutes, seconds: 2)),
  endedAt: _ended.subtract(Duration(minutes: minutes)),
  deviceId: 'device-1',
  failure: outcome == ActionOutcome.failed ? ActionFailure.stepFailed : null,
  exitCode: outcome == ActionOutcome.failed ? 5 : null,
);

void main() {
  test('audit reads answer in order per server, and a stopped engine '
      'answers none', () async {
    final engine = FakeEngineClient();
    final operations = OperationsController(engine);
    addTearDown(operations.dispose);
    final first = operations.readAudit(_server);
    final second = operations.readAudit(_server, before: _ended);
    expect(
      engine.sentOfType<AuditQuery>().cast<AuditQuery>().last.before,
      _ended,
    );
    engine.emit(AuditRecords(_server, [_record(1)]));
    expect((await first).records, hasLength(1));
    await engine.close();
    expect((await second).records, isEmpty);
  });

  group('the page', () {
    late FakeEngineClient engine;
    late OperationsController operations;

    Future<void> open(WidgetTester tester, {bool inMemory = false}) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      engine = FakeEngineClient();
      operations = OperationsController(engine, auditInMemory: inMemory);
      addTearDown(() async {
        operations.dispose();
        await engine.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ActivityPage(
            operations: operations,
            serverId: _server,
            serverName: 'web-1',
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('lists the records, opens their redacted steps, and reads '
        'older pages', (tester) async {
      await open(tester);
      expect(find.text('Activity on web-1'), findsOneWidget);
      expect(find.text('Reading the log.'), findsOneWidget);
      engine.emit(
        AuditRecords(_server, [
          _record(1),
          _record(5, outcome: ActionOutcome.failed),
        ], more: true),
      );
      await tester.pumpAndSettle();

      expect(find.text('Unit action'), findsNWidgets(2));
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      // Columns reach a screen reader as "column: value" (A11Y-03).
      expect(find.bySemanticsLabel(RegExp('Result: Failed')), findsOneWidget);

      await tester.tap(find.text('Failed'));
      await tester.pumpAndSettle();
      expect(find.text('A step failed.'), findsOneWidget);
      expect(find.text('Exit status 5'), findsOneWidget);
      expect(
        find.text('env API_TOKEN=«redacted» systemctl restart nginx.service'),
        findsOneWidget,
      );
      Navigator.of(tester.element(find.text('What ran'))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Show older'));
      await tester.pump();
      final older = engine.sentOfType<AuditQuery>().cast<AuditQuery>().last;
      expect(older.before, _ended.subtract(const Duration(minutes: 5)));
    });

    testWidgets('copies the stored records, secrets already removed', (
      tester,
    ) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await open(tester, inMemory: true);
      expect(
        find.textContaining('lasts only until this window closes'),
        findsOneWidget,
      );
      engine.emit(AuditRecords(_server, [_record(1), _record(2)]));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Copy the log'));
      await tester.pumpAndSettle();
      final lines = copied!.split('\n');
      expect(lines, hasLength(2));
      expect(lines.first, contains('«redacted»'));
      expect(lines.first, contains('"tier":"acknowledge"'));
      expect(
        find.text('The log is on the clipboard, with secrets removed.'),
        findsOneWidget,
      );
      await tester.pump(const Duration(seconds: 10));
    });
  });

  testWidgets('the Safety menu opens it', (tester) async {
    final safety = SafetyController(
      initial: const SafetyPolicy(
        servers: {'srv-1': ServerSafety(management: true)},
      ),
      apply: (_) {},
    );
    addTearDown(safety.dispose);
    final harness = await pumpApp(
      tester,
      servers: twoServers,
      safety: safety,
      operations: true,
    );
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(ServerHeader),
        matching: find.byTooltip('Safety'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text('Activity on web-1'), findsOneWidget);
    expect(harness.engine.sentOfType<AuditQuery>(), hasLength(1));
  });
}
