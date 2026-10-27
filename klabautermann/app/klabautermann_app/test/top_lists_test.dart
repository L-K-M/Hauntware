// OV-07: the Overview's top lists of processes and containers, by CPU
// and by memory, read only while the card shows.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/top_lists.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
final _now = DateTime.utc(2026, 10, 27, 12);

ProcessRow _process(int pid, String name, {double? cpu, int? rss}) =>
    ProcessRow(pid: pid, name: name, cpuPercent: cpu, residentBytes: rss);

void main() {
  test('the top processes rank by the figure asked, the most first, at '
      'most five, leaving out those without it', () {
    final processes = [
      for (var i = 1; i <= 7; i++)
        _process(i, 'p$i', cpu: i.toDouble(), rss: (8 - i) << 20),
      _process(9, 'idle'),
    ];
    expect(topProcesses(processes, TopMeasure.cpu).map((e) => e.pid), [
      7,
      6,
      5,
      4,
      3,
    ]);
    expect(topProcesses(processes, TopMeasure.memory).first.label, 'p1');
  });

  test('the top containers rank by their list stats', () {
    final containers = [
      dockerContainer('a', name: 'web'),
      dockerContainer('b', name: 'db'),
      dockerContainer('c', name: 'cache'),
    ];
    final stats = {
      'a': ContainerListStats(containerId: 'a', at: _now, cpuPercent: 3),
      'b': ContainerListStats(
        containerId: 'b',
        at: _now,
        cpuPercent: 40,
        memoryUsed: 1 << 30,
      ),
    };
    expect(
      topContainers(containers, stats, TopMeasure.cpu).map((e) => e.label),
      ['db', 'web'],
    );
    expect(
      topContainers(containers, stats, TopMeasure.memory).map((e) => e.label),
      ['db'],
    );
  });

  testWidgets('the card reads processes and container stats while it '
      'shows, and ranks them by CPU or memory', (tester) async {
    final engine = FakeEngineClient();
    final monitoring = MonitoringController(engine);
    addTearDown(() async {
      monitoring.dispose();
      await engine.close();
    });
    Future<void> pump({required bool visible}) => tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: TopListsCard(
              monitoring: monitoring,
              serverId: _serverId,
              visible: visible,
            ),
          ),
        ),
      ),
    );
    engine.emit(dockerReady(_serverId));
    await pump(visible: true);
    await tester.pump();
    expect(
      engine.sentOfType<Subscribe>(),
      isEmpty,
      reason: 'closed, the card reads nothing',
    );
    await tester.tap(find.text('Show the busiest processes and containers'));
    await tester.pump();

    final subscribed = engine.sentOfType<Subscribe>().cast<Subscribe>();
    expect(subscribed.single.streams, {SampleStream.procs});
    expect(find.text('Waiting for the first reading…'), findsNWidgets(2));

    engine.emit(
      Sample(
        serverId: _serverId,
        stream: SampleStream.procs,
        seq: 1,
        at: _now,
        result: ProcsResult([
          _process(10, 'nginx', cpu: 12.5, rss: 50 << 20),
          _process(11, 'postgres', cpu: 3, rss: 400 << 20),
        ]),
      ),
    );
    engine.emit(
      dockerContainerList(_serverId, [
        dockerContainer('c1', name: 'web'),
      ], at: _now),
    );
    await tester.pump();
    final statsFor = engine
        .sentOfType<DockerWatch>()
        .cast<DockerWatch>()
        .last
        .statsFor;
    expect(statsFor, {'c1'}, reason: 'the running containers');
    engine.emit(
      dockerStatsRound(_serverId, [
        ContainerListStats(containerId: 'c1', at: _now, cpuPercent: 7.25),
      ], at: _now),
    );
    await tester.pumpAndSettle();

    expect(find.text('nginx (10)'), findsOneWidget);
    expect(find.text('12.5 %'), findsOneWidget);
    expect(find.text('web'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('nginx (10)')).dy,
      lessThan(tester.getTopLeft(find.text('postgres (11)')).dy),
    );

    await tester.tap(find.text('Memory'));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('postgres (11)')).dy,
      lessThan(tester.getTopLeft(find.text('nginx (10)')).dy),
    );
    expect(find.text('Nothing to rank yet.'), findsOneWidget);

    await pump(visible: false);
    await tester.pump();
    expect(engine.sentOfType<Unsubscribe>(), isNotEmpty);
    expect(engine.sentOfType<DockerUnwatch>(), isNotEmpty);
  });
}
