import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/docker/containers_panel.dart';
import 'package:klabautermann_app/ui/docker/containers_view.dart';
import 'package:klabautermann_app/ui/sortable_table.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
const _mib = 1024 * 1024;

const _wide = Size(1000, 600);
const _phone = Size(390, 900);

/// When the lists are read; local, so nothing depends on the test
/// machine's zone.
final _now = DateTime(2026, 10, 15, 14, 30);

/// Two compose projects, a container in none, a Swarm task and a
/// container that never started (CTR-01, CTR-04).
final _containers = [
  dockerContainer(
    'a1f3c2e4b5d6',
    name: 'web-frontend',
    project: 'web',
    status: 'Up 3 hours (healthy)',
    health: HealthStatus.healthy,
    ports: const [
      ContainerPort(ip: '0.0.0.0', privatePort: 80, publicPort: 8080),
      ContainerPort(ip: '::', privatePort: 80, publicPort: 8080),
    ],
  ),
  dockerContainer(
    'b7e9d0c1a2f3',
    name: 'web-db',
    project: 'web',
    image: 'postgres:16',
    status: 'Up 3 days (unhealthy)',
    health: HealthStatus.unhealthy,
    ports: const [ContainerPort(privatePort: 5432, type: 'tcp')],
  ),
  dockerContainer(
    'c4d5e6f7a8b9',
    name: 'web-worker',
    project: 'web',
    image: 'myorg/worker:5',
    state: 'exited',
    status: 'Exited (137) 2 hours ago',
  ),
  dockerContainer(
    'd0e1f2a3b4c5',
    name: 'grafana',
    project: 'monitoring',
    image: 'grafana/grafana:11.3.0',
    status: 'Up About an hour',
  ),
  dockerContainer(
    'e6f7a8b9c0d1',
    name: 'prometheus',
    project: 'monitoring',
    image: 'prom/prometheus:v3.0.0',
    status: 'Up 5 minutes (health: starting)',
    health: HealthStatus.starting,
  ),
  dockerContainer(
    'f2a3b4c5d6e7',
    name: 'portainer',
    image: 'portainer/portainer-ce:2.24',
    status: 'Up 2 weeks',
  ),
  dockerContainer(
    '0a1b2c3d4e5f',
    name: 'api.1.k2x9q4m7z1p3v8n5c6b0w2r4t',
    image: 'myorg/api:2',
    status: 'Up 4 days',
  ),
  dockerContainer(
    '9f8e7d6c5b4a',
    name: 'hello',
    image: 'hello-world',
    state: 'created',
    status: 'Created',
  ),
];

/// Each running container's figures, read at [at].
List<ContainerListStats> _stats(DateTime at) => [
  for (final (id, cpu, memory) in [
    ('a1f3c2e4b5d6', 2.5, 48 * _mib),
    ('b7e9d0c1a2f3', 12.5, 512 * _mib),
    ('d0e1f2a3b4c5', 0.8, 96 * _mib),
    ('e6f7a8b9c0d1', 31.0, 300 * _mib),
    ('f2a3b4c5d6e7', 0.1, 20 * _mib),
    // A first round reads no CPU share yet (03 §5.6).
    ('0a1b2c3d4e5f', null, 64 * _mib),
  ])
    ContainerListStats(
      containerId: id,
      at: at,
      cpuPercent: cpu,
      memoryUsed: memory,
      memoryLimit: 2048 * _mib,
    ),
];

/// The containers' names by id, so orders read as names.
final _names = {
  for (final container in _containers) container.id: container.name!,
};

/// What the monitoring clock reads; tests move it.
late DateTime _clock;

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

  /// Delivers [containers] and, unless null, a stats round [statsAt].
  Future<void> list(
    WidgetTester tester, {
    List<ContainerSummary>? containers,
    DateTime? statsAt,
  }) async {
    await emit(
      tester,
      dockerContainerList(_serverId, containers ?? _containers, at: _now),
    );
    if (statsAt != null) {
      await emit(
        tester,
        dockerStatsRound(_serverId, _stats(statsAt), at: _now),
      );
    }
  }

  /// Lets the rows on screen settle and reach the watch.
  Future<void> settle(WidgetTester tester) async {
    await tester.pump(kStatsForSettle);
    await tester.pumpAndSettle();
  }
}

