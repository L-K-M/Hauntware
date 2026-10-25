import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/docker/volumes_panel.dart';
import 'package:klabautermann_app/ui/docker/volumes_view.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';

const _wide = Size(1000, 600);
const _phone = Size(390, 900);

/// When the lists are read; local, so nothing depends on the test
/// machine's zone.
final _now = DateTime(2026, 10, 15, 14, 30);

/// Three volumes: one two containers mount, one a stopped container
/// mounts, and one nothing mounts (VOL-01).
final _volumes = [
  VolumeSummary(
    name: 'pgdata',
    driver: 'local',
    createdAt: _now.subtract(const Duration(days: 4)),
  ),
  VolumeSummary(
    name: 'cache',
    driver: 'local',
    createdAt: _now.subtract(const Duration(hours: 5)),
  ),
  VolumeSummary(name: 'orphan', driver: 'nfs'),
];

final _containers = [
  dockerContainer('a1', name: 'db', volumes: ['pgdata']),
  dockerContainer('a2', name: 'backup', volumes: ['pgdata', 'pgdata']),
  dockerContainer('b1', name: 'worker', state: 'exited', volumes: ['cache']),
];

final class _Panel {
  _Panel(this.engine, this.visible);

  final FakeEngineClient engine;
  final ValueNotifier<bool> visible;

  List<DockerWatch> get watches => engine.sentOfType<DockerWatch>().cast();
  List<DockerUnwatch> get unwatches =>
      engine.sentOfType<DockerUnwatch>().cast();

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  Future<void> list(
    WidgetTester tester, {
    List<ContainerSummary>? containers,
  }) async {
    await emit(tester, dockerVolumeList(_serverId, _volumes, at: _now));
    if (containers != null) {
      await emit(tester, dockerContainerList(_serverId, containers, at: _now));
    }
  }
}

Future<_Panel> _pump(WidgetTester tester, {Size size = _wide}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine, now: () => _now);
  final visible = ValueNotifier(true);
  addTearDown(() async {
    monitoring.dispose();
    visible.dispose();
    await engine.close();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: GhostTheme.light(klabautermannThemeStyle),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: ValueListenableBuilder(
          valueListenable: visible,
          builder: (context, shows, _) => VolumesPanel(
            monitoring: monitoring,
            serverId: _serverId,
            visible: shows,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine, visible);
}

const _prefix = 'volumes.row.';

/// The volumes the panel shows, top to bottom, by name.
List<String> _order(WidgetTester tester) {
  final rows = [
    for (final element in find.byType(Semantics).evaluate())
      if (element.widget.key case ValueKey<String>(
        :final value,
      ) when value.startsWith(_prefix))
        (
          name: value.substring(_prefix.length),
          top: tester.getTopLeft(find.byWidget(element.widget)).dy,
        ),
  ]..sort((a, b) => a.top.compareTo(b.top));
  return [for (final row in rows) row.name];
}

String _label(WidgetTester tester, String name) =>
    tester.getSemantics(find.byKey(ValueKey('$_prefix$name'))).label;

/// 03 §10.4's Volumes sub-tab (VOL-01) over the volume watch.
void main() {
  test('counts each container mounting a volume once, and named volumes '
      'only', () {
    final counts = containersByVolume([
      ..._containers,
      dockerContainer('c1'),
      ContainerSummary(
        id: 'd1',
        mounts: const [ContainerMount(type: 'bind', name: 'pgdata')],
      ),
    ]);
    expect(counts, {'pgdata': 2, 'cache': 1});
  });

  testWidgets('watches the volumes and containers while it shows and reads '
      'nothing hidden', (tester) async {
    final panel = await _pump(tester);
    expect(panel.watches.single.lists, {
      DockerWatchList.volumes,
      DockerWatchList.containers,
    });
    expect(find.text('Reading the volumes…'), findsOneWidget);

    panel.visible.value = false;
    await tester.pumpAndSettle();
    expect(panel.unwatches.single.watchId, panel.watches.single.watchId);
  });

  testWidgets('shows name, driver, age and use, sorted by name, and filters '
      'the unused', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, containers: _containers);

    expect(_order(tester), ['cache', 'orphan', 'pgdata']);
    expect(
      _label(tester, 'pgdata'),
      allOf(
        contains('local'),
        contains('4 days ago'),
        contains('Mounted by 2 containers'),
      ),
    );
    expect(_label(tester, 'cache'), contains('Mounted by 1 container'));
    expect(_label(tester, 'orphan'), contains('Unused'));

    await tester.tap(find.widgetWithText(ChoiceChip, 'Unused'));
    await tester.pumpAndSettle();
    expect(_order(tester), ['orphan']);

    await tester.enterText(find.byType(TextField), 'local');
    await tester.pumpAndSettle();
    expect(find.text('Every volume is mounted by a container.'), findsNothing);
    expect(find.text('No volume matches the search.'), findsOneWidget);
  });

  testWidgets('without a container list the use is unknown and says why', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    await panel.emit(
      tester,
      DockerListChanged(
        serverId: _serverId,
        list: DockerWatchList.containers,
        payload: const DockerQueryFailed(
          DockerQueryFailure.daemonError,
          detail: 'boom',
        ),
        at: _now,
      ),
    );

    expect(
      find.textContaining('Which volumes are in use is unknown'),
      findsOneWidget,
    );
    expect(_label(tester, 'pgdata'), contains('Use: unknown'));
  });

  testWidgets('the Unused filter lists every volume until a container list '
      'says which are unused', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester);

    final unused = find.widgetWithText(ChoiceChip, 'Unused');
    expect(tester.widget<ChoiceChip>(unused).onSelected, isNull);
    await tester.tap(unused);
    await tester.pumpAndSettle();
    expect(_order(tester), ['cache', 'orphan', 'pgdata']);
    expect(find.text('Every volume is mounted by a container.'), findsNothing);

    await panel.emit(
      tester,
      dockerContainerList(_serverId, _containers, at: _now),
    );
    await tester.tap(unused);
    await tester.pumpAndSettle();
    expect(_order(tester), ['orphan']);
  });

  testWidgets('says why the list failed, keeps the last one and watches '
      'again on Try again', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, containers: _containers);
    await panel.emit(
      tester,
      DockerListChanged(
        serverId: _serverId,
        list: DockerWatchList.volumes,
        payload: const DockerQueryFailed(DockerQueryFailure.connectionFailed),
        at: _now,
      ),
    );

    expect(
      find.text(
        'The connection to the engine failed while listing the volumes.',
      ),
      findsOneWidget,
    );
    expect(find.text('The list below is the last one read.'), findsOneWidget);
    expect(_order(tester), ['cache', 'orphan', 'pgdata']);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(panel.unwatches, hasLength(1));
    expect(panel.watches, hasLength(2));
  });

  testWidgets('an empty engine says so', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(tester, dockerVolumeList(_serverId, const [], at: _now));
    expect(find.text('This engine has no volumes.'), findsOneWidget);
  });

  testWidgets('a phone lists two-line rows with a sort menu', (tester) async {
    final panel = await _pump(tester, size: _phone);
    await panel.list(tester, containers: _containers);

    expect(find.byType(DropdownButton<VolumeColumn>), findsOneWidget);
    expect(_order(tester), ['cache', 'orphan', 'pgdata']);
    expect(_label(tester, 'orphan'), contains('Driver: nfs'));
  });
}
