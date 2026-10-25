// The alert rule editor (ALR-01, ALR-16; 03 §4.8, §7.19): the server
// header and the alert center open the rules page, which lists the
// account's rules with the coverage limit (Y3) and, while enrolled, adds,
// changes and deletes them through the engine's rule writes.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/alert_rules_controller.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/ui/alert_rules.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';
import 'support/sync_sign_in.dart';

const _coverage = 'Evaluated on this device while Klabautermann is open.';

const _servers = [
  FleetServer(
    id: 'srv-1',
    displayName: 'web-1',
    address: 'web-1.example',
    origin: FleetEntryOrigin.synced,
    group: 'web',
  ),
  FleetServer(
    id: 'srv-2',
    displayName: 'db-1',
    address: '10.0.0.4',
    origin: FleetEntryOrigin.synced,
  ),
];

SyncedRule _rule(
  String id, {
  RuleScope scope = RuleScope.server,
  String? target,
  String metric = 'cpu.busy',
  ThresholdOp op = ThresholdOp.greaterThan,
  double raise = 90,
  double clear = 80,
  Duration raiseFor = Duration.zero,
  AlertSeverity severity = AlertSeverity.warning,
}) => SyncedRule(
  id: id,
  target: target,
  rule: alertRule(
    metric: metric,
    scope: scope,
    op: op,
    raise: ThresholdBound(value: raise, duration: raiseFor),
    clear: ThresholdBound(value: clear),
    severity: severity,
  ),
);

final _rules = AlertRulesChanged([
  _rule('r-web1', target: 'srv-1', raiseFor: const Duration(minutes: 5)),
  _rule('r-db1', target: 'srv-2', metric: 'memory.used'),
  _rule(
    'r-group',
    scope: RuleScope.group,
    target: 'web',
    metric: 'load.perCore',
    raise: 2,
    clear: 1.5,
  ),
  _rule(
    'r-all',
    scope: RuleScope.all,
    metric: 'disk.used',
    op: ThresholdOp.greaterOrEqual,
    raise: 95,
    clear: 90,
    severity: AlertSeverity.critical,
  ),
]);

