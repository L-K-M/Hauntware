// FL-09 and FL-10 (03 §10.3): the fleet summary strip, the attention-first
// order and the faults-only filter over the attention queue's problems.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_servers/ghost_servers.dart' show GhostSessionState;
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/fleet_rows.dart';
import 'package:klabautermann_app/ui/fleet_triage.dart';
import 'package:klabautermann_app/ui/sidebar_kit.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

final _now = DateTime.utc(2026, 10, 27, 12);

const _a = FleetServer(id: 'srv-a', displayName: 'alpha');
const _b = FleetServer(id: 'srv-b', displayName: 'bravo');
const _c = FleetServer(id: 'srv-c', displayName: 'charlie');

Sample _overview(String serverId, {required double busy, int? used}) => Sample(
  serverId: serverId,
  stream: SampleStream.overview,
  seq: 1,
  at: _now,
  result: OverviewResult(
    cpu: CpuPercentages(const [], busy),
    memory: used == null
        ? null
        : MemoryUsage(usedBytes: used, totalBytes: 4 << 30),
  ),
);

void main() {
  test('attention first moves faulted servers up, most first, and keeps '
      'fleet order otherwise', () {
    expect(
      attentionFirst([_a, _b, _c], {'srv-c': 1, 'srv-b': 2}).map((s) => s.id),
      ['srv-b', 'srv-c', 'srv-a'],
    );
    expect(attentionFirst([_a, _b, _c], const {}), [_a, _b, _c]);
  });

  test('the summary counts who answers and averages fresh readings only', () {
    final sessions = {
      'srv-a': GhostSessionState.connected,
      'srv-b': GhostSessionState.connected,
      'srv-c': GhostSessionState.failed,
    };
    final overviews = {
      'srv-a': _overview('srv-a', busy: 20, used: 1 << 30),
      // Older than the rows' stale limit: left out.
      'srv-b': Sample(
        serverId: 'srv-b',
        stream: SampleStream.overview,
        seq: 1,
        at: _now.subtract(const Duration(minutes: 10)),
        result: OverviewResult(cpu: CpuPercentages(const [], 90)),
      ),
      // Its link is down: left out though fresh.
      'srv-c': _overview('srv-c', busy: 80, used: 2 << 30),
    };
    final summary = fleetSummary(
      servers: const [_a, _b, _c],
      session: (id) => sessions[id]!,
      probe: (id) => id == 'srv-c' ? ReachabilityStatus.online : null,
      overview: (id) => overviews[id],
      core: (_) => null,
      // A server that left the fleet is no longer counted.
      openProblems: const {'srv-c': 1, 'srv-gone': 2},
      now: _now,
    );

    expect(summary.total, 3);
    expect(summary.online, 3, reason: 'two links up, one probe answered');
    expect(summary.needAttention, 1);
    expect(summary.reporting, 1);
    expect(summary.cpuPercent, 20);
    expect(summary.memoryUsedBytes, 1 << 30);
    expect(summary.memoryTotalBytes, 4 << 30);
  });

  testWidgets('the fleet list filters to and sorts by what needs '
      'attention, and says when nothing does', (tester) async {
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = FakeEngineClient();
    final fleet = FleetController(engine, servers: const [_a, _b, _c]);
    final monitoring = MonitoringController(engine);
    addTearDown(() async {
      fleet.dispose();
      monitoring.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => SidebarKitScope(
              strings: klabautermannSidebarStrings(
                AppLocalizations.of(context),
              ),
              child: FleetServerList(
                fleet: fleet,
                monitoring: monitoring,
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text('0 of 3 online'), findsOneWidget);
    expect(
      find.byType(FilterChip),
      findsNothing,
      reason: 'nothing to triage yet',
    );

    void failedUnits(int seq, List<SystemdUnit> units) => engine.emit(
      Sample(
        serverId: 'srv-c',
        stream: SampleStream.failedUnits,
        seq: seq,
        at: _now,
        result: FailedUnitsResult(units),
      ),
    );
    const nginx = SystemdUnit(
      unit: 'nginx.service',
      load: 'loaded',
      active: 'failed',
      sub: 'failed',
    );

    failedUnits(1, [nginx]);
    await tester.pumpAndSettle();
    expect(find.text('1 needs attention'), findsOneWidget);

    await tester.tap(find.text('Needs attention (1)'));
    await tester.pumpAndSettle();
    expect(find.text('charlie'), findsOneWidget);
    expect(find.text('alpha'), findsNothing);

    failedUnits(2, const []);
    await tester.pumpAndSettle();
    expect(find.text('Nothing needs attention.'), findsOneWidget);
    await tester.tap(find.text('Show all servers'));
    await tester.pumpAndSettle();
    expect(find.text('alpha'), findsOneWidget);

    failedUnits(3, [nginx]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Attention first'));
    await tester.pumpAndSettle();
    final names = [
      for (final name in ['alpha', 'bravo', 'charlie'])
        tester.getTopLeft(find.text(name)).dy,
    ];
    expect(names[2], lessThan(names[0]), reason: 'charlie leads');
    expect(names[0], lessThan(names[1]), reason: 'alpha before bravo');
  });
}
