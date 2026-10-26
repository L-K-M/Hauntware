// TRI-03: the fleet's attention queue, with acknowledgements and notes
// kept on this device.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/alert_center.dart';
import 'package:klabautermann_app/controllers/attention.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/attention.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _web = 'srv-web';
const _db = 'srv-db';

final _now = DateTime.utc(2026, 10, 26, 12);

FsMount _mount(String mountPoint, {int use = 40, int inodes = 10}) => FsMount(
  device: '/dev/sda1',
  type: 'ext4',
  mountPoint: mountPoint,
  sizeBytes: 100,
  usedBytes: use,
  availBytes: 100 - use,
  capacityPercent: use,
  inodeUsePercent: inodes,
);

SystemdUnit _unit(String name) =>
    SystemdUnit(unit: name, load: 'loaded', active: 'failed', sub: 'failed');

ActiveAlert _alert(String serverId) => ActiveAlert(
  serverId: serverId,
  ruleId: 'cpu-high',
  metric: 'cpu.busy',
  severity: AlertSeverity.warning,
  raisedAt: _now,
);

void main() {
  group('scanAttention', () {
    test('lists each server\'s problems from what it holds', () {
      final scan = scanAttention([
        AttentionSource(
          serverId: _web,
          link: const LinkReady(),
          alerts: [_alert(_web)],
          fs: FsSnapshot([
            _mount('/', use: 85),
            _mount('/var', use: 95, inodes: 93),
          ]),
          failedUnits: [_unit('nginx.service')],
          containers: [
            dockerContainer('c1', name: 'api', health: HealthStatus.unhealthy),
            dockerContainer('c2', name: 'db', health: HealthStatus.healthy),
          ],
        ),
        const AttentionSource(
          serverId: _db,
          link: LinkBlocked(LinkBlockedReason.endpointChanged),
        ),
      ]);
      expect(
        [for (final item in scan.items) (item.serverId, item.key)],
        [
          (_web, 'alert:cpu-high'),
          (_web, 'failedUnit:nginx.service'),
          (_web, 'diskFull:/var'),
          (_web, 'inodesFull:/var'),
          (_web, 'unhealthyContainer:api'),
          (_db, 'blocked:'),
        ],
      );
      expect(
        scan.items.firstWhere((i) => i.kind == AttentionKind.diskFull).percent,
        95,
        reason: '/ at 85 % only warns, which the queue leaves to the rows',
      );
      expect(scan.observed[_web], AttentionKind.values.toSet());
      expect(scan.observed[_db], {
        AttentionKind.blocked,
        AttentionKind.unreachable,
        AttentionKind.alert,
      }, reason: 'nothing held of its units, mounts or containers');
    });

    test('a failed link or a backoff reads unreachable; a closed one by '
        'its owner does not', () {
      List<AttentionKind> kinds(LinkStatus link) => [
        for (final item in scanAttention([
          AttentionSource(serverId: _web, link: link),
        ]).items)
          item.kind,
      ];
      expect(kinds(LinkBackoff(_now)), [AttentionKind.unreachable]);
      expect(
        kinds(
          const LinkClosed(
            LinkClosedReason.connectFailed,
            failure: LinkFailureKind.unreachable,
          ),
        ),
        [AttentionKind.unreachable],
      );
      expect(kinds(const LinkClosed(LinkClosedReason.closedByOwner)), isEmpty);
    });
  });

  group('AttentionAcks', () {
    const unit = AttentionItem(
      serverId: _web,
      kind: AttentionKind.failedUnit,
      subject: 'nginx.service',
    );
    const disk = AttentionItem(
      serverId: _web,
      kind: AttentionKind.diskFull,
      subject: '/var',
      percent: 95,
    );

    test('keeps a trimmed note, saves it and reads it back', () async {
      final saved = <Map<String, Object?>>[];
      final acks = AttentionAcks(save: (json) async => saved.add(json));
      await acks.acknowledge(unit, note: '  restarts tonight \n');
      expect(acks.ackFor(unit)?.note, 'restarts tonight');
      expect(acks.ackFor(disk), isNull);

      final reread = AttentionAcks(stored: saved.last);
      expect(reread.ackFor(unit)?.note, 'restarts tonight');
      expect(reread.ackFor(unit)?.at, acks.ackFor(unit)?.at);

      await acks.reopen(unit);
      expect(acks.ackFor(unit), isNull);
      expect(saved.last, isEmpty);
    });

    test('cuts a long note and skips what does not read as one', () async {
      final acks = AttentionAcks(
        stored: {
          _web: {
            'diskFull:/var': {'at': 'yesterday'},
            'failedUnit:nginx.service': {'at': '2026-10-26T12:00:00Z'},
          },
          _db: 'acknowledged',
        },
      );
      expect(acks.ackFor(disk), isNull);
      expect(acks.ackFor(unit)?.note, '');

      await acks.acknowledge(disk, note: 'x' * (kAttentionNoteMax + 10));
      expect(acks.ackFor(disk)?.note.length, kAttentionNoteMax);
    });

    test('drops what cleared, keeps what it could not see, and forgets '
        'servers that left', () async {
      final acks = AttentionAcks()
        ..acknowledge(unit)
        ..acknowledge(disk)
        ..acknowledge(
          const AttentionItem(serverId: _db, kind: AttentionKind.blocked),
        );

      // The units still list nginx; no mounts held this time.
      expect(
        acks.prune((
          items: const [unit],
          observed: {
            _web: {AttentionKind.failedUnit},
            _db: {AttentionKind.blocked},
          },
        )),
        isTrue,
        reason: "db's link is no longer blocked",
      );
      expect(acks.ackFor(unit), isNotNull);
      expect(acks.ackFor(disk), isNotNull, reason: 'no mount listing held');

      // nginx recovered; the web server's mounts are read and /var is fine.
      acks.prune((
        items: const [],
        observed: {
          _web: {AttentionKind.failedUnit, AttentionKind.diskFull},
        },
      ));
      expect(acks.ackFor(unit), isNull);
      expect(acks.ackFor(disk), isNull);
      expect(
        acks.prune((items: const [], observed: const {})),
        isFalse,
        reason: 'nothing left to drop',
      );
    });
  });

  testWidgets('the fleet list counts what needs attention; the queue '
      'acknowledges with a note until the problem clears', (tester) async {
    tester.view.physicalSize = const Size(1000, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final engine = FakeEngineClient();
    final fleet = FleetController(
      engine,
      servers: const [
        FleetServer(id: _web, displayName: 'web-1'),
        FleetServer(id: _db, displayName: 'db-1'),
      ],
    );
    final monitoring = MonitoringController(engine);
    final opened = <String>[];
    addTearDown(() async {
      fleet.dispose();
      monitoring.dispose();
      await engine.close();
    });
    var seq = 0;
    void units(List<String> names) => engine.emit(
      Sample(
        serverId: _web,
        stream: SampleStream.failedUnits,
        seq: ++seq,
        at: _now,
        result: FailedUnitsResult([for (final name in names) _unit(name)]),
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: AttentionNotice(
            fleet: fleet,
            monitoring: monitoring,
            onOpenServer: (server) => opened.add(server.id),
          ),
        ),
      ),
    );
    expect(find.byType(TextButton), findsNothing, reason: 'nothing to show');

    units(['nginx.service']);
    engine.emit(
      const LinkState(_db, LinkBlocked(LinkBlockedReason.endpointChanged)),
    );
    await tester.pumpAndSettle();
    expect(find.text('2 problems need attention'), findsOne);

    await tester.tap(find.text('Show'));
    await tester.pumpAndSettle();
    expect(find.text('Attention'), findsOne);
    expect(find.text('Unit failed: nginx.service'), findsOne);
    expect(
      find.text(
        'Connecting is blocked until you decide, for example about a changed '
        'host key.',
      ),
      findsOne,
    );

    await tester.tap(find.text('Acknowledge').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'restarts tonight');
    await tester.tap(find.widgetWithText(FilledButton, 'Acknowledge'));
    await tester.pumpAndSettle();
    expect(find.text('Acknowledged (1)'), findsOne);
    expect(find.text('restarts tonight'), findsOne);
    expect(find.text('Reopen'), findsOne);

    await tester.tap(find.text('Open server').first);
    await tester.pumpAndSettle();
    expect(opened, [_db], reason: 'the open problem lists first');
    expect(find.text('1 problem needs attention'), findsOne);

    // nginx recovers: its acknowledgement goes, so a new failure asks again.
    units([]);
    await tester.pumpAndSettle();
    units(['nginx.service']);
    await tester.pumpAndSettle();
    expect(find.text('2 problems need attention'), findsOne);
  });
}