Future<AppHarness> _openWeb1Rules(
  WidgetTester tester, {
  bool enrolled = true,
}) async {
  final harness = await pumpApp(
    tester,
    servers: _servers,
    alerts: true,
    syncAccount: enrolled ? testSyncAccount : null,
  );
  harness.engine.emit(_rules);
  await tester.tap(find.text('web-1'));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('Alert rules'));
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  group('AlertRulesController', () {
    late FakeEngineClient engine;
    late AlertRulesController rules;

    setUp(() {
      engine = FakeEngineClient();
      rules = AlertRulesController(engine);
    });

    tearDown(() async {
      rules.dispose();
      await engine.close();
    });

    test('follows the engine\'s rules, and a write completes on its '
        'answer', () async {
      engine.emit(_rules);
      await pumpEventQueue();
      expect(
        [for (final r in rules.rules) r.id],
        ['r-web1', 'r-db1', 'r-group', 'r-all'],
      );

      final put = rules.put(_rule('x').rule, target: 'srv-1');
      final sent = engine.sentOfType<PutRule>().single as PutRule;
      expect(sent.ruleId, hasLength(36));
      expect(sent.target, 'srv-1');
      engine.emit(CatalogWritten(requestId: sent.requestId));
      await expectLater(put, completes);

      final removed = rules.remove('r-db1');
      final remove = engine.sentOfType<RemoveRule>().single as RemoveRule;
      expect(remove.ruleId, 'r-db1');
      engine.emit(
        CatalogWriteRefused(
          requestId: remove.requestId,
          failure: CatalogWriteFailure.notEnrolled,
        ),
      );
      await expectLater(
        removed,
        throwsA(
          isA<AlertRuleNotSavedException>().having(
            (e) => e.failure,
            'failure',
            CatalogWriteFailure.notEnrolled,
          ),
        ),
      );
    });

    test('a stopped engine fails a pending write', () async {
      final put = rules.put(_rule('x').rule);
      await engine.close();
      await expectLater(
        put,
        throwsA(
          isA<AlertRuleNotSavedException>().having(
            (e) => e.failure,
            'failure',
            isNull,
          ),
        ),
      );
    });
  });

  testWidgets('a server\'s rules page lists the rules that apply to it, '
      'each with the coverage limit', (tester) async {
    await _openWeb1Rules(tester, enrolled: false);

    expect(find.byType(AlertRulesPage), findsOneWidget);
    expect(find.text('CPU busy above 90%'), findsOneWidget);
    expect(find.text('On web-1 · Warning · after 5 minutes'), findsOneWidget);
    expect(find.text('Clears at or below 80%'), findsOneWidget);
    expect(find.text('Load per core above 2.00'), findsOneWidget);
    expect(find.text('On the web group · Warning'), findsOneWidget);
    expect(find.text('Disk space used at or above 95%'), findsOneWidget);
    expect(find.text('On every server · Critical'), findsOneWidget);
    expect(find.text('Clears below 90%'), findsOneWidget);
    // db-1's rule applies elsewhere.
    expect(find.textContaining('Memory used'), findsNothing);
    // The header's line and one per row.
    expect(find.text(_coverage), findsNWidgets(4));

    // Rules sync, so without an account they stay read-only.
    expect(
      find.text(
        'Alert rules sync through your sync account, so adding or '
        'changing one needs you signed in.',
      ),
      findsOneWidget,
    );
    expect(find.text('Add rule'), findsNothing);
    expect(find.byTooltip('Delete rule'), findsNothing);
  });

  testWidgets('adding a rule from a server checks its thresholds and '
      'saves it on that server', (tester) async {
    final harness = await _openWeb1Rules(tester);

    await tester.tap(find.text('Add rule'));
    await tester.pumpAndSettle();
    expect(find.text('New rule'), findsOneWidget);

    Finder field(String label) =>
        find.widgetWithText(TextFormField, label).first;
    await tester.enterText(field('Raise at'), '85');
    await tester.enterText(field('Clear at'), '88');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(
      find.text('The clear value must not be above the raise value.'),
      findsOneWidget,
    );
    expect(harness.engine.sentOfType<PutRule>(), isEmpty);

    await tester.enterText(field('Clear at'), '75');
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Held for (minutes)').first,
      '2.5',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('New rule'), findsNothing);

    final put = harness.engine.sentOfType<PutRule>().single as PutRule;
    expect(put.target, 'srv-1');
    expect(put.rule.scope, RuleScope.server);
    expect(put.rule.metric, 'cpu.busy');
    expect(put.rule.op, ThresholdOp.greaterThan);
    expect(put.rule.raise.value, 85);
    expect(put.rule.raise.duration, const Duration(seconds: 150));
    expect(put.rule.clear.value, 75);
    expect(alertRuleSeverity(put.rule), AlertSeverity.warning);
    expect(put.rule.evalScope, RuleEvalScope.client);
    harness.engine.emit(CatalogWritten(requestId: put.requestId));
    await tester.pumpAndSettle();
  });

  testWidgets('editing keeps a rule\'s id and scope, and a refused delete '
      'says why', (tester) async {
    final harness = await _openWeb1Rules(tester);

    await tester.tap(find.text('Load per core above 2.00'));
    await tester.pumpAndSettle();
    expect(find.text('Edit rule'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Raise at').first,
      '3',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final put = harness.engine.sentOfType<PutRule>().single as PutRule;
    expect((put.ruleId, put.target), ('r-group', 'web'));
    expect(put.rule.scope, RuleScope.group);
    expect(put.rule.raise.value, 3);

    await tester.tap(find.byTooltip('Delete rule').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    final remove = harness.engine.sentOfType<RemoveRule>().single as RemoveRule;
    expect(remove.ruleId, 'r-web1');
    harness.engine.emit(
      CatalogWriteRefused(
        requestId: remove.requestId,
        failure: CatalogWriteFailure.unknownTarget,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('This rule is no longer in your account.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('the alert center opens every rule', (tester) async {
    final harness = await pumpApp(tester, servers: _servers, alerts: true);
    harness.engine
      ..emit(_rules)
      ..emit(
        LocalAlertChanged(
          serverId: 'srv-2',
          ruleId: 'r-db1',
          metric: 'memory.used',
          severity: AlertSeverity.warning,
          raised: true,
          at: DateTime.utc(2026, 10, 25, 12),
          value: 93,
        ),
      );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show alerts'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Alert rules'));
    await tester.pumpAndSettle();

    expect(find.byType(AlertRulesPage), findsOneWidget);
    expect(find.text('Memory used above 90%'), findsOneWidget);
    expect(find.text('CPU busy above 90%'), findsOneWidget);
  });
}
