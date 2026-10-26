// CST-03, CST-04: a container's usage history from its list stats, with
// network and block I/O as rates between reads, a break after a long
// pause, none across a total that went down, and the memory share of
// its limit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/container_usage.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/docker/container_usage_charts.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

final _start = DateTime.utc(2026, 10, 26, 12);

ContainerListStats _row(
  int second, {
  double? cpu,
  int? used,
  int? limit,
  int? rx,
  int? tx,
  int? read,
  int? written,
  int? pids,
}) => ContainerListStats(
  containerId: 'c1',
  at: _start.add(Duration(seconds: second)),
  cpuPercent: cpu,
  memoryUsed: used,
  memoryLimit: limit,
  networkRx: rx,
  networkTx: tx,
  blockRead: read,
  blockWrite: written,
  pids: pids,
);

void main() {
  test('each read lands in its chart, totals as rates between reads', () {
    final history = ContainerUsageHistory();
    addTearDown(history.dispose);
    history
      ..add(_row(0, cpu: 5, used: 100, limit: 1000, rx: 0, tx: 0, pids: 3))
      ..add(
        _row(5, cpu: 7, used: 200, limit: 1000, rx: 5000, tx: 500, pids: 4),
      );

    expect(history.latest?.cpuPercent, 7);
    expect(history.cpu.valueAt(0, 1), 7);
    expect(
      [history.memory.valueAt(0, 1), history.memory.valueAt(1, 1)],
      [200, 1000],
    );
    expect(history.network.valueAt(0, 0), isNull, reason: 'no rate yet');
    expect(
      [history.network.valueAt(0, 1), history.network.valueAt(1, 1)],
      [1000, 100],
    );
    expect(history.blockIo.valueAt(0, 1), isNull, reason: 'none reported');
    expect(history.pids.valueAt(0, 1), 4);
  });

  test('a repeat is ignored, a long pause breaks the line, and a total '
      'that went down gives no rate', () {
    final history = ContainerUsageHistory();
    addTearDown(history.dispose);
    history
      ..add(_row(0, rx: 9000))
      ..add(_row(0, rx: 9999))
      ..add(_row(60, rx: 100));

    expect(history.network.length, 2);
    expect(history.network.joinsPrevious(1), isFalse, reason: 'a gap');
    expect(history.network.valueAt(0, 1), isNull, reason: 'it restarted');
  });

  test('the memory share of its limit, none without one', () {
    expect(memoryLimitShare(_row(0, used: 930, limit: 1000)), 0.93);
    expect(memoryLimitShare(_row(0, used: 930)), isNull);
    expect(memoryLimitShare(_row(0, used: 930, limit: 0)), isNull);
  });

  testWidgets('the charts wait for a first reading, then chart it, and '
      'memory near its limit says so', (tester) async {
    final engine = FakeEngineClient();
    final monitoring = MonitoringController(engine, now: () => _start);
    addTearDown(() async {
      monitoring.dispose();
      await engine.close();
    });
    monitoring.docker.watchContainers('srv-1');
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: ContainerUsageCharts(
              monitoring: monitoring,
              serverId: 'srv-1',
              containerId: 'c1',
            ),
          ),
        ),
      ),
    );
    expect(find.text('Usage'), findsOneWidget);
    expect(find.textContaining('first reading'), findsOneWidget);

    engine.emit(
      dockerContainerList('srv-1', [dockerContainer('c1')], at: _start),
    );
    engine.emit(
      dockerStatsRound('srv-1', [
        _row(0, cpu: 3, used: 950, limit: 1000, pids: 2),
      ], at: _start),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('first reading'), findsNothing);
    expect(
      find.textContaining('Memory is at 95% of its limit'),
      findsOneWidget,
    );
    for (final title in ['CPU', 'Memory', 'Network', 'Block I/O', 'PIDs']) {
      expect(find.text(title), findsWidgets, reason: title);
    }
  });
}