Future<_Panel> _pump(
  WidgetTester tester, {
  Size size = _wide,
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.linux,
  double textScale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  _clock = _now;
  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine, now: () => _clock);
  final visible = ValueNotifier(true);
  addTearDown(() async {
    monitoring.dispose();
    visible.dispose();
    await engine.close();
  });

  final base = brightness == Brightness.light
      ? GhostTheme.light(klabautermannThemeStyle, platform: platform)
      : GhostTheme.dark(klabautermannThemeStyle, platform: platform);
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: goldenFontFamily),
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: MediaQuery.withClampedTextScaling(
        minScaleFactor: textScale,
        maxScaleFactor: textScale,
        child: Scaffold(
          body: RepaintBoundary(
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: ValueListenableBuilder(
                valueListenable: visible,
                builder: (context, shows, _) => ContainersPanel(
                  monitoring: monitoring,
                  serverId: _serverId,
                  visible: shows,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine, visible);
}

const _prefix = 'containers.row.';

/// The rows the panel shows, top to bottom: a container by name, a
/// heading as `group.<project>`.
List<String> _order(WidgetTester tester) {
  final rows = [
    for (final element in find.byType(Semantics).evaluate())
      if (element.widget.key case ValueKey<String>(
        :final value,
      ) when value.startsWith(_prefix))
        (
          key: value.substring(_prefix.length),
          top: tester.getTopLeft(find.byWidget(element.widget)).dy,
        ),
  ]..sort((a, b) => a.top.compareTo(b.top));
  return [for (final row in rows) _names[row.key] ?? row.key];
}

Finder _header(String column) =>
    find.byKey(ValueKey('containers.column.$column'));

Finder _heading(String project) =>
    find.byKey(ValueKey('containers.row.group.$project'));

/// 03 §10.4's Containers sub-tab (CTR-01, CTR-04, CST-01) over the
/// container watch.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  testWidgets('watches while it shows and reads nothing hidden', (
    tester,
  ) async {
    final panel = await _pump(tester);
    expect(panel.watches, hasLength(1));
    expect(panel.watches.single.lists, {
      DockerWatchList.containers,
      DockerWatchList.stats,
    });
    expect(find.text('Reading the containers…'), findsOneWidget);

    panel.visible.value = false;
    await tester.pumpAndSettle();
    expect(panel.unwatches.single.watchId, panel.watches.single.watchId);

    panel.visible.value = true;
    await tester.pumpAndSettle();
    expect(panel.watches, hasLength(2));
    expect(panel.watches.last.watchId, isNot(panel.watches.first.watchId));
  });

  testWidgets('groups by compose project, with the rest last', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, statsAt: _now);
    expect(_order(tester), [
      'group.monitoring',
      'grafana',
      'prometheus',
      'group.web',
      'web-db',
      'web-frontend',
      'web-worker',
      'group.',
      'api.1.k2x9q4m7z1p3v8n5c6b0w2r4t',
      'hello',
      'portainer',
    ]);
    expect(find.text('Not in a stack'), findsOneWidget);
    expect(find.text('2 containers, 2 running'), findsOneWidget);
    expect(find.text('3 containers, 2 running'), findsNWidgets(2));

    // Without a project, no headings.
    await panel.list(tester, containers: _containers.sublist(5));
    expect(_order(tester), [
      'api.1.k2x9q4m7z1p3v8n5c6b0w2r4t',
      'hello',
      'portainer',
    ]);
  });

  testWidgets('shows each column in words: state, health, status, ports, '
      'stack and the figures', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, statsAt: _now);

    for (final text in [
      'Running',
      'Exited',
      'Created',
      'Healthy',
      'Unhealthy',
      'Starting',
      // The health marker moves to its column.
      'Up 3 hours',
      'Exited (137) 2 hours ago',
      // IPv4's and IPv6's binding of one port read once.
      '8080->80/tcp',
      '5432/tcp',
      'api (Swarm)',
      '12.5%',
      '512 MiB',
    ]) {
      expect(find.text(text), findsWidgets, reason: text);
    }
    expect(find.text('Up 3 hours (healthy)'), findsNothing);

    // Each row reads as its cells (A11Y-03); a stopped container has no
    // figures, a first round no CPU share yet.
    expect(
      find.bySemanticsLabel(
        RegExp(r'^Name: web-db\nState: Running\nHealth: Unhealthy\n'),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(
        RegExp(r'Name: api\.1\..*\nCPU: unknown\n', dotAll: true),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Name: web-worker\n.*CPU:', dotAll: true)),
      findsNothing,
    );
  });

  testWidgets('sorts within each group, the busiest first by CPU', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.list(tester, statsAt: _now);

    await tester.tap(_header(ContainerColumn.cpu.name));
    await tester.pumpAndSettle();
    expect(_order(tester), [
      'group.monitoring',
      'prometheus',
      'grafana',
      'group.web',
      'web-db',
      'web-frontend',
      // Nothing to measure sorts last.
      'web-worker',
      'group.',
      'portainer',
      'api.1.k2x9q4m7z1p3v8n5c6b0w2r4t',
      'hello',
    ]);

    // Uptime by the duration the status names: the newest first.
    await tester.tap(_header(ContainerColumn.status.name));
    await tester.pumpAndSettle();
    expect(_order(tester), [
      'group.monitoring',
      'prometheus',
      'grafana',
      'group.web',
      'web-frontend',
      'web-db',
      'web-worker',
      'group.',
      'api.1.k2x9q4m7z1p3v8n5c6b0w2r4t',
      'portainer',
      'hello',
    ]);

    await tester.tap(_header(ContainerColumn.health.name));
    await tester.pumpAndSettle();
    expect(_order(tester).sublist(1, 3), ['prometheus', 'grafana']);
    expect(_order(tester).sublist(4, 7), [
      'web-db',
      'web-frontend',
      'web-worker',
    ]);
  });

  testWidgets('a heading folds its group and opens it again', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, statsAt: _now);

    await tester.tap(_heading('web'));
    await tester.pumpAndSettle();
    expect(_order(tester), [
      'group.monitoring',
      'grafana',
      'prometheus',
      'group.web',
      'group.',
      'api.1.k2x9q4m7z1p3v8n5c6b0w2r4t',
      'hello',
      'portainer',
    ]);
    expect(
      tester.getSemantics(_heading('web')),
      isSemantics(
        label: 'web',
        value: '3 containers, 2 running',
        hasExpandedState: true,
        isExpanded: false,
        isButton: true,
        hasTapAction: true,
      ),
    );

    // A search shows every match, folded or not.
    await tester.enterText(find.byType(TextField), 'worker');
    await tester.pumpAndSettle();
    expect(_order(tester), ['group.web', 'web-worker']);

    await tester.enterText(find.byType(TextField), '');
    await tester.pumpAndSettle();
    await tester.tap(_heading('web'));
    await tester.pumpAndSettle();
    expect(_order(tester), contains('web-db'));
  });

  testWidgets('running only hides the stopped containers', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, statsAt: _now);

    await tester.tap(find.text('Running only'));
    await tester.pumpAndSettle();
    expect(_order(tester), [
      'group.monitoring',
      'grafana',
      'prometheus',
      'group.web',
      'web-db',
      'web-frontend',
      'group.',
      'api.1.k2x9q4m7z1p3v8n5c6b0w2r4t',
      'portainer',
    ]);
    expect(find.text('2 containers, 2 running'), findsNWidgets(3));

    await panel.list(tester, containers: [_containers[2], _containers[7]]);
    expect(_order(tester), isEmpty);
    expect(
      find.text(
        'No container is running. Turn off Running only to see the stopped '
        'ones.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('searches by name, image and ID', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, statsAt: _now);

    for (final (query, order) in [
      ('graf', ['group.monitoring', 'grafana']),
      ('POSTGRES', ['group.web', 'web-db']),
      // An id, not a name.
      ('9f8e7d', ['group.', 'hello']),
      // Every term has to match.
      ('web nginx', ['group.web', 'web-frontend']),
    ]) {
      await tester.enterText(find.byType(TextField), query);
      await tester.pumpAndSettle();
      expect(_order(tester), order, reason: query);
    }

    await tester.enterText(find.byType(TextField), 'nothing-like-this');
    await tester.pumpAndSettle();
    expect(_order(tester), isEmpty);
    expect(find.text('No container matches the search.'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(_order(tester), hasLength(11));
  });

  testWidgets('stats turn grey beside a history icon once stale, and say '
      'so', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, statsAt: _now);
    expect(find.byIcon(Icons.history), findsNothing);

    _clock = _now.add(const Duration(seconds: 25));
    await tester.pump(const Duration(seconds: 1));
    final figure = find.text('512 MiB');
    expect(
      tester.widget<Text>(figure).style?.color,
      Theme.of(tester.element(figure)).colorScheme.onSurfaceVariant,
    );
    expect(find.byIcon(Icons.history), findsWidgets);
    expect(
      find.bySemanticsLabel(
        RegExp(r'Name: web-db\n.*CPU: 12\.5%, stale\n', dotAll: true),
      ),
      findsOneWidget,
    );

    // A fresh round for one row; the others stay old.
    await panel.emit(
      tester,
      dockerStatsRound(_serverId, [
        ContainerListStats(
          containerId: 'b7e9d0c1a2f3',
          at: _clock,
          cpuPercent: 14,
          memoryUsed: 520 * _mib,
        ),
      ], at: _clock),
    );
    final fresh = find.text('520 MiB');
    expect(
      tester.widget<Text>(fresh).style?.color,
      isNot(Theme.of(tester.element(fresh)).colorScheme.onSurfaceVariant),
    );
    expect(
      find.bySemanticsLabel(
        RegExp(r'Name: web-db\n.*CPU: 14\.0%\nMemory: 520 MiB$', dotAll: true),
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'Name: grafana\n.*, stale$', dotAll: true)),
      findsOneWidget,
    );
  });

  testWidgets('the watch reads stats for the running rows on screen, under '
      'one id as they change', (tester) async {
    final panel = await _pump(tester);
    final many = [
      for (var i = 0; i < 60; i++)
        dockerContainer(
          'c${i.toString().padLeft(2, '0')}',
          state: i == 1 ? 'exited' : 'running',
        ),
    ];
    _names.addAll({for (final c in many) c.id: c.id});
    await panel.list(tester, containers: many);
    await panel.settle(tester);

    final first = panel.watches.last;
    expect(first.watchId, panel.watches.first.watchId);
    expect(first.statsFor, containsAll(['c00', 'c02']));
    expect(first.statsFor, isNot(contains('c01')), reason: 'not running');
    expect(first.statsFor, isNot(contains('c59')), reason: 'off screen');
    expect(_order(tester), containsAll(first.statsFor));

    await tester.drag(find.text('c05'), const Offset(0, -300));
    await tester.pumpAndSettle();
    await panel.settle(tester);
    final scrolled = panel.watches.last;
    expect(scrolled.watchId, first.watchId);
    expect(scrolled.statsFor, isNot(contains('c00')));
    expect(scrolled.statsFor, isNotEmpty);
    expect(_order(tester), containsAll(scrolled.statsFor));

    // Holding still sends nothing more.
    final sent = panel.watches.length;
    await panel.settle(tester);
    expect(panel.watches, hasLength(sent));

    // A watch that starts again reads them at once.
    panel.visible.value = false;
    await tester.pumpAndSettle();
    panel.visible.value = true;
    await tester.pumpAndSettle();
    expect(panel.watches.last.watchId, isNot(first.watchId));
    expect(panel.watches.last.statsFor, scrolled.statsFor);
  });

  testWidgets('says why the list failed, keeps the last one and watches '
      'anew on retry', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.containers,
        DockerQueryFailure.daemonError,
        at: _now,
        detail: 'Error response from daemon: client version too old',
      ),
    );
    expect(
      find.text('The engine refused or failed to list the containers.'),
      findsOneWidget,
    );
    expect(
      find.text('Error response from daemon: client version too old'),
      findsOneWidget,
    );
    expect(find.text('Reading the containers…'), findsNothing);

    final before = panel.watches.last.watchId;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(panel.unwatches.single.watchId, before);
    expect(panel.watches.last.watchId, isNot(before));

    await panel.list(tester, statsAt: _now);
    expect(find.text('Try again'), findsNothing);
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.containers,
        DockerQueryFailure.connectionFailed,
        at: _now,
      ),
    );
    expect(
      find.text(
        'The connection to the engine failed while listing the containers.',
      ),
      findsOneWidget,
    );
    expect(find.text('The list below is the last one read.'), findsOneWidget);
    expect(_order(tester), hasLength(11));

    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.stats,
        DockerQueryFailure.connectionFailed,
        at: _now,
      ),
    );
    expect(
      find.text(
        'The CPU and memory figures could not be read, so the ones shown may '
        'be old.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a refused watch and an empty engine say so', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.containers,
        DockerQueryFailure.tooManyQueries,
        at: _now,
      ),
    );
    expect(
      find.text(
        'This server already has as many Docker watches open as Klabautermann '
        'allows.',
      ),
      findsOneWidget,
    );

    await panel.list(tester, containers: const []);
    expect(find.text('This engine has no containers.'), findsOneWidget);
  });

  testWidgets('names low-session mode for the route it holds on', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    expect(find.textContaining('Low-session mode'), findsNothing);

    await panel.emit(tester, dockerReady(_serverId, lowSession: true));
    expect(
      find.text(
        'Low-session mode: stats are read one container at a time, so they '
        'update more slowly.',
      ),
      findsOneWidget,
    );

    await panel.emit(
      tester,
      dockerReady(_serverId, rank: DockerRank.cliRelay, lowSession: true),
    );
    expect(
      find.text(
        'Low-session mode: the list is read again every 15 seconds instead '
        'of following engine events, and stats are read one container at a '
        'time.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a phone lists two-line rows with a sort menu, folds headings '
      'and reports the rows it built', (tester) async {
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.list(tester, statsAt: _now);
    expect(find.byType(SortableTable<ContainerListEntry>), findsNothing);
    expect(find.text('Sort by'), findsOneWidget);
    expect(find.text('Image: postgres:16'), findsOneWidget);
    expect(_order(tester).take(3), [
      'group.monitoring',
      'grafana',
      'prometheus',
    ]);

    await panel.settle(tester);
    expect(
      panel.watches.last.statsFor,
      containsAll(['d0e1f2a3b4c5', 'b7e9d0c1a2f3']),
    );
    expect(
      panel.watches.last.statsFor,
      isNot(contains('c4d5e6f7a8b9')),
      reason: 'a stopped container has no stats',
    );

    await tester.tap(_heading('monitoring'));
    await tester.pumpAndSettle();
    expect(_order(tester).take(2), ['group.monitoring', 'group.web']);
    await panel.settle(tester);
    expect(panel.watches.last.statsFor, isNot(contains('d0e1f2a3b4c5')));

    // The busiest first.
    await tester.tap(find.text('Name').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('CPU').last);
    await tester.pumpAndSettle();
    expect(_order(tester).sublist(1, 4), [
      'group.web',
      'web-db',
      'web-frontend',
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('at twice the text size a desktop panel takes the two-line '
      'rows rather than a squeezed table', (tester) async {
    final panel = await _pump(tester, textScale: 2);
    await panel.list(tester, statsAt: _now);
    expect(find.byType(SortableTable<ContainerListEntry>), findsNothing);
    expect(find.text('Image: postgres:16'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.containers,
        DockerQueryFailure.connectionFailed,
        at: _now,
        detail: 'read: connection reset by peer',
      ),
    );
    expect(tester.takeException(), isNull);
  });

  group('golden', () {
    // 03 §11.1: grouped containers with health badges, a Swarm task, a
    // first stats round, stale stats and a stopped container, on desktop.
    for (final brightness in Brightness.values) {
      testWidgets('desktop, ${brightness.name}', (tester) async {
        final panel = await _pump(tester, brightness: brightness);
        await panel.list(
          tester,
          statsAt: _now.subtract(const Duration(seconds: 30)),
        );
        // A fresh round for the rows on screen of one group; the rest
        // are stale.
        await panel.emit(
          tester,
          dockerStatsRound(_serverId, [
            for (final row in _stats(_now))
              if (row.containerId == 'b7e9d0c1a2f3' ||
                  row.containerId == 'a1f3c2e4b5d6')
                row,
          ], at: _now),
        );
        await expectLater(
          find.byType(ContainersPanel),
          matchesGoldenFile(
            'goldens/containers_panel_desktop_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
