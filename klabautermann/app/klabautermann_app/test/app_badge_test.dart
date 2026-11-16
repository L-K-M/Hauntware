// The app icon badge (ALR-02, decision Q3): the unseen raised alerts,
// shown only while alert notifications are on. Delivery to the icon is
// the plugin's, on iOS and macOS, and is a manual device check.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/alert_center.dart';
import 'package:klabautermann_app/controllers/alert_notifications.dart';
import 'package:klabautermann_app/controllers/app_badge.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/system_notifications.dart';
import 'package:klabautermann_app/ui/alerts.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

final class _Badges implements SystemNotifications {
  final badges = <int>[];

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<bool> permitted() async => true;

  @override
  Future<void> show(int id, {required String title, required String body}) =>
      Future.value();

  @override
  Future<void> cancel(int id) => Future.value();

  @override
  Future<void> setBadge(int count) async => badges.add(count);
}

LocalAlertChanged _change(String serverId, {required bool raised}) =>
    LocalAlertChanged(
      serverId: serverId,
      ruleId: 'r1',
      metric: 'cpu.busy',
      severity: AlertSeverity.warning,
      raised: raised,
      at: DateTime.utc(2026, 11, 15),
      value: 93,
    );

void main() {
  test('appBadgeCount is the unseen raises while notifications are on, '
      'else none', () {
    expect(appBadgeCount(unseenRaised: 3, notificationsOn: true), 3);
    expect(appBadgeCount(unseenRaised: 3, notificationsOn: false), 0);
    expect(appBadgeCount(unseenRaised: 0, notificationsOn: true), 0);
  });

  test('the badge follows raises, opening the alerts and the switch, and '
      'clears a stale badge at start', () async {
    final engine = FakeEngineClient();
    final sink = _Badges();
    final alerts = AlertCenter(engine);
    final notifications = AlertNotificationsController(
      engine,
      notifications: sink,
      textOf: (raise) => alertNotificationText(
        lookupAppLocalizations(const Locale('en')),
        raise,
        server: raise.serverId,
      ),
      enabled: true,
    );
    final badge = AppBadgeController(
      alerts: alerts,
      notifications: notifications,
      sink: sink,
    );
    addTearDown(() async {
      badge.dispose();
      notifications.dispose();
      alerts.dispose();
      await engine.close();
    });
    expect(sink.badges, [0]);

    engine
      ..emit(_change('srv-1', raised: true))
      ..emit(_change('srv-2', raised: true));
    await pumpEventQueue();
    expect(sink.badges, [0, 1, 2]);

    alerts.markSeen();
    expect(sink.badges, [0, 1, 2, 0]);

    engine.emit(_change('srv-1', raised: false));
    engine.emit(_change('srv-1', raised: true));
    await pumpEventQueue();
    expect(sink.badges.last, 1);

    await notifications.setEnabled(false);
    expect(sink.badges.last, 0, reason: 'no badge while notifications off');

    engine.emit(_change('srv-3', raised: true));
    await pumpEventQueue();
    expect(sink.badges.last, 0);

    await notifications.setEnabled(true);
    expect(sink.badges.last, 2);
  });
}
