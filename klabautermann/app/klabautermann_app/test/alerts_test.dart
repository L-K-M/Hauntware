// In-app alerts in the app (ALR-01, ALR-02; 03 §7.19): the alert center
// follows the engine's raises and clears, the fleet list's notice states
// the coverage limit (Y3) and opens the center, and each fleet row badges
// its server's raised alerts.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/alert_center.dart';
import 'package:klabautermann_app/ui/alerts.dart';
import 'package:klabautermann_app/ui/fleet_rows.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

const _phone = Size(390, 844);
const _coverage = 'Evaluated on this device while Klabautermann is open.';

final _t0 = DateTime.utc(2026, 10, 25, 12);

LocalAlertChanged _change(
  String serverId,
  String ruleId, {
  required bool raised,
  String metric = 'cpu.busy',
  AlertSeverity severity = AlertSeverity.warning,
  double? value = 93,
  int minute = 0,
}) => LocalAlertChanged(
  serverId: serverId,
  ruleId: ruleId,
  metric: metric,
  severity: severity,
  raised: raised,
  at: _t0.add(Duration(minutes: minute)),
  value: value,
  since: raised ? _t0 : null,
);

Finder _inRow(String serverId, Finder finder) => find.descendant(
  of: find.byWidgetPredicate(
    (widget) => widget is FleetServerRow && widget.server.id == serverId,
  ),
  matching: finder,
);

void main() {
  group('AlertCenter', () {
    late FakeEngineClient engine;
    late AlertCenter center;

    setUp(() {
      engine = FakeEngineClient();
      center = AlertCenter(engine);
    });

    tearDown(() async {
      center.dispose();
      await engine.close();
    });

    test('a raise is active until its clear, and both enter the history, '
        'newest first', () async {
      engine.emit(_change('srv-1', 'r1', raised: true));
      await pumpEventQueue();
      expect(center.active.single.ruleId, 'r1');
      expect(center.countFor('srv-1'), 1);
      expect(center.severityFor('srv-1'), AlertSeverity.warning);
      expect(center.unseen, 1);

      engine.emit(_change('srv-1', 'r1', raised: false, minute: 5));
      await pumpEventQueue();
      expect(center.active, isEmpty);
      expect(center.countFor('srv-1'), 0);
      expect(center.severityFor('srv-1'), isNull);
      expect([for (final t in center.history) t.raised], [false, true]);
      expect(center.unseen, 2);

      center.markSeen();
      expect(center.unseen, 0);
    });

    test('active alerts sort critical first, and a server badges its '
        'highest severity', () async {
      engine
        ..emit(_change('srv-1', 'r1', raised: true))
        ..emit(
          _change(
            'srv-1',
            'r2',
            raised: true,
            metric: 'disk.used',
            severity: AlertSeverity.critical,
          ),
        )
        ..emit(
          _change('srv-2', 'r1', raised: true, severity: AlertSeverity.info),
        );
      await pumpEventQueue();

      expect(
        [for (final a in center.active) a.severity],
        [AlertSeverity.critical, AlertSeverity.warning, AlertSeverity.info],
      );
      expect(center.countFor('srv-1'), 2);
      expect(center.severityFor('srv-1'), AlertSeverity.critical);
      expect(center.serversWithAlerts, 2);
    });

    test('the history keeps the latest transitions only', () async {
      for (var i = 0; i < AlertCenter.historyLimit + 5; i++) {
        engine.emit(_change('srv-1', 'r$i', raised: true, minute: i));
      }
      await pumpEventQueue();
      expect(center.history, hasLength(AlertCenter.historyLimit));
      expect(center.history.first.ruleId, 'r${AlertCenter.historyLimit + 4}');
      expect(center.active, hasLength(AlertCenter.historyLimit + 5));
    });

    test('a stopped engine raises nothing, so no alert stays active', () async {
      engine.emit(_change('srv-1', 'r1', raised: true));
      await pumpEventQueue();
      await engine.close();
      await pumpEventQueue();
      expect(center.active, isEmpty);
      expect(center.history, hasLength(1));
    });
  });

  testWidgets('a raised alert badges its row, and the notice states the '
      'coverage limit and opens the alert center', (tester) async {
    final harness = await pumpApp(tester, servers: twoServers, alerts: true);
    expect(find.text(_coverage), findsNothing);
    expect(find.byType(AlertBadge), findsNothing);

    harness.engine
      ..emit(_change('srv-1', 'r1', raised: true))
      ..emit(
        _change(
          'srv-1',
          'r2',
          raised: true,
          metric: 'load.perCore',
          severity: AlertSeverity.critical,
          value: 1.5,
        ),
      );
    await tester.pumpAndSettle();

    expect(find.text('2 alerts are active'), findsOneWidget);
    expect(find.text(_coverage), findsOneWidget);
    final badge = tester.widget<AlertBadge>(
      _inRow('srv-1', find.byType(AlertBadge)),
    );
    expect((badge.count, badge.severity), (2, AlertSeverity.critical));
    expect(_inRow('srv-2', find.byType(AlertBadge)), findsNothing);
    expect(tester.getSemantics(find.text('web-1')).label, contains('2 alerts'));

    await tester.tap(find.text('Show alerts'));
    await tester.pumpAndSettle();
    final dialog = find.byType(AlertCenterView);
    expect(
      find.descendant(of: dialog, matching: find.text(_coverage)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: dialog, matching: find.text('web-1: Load per core')),
      findsNWidgets(2),
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('Critical · 1.50 · since'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: dialog,
        matching: find.textContaining('Warning · 93% · since'),
      ),
      findsOneWidget,
    );
    expect(harness.alerts!.unseen, 0);

    // A row opens its server, closing the center.
    await tester.tap(
      find.descendant(of: dialog, matching: find.text('web-1: CPU busy')).first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertCenterView), findsNothing);
    expect(harness.fleet.selectedServerId, 'srv-1');
  });

  testWidgets('cleared alerts leave a notice until the user looks, then '
      'the list shows none', (tester) async {
    final harness = await pumpApp(
      tester,
      size: _phone,
      servers: twoServers,
      alerts: true,
    );
    harness.engine
      ..emit(_change('srv-2', 'r1', raised: true, metric: 'memory.used'))
      ..emit(
        _change('srv-2', 'r1', raised: false, metric: 'memory.used', minute: 3),
      );
    await tester.pumpAndSettle();

    expect(
      find.text('Every alert has cleared since you last looked.'),
      findsOneWidget,
    );
    expect(find.byType(AlertBadge), findsNothing);

    await tester.tap(find.text('Show alerts'));
    await tester.pumpAndSettle();
    expect(find.text('No alert is active.'), findsOneWidget);
    expect(find.textContaining('Cleared at'), findsOneWidget);
    expect(find.textContaining('Raised at'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Show alerts'), findsNothing);
  });
}
