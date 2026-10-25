// Raised alerts as system notifications (ALR-01, 03 §7.19): off until the
// user turns them on, after the app's prompt states the coverage limit and
// the system allows them (Y3); then each raise posts a notification that
// says so, and its clear withdraws it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/alert_notifications.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/system_notifications.dart';
import 'package:klabautermann_app/ui/alerts.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

const _coverage = 'Evaluated on this device while Klabautermann is open.';

final class _FakeNotifications implements SystemNotifications {
  bool allow = true;
  int permissionRequests = 0;
  final shown = <int, ({String title, String body})>{};
  final cancelled = <int>[];

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return allow;
  }

  @override
  Future<void> show(
    int id, {
    required String title,
    required String body,
  }) async => shown[id] = (title: title, body: body);

  @override
  Future<void> cancel(int id) async => cancelled.add(id);
}

LocalAlertChanged _change(
  String ruleId, {
  required bool raised,
  String serverId = 'srv-1',
}) => LocalAlertChanged(
  serverId: serverId,
  ruleId: ruleId,
  metric: 'cpu.busy',
  severity: AlertSeverity.critical,
  raised: raised,
  at: DateTime.utc(2026, 10, 25, 12),
  value: raised ? 93 : 70,
);

void main() {
  group('AlertNotificationsController', () {
    late FakeEngineClient engine;
    late _FakeNotifications fake;
    late List<bool> saved;

    AlertNotificationsController controller({
      SystemNotifications? notifications,
      bool enabled = false,
    }) {
      final created = AlertNotificationsController(
        engine,
        notifications: notifications,
        textOf: (raise) => alertNotificationText(
          lookupAppLocalizations(const Locale('en')),
          raise,
          server: 'web-1',
        ),
        enabled: enabled,
        save: (on) async => saved.add(on),
      );
      addTearDown(created.dispose);
      return created;
    }

    setUp(() {
      engine = FakeEngineClient();
      fake = _FakeNotifications();
      saved = [];
    });

    tearDown(() => engine.close());

    test('posts nothing until turned on, then each raise posts a '
        'notification stating the coverage limit, and its clear withdraws '
        'it', () async {
      final notifications = controller(notifications: fake);
      engine.emit(_change('r1', raised: true));
      await pumpEventQueue();
      expect(fake.shown, isEmpty);

      expect(
        await notifications.setEnabled(true),
        AlertNotificationsOutcome.enabled,
      );
      expect(fake.permissionRequests, 1);
      expect(saved, [true]);
      expect(notifications.enabled, isTrue);

      engine.emit(_change('r2', raised: true));
      await pumpEventQueue();
      final posted = fake.shown.values.single;
      expect(posted.title, 'web-1: CPU busy at 93%');
      expect(posted.body, 'Critical. $_coverage');

      // r1 rose while off, so its clear withdraws nothing.
      engine
        ..emit(_change('r1', raised: false))
        ..emit(_change('r2', raised: false));
      await pumpEventQueue();
      expect(fake.cancelled, [fake.shown.keys.single]);
    });

    test('a refusal leaves them off and unsaved, and a device without '
        'notifications offers none', () async {
      fake.allow = false;
      final refused = controller(notifications: fake);
      expect(await refused.setEnabled(true), AlertNotificationsOutcome.denied);
      expect(refused.enabled, isFalse);
      expect(saved, isEmpty);

      final none = controller(enabled: true);
      expect(none.available, isFalse);
      expect(none.enabled, isFalse);
      expect(
        await none.setEnabled(true),
        AlertNotificationsOutcome.unavailable,
      );
    });

    test('a stored switch starts on, and turning it off saves', () async {
      final notifications = controller(notifications: fake, enabled: true);
      engine.emit(_change('r1', raised: true));
      await pumpEventQueue();
      expect(fake.shown, hasLength(1));

      await notifications.setEnabled(false);
      expect(saved, [false]);
      expect(fake.permissionRequests, 0);
      engine.emit(_change('r2', raised: true, serverId: 'srv-2'));
      await pumpEventQueue();
      expect(fake.shown, hasLength(1));
    });
  });

  testWidgets('the switch states the coverage limit before the system asks, '
      'and stays off when the user declines', (tester) async {
    final fake = _FakeNotifications();
    final harness = await pumpApp(
      tester,
      servers: twoServers,
      alerts: true,
      notifications: fake,
    );
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Alert rules'));
    await tester.pumpAndSettle();

    final tile = find.widgetWithText(
      SwitchListTile,
      'Notify me when an alert is raised',
    );
    expect(tile, findsOneWidget);
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(find.text('Get notified of raised alerts?'), findsOneWidget);
    expect(
      find.textContaining('It cannot notify you while it is closed.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(fake.permissionRequests, 0);
    expect(harness.alertNotifications!.enabled, isFalse);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Allow notifications'));
    await tester.pumpAndSettle();
    expect(fake.permissionRequests, 1);
    expect(harness.alertNotifications!.enabled, isTrue);
    expect(tester.widget<SwitchListTile>(tile).value, isTrue);
  });

  testWidgets('a device without notifications shows no switch', (tester) async {
    await pumpApp(tester, servers: twoServers, alerts: true);
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Alert rules'));
    await tester.pumpAndSettle();
    expect(find.text('Notify me when an alert is raised'), findsNothing);
  });
}
