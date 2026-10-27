import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/docker/container_details.dart'
    show ContainerDetailsPage;
import 'package:klabautermann_app/ui/docker/stacks_panel.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';

const _wide = Size(1000, 640);
const _phone = Size(390, 900);

/// When the lists are read; local, so nothing depends on the test
/// machine's zone.
final _now = DateTime(2026, 10, 15, 14, 30);

/// A label that marks [manager]'s ownership.
Ownership _owned(ExternalManager manager, String label) =>
    Ownership([OwnershipMarker(manager: manager, label: label, value: 'true')]);

/// Five stacks, one per verdict: a blog Dockge deployed from inside its
/// own container, a Coolify-managed API, metrics whose files changed, a
/// queue still being checked and a verified web stack with an unhealthy
/// database and published ports.
final _stacks = [
  dockerStack(
    'blog',
    [
      dockerService('ghost', [
        dockerContainer('b1', name: 'blog-ghost-1', image: 'ghost:5'),
      ]),
    ],
    ownership: _owned(ExternalManager.dockge, 'dockge.stack'),
    workingDir: '/opt/stacks/blog',
    configFiles: ['/opt/stacks/blog/compose.yaml'],
  ),
  dockerStack('coolify-api', [
    dockerService('api', [
      dockerContainer('c1', name: 'coolify-api-1', image: 'myorg/api:3'),
    ]),
  ], ownership: _owned(ExternalManager.coolify, 'coolify.managed')),
  dockerStack('metrics', [
    dockerService('prometheus', [
      dockerContainer('m1', name: 'metrics-prometheus-1', image: 'prom:3'),
    ]),
    dockerService('grafana', [
      dockerContainer(
        'm2',
        name: 'metrics-grafana-1',
        image: 'grafana:11',
        state: 'exited',
      ),
    ]),
  ]),
  dockerStack('queue', [
    dockerService('redis', [
      dockerContainer('q1', name: 'queue-redis-1', image: 'redis:7'),
    ]),
  ]),
  dockerStack(
    'web',
    [
      dockerService('app', [
        dockerContainer(
          'w1',
          name: 'web-app-1',
          image: 'nginx:1.27',
          health: HealthStatus.healthy,
          ports: const [
            ContainerPort(
              privatePort: 80,
              publicPort: 8080,
              type: 'tcp',
              ip: '0.0.0.0',
            ),
          ],
        ),
        dockerContainer(
          'w2',
          name: 'web-app-2',
          image: 'nginx:1.27',
          health: HealthStatus.healthy,
        ),
      ]),
      dockerService('db', [
        dockerContainer(
          'w3',
          name: 'web-db-1',
          image: 'postgres:16',
          health: HealthStatus.unhealthy,
        ),
      ]),
      dockerService('migrate', [
        dockerContainer(
          'w4',
          name: 'web-migrate-run-1',
          image: 'myorg/web:5',
          state: 'exited',
        ),
      ], oneOff: true),
    ],
    environmentFiles: ['/srv/web/.env'],
  ),
];

const _verdicts = <String, StackVerdict>{
  'blog': StackSourceNotOnHost(deployedBy: ExternalManager.dockge),
  'coolify-api': StackVerified(),
  'metrics': StackUnverified(StackUnverifiedReason.hashMismatch),
  'web': StackVerified(),
};

const _cli = DockerComposeCli(
  pluginVersion: '2.29.7',
  standaloneVersion: '1.29.2',
);

final class _Panel {
  _Panel(this.engine, this.visible, this.request);

  final FakeEngineClient engine;
  final ValueNotifier<bool> visible;

  /// The palette's stack request the panel is built with.
  final ValueNotifier<StackRequest?> request;

  List<DockerWatch> get watches => engine.sentOfType<DockerWatch>().cast();
  List<DockerUnwatch> get unwatches =>
      engine.sentOfType<DockerUnwatch>().cast();

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  /// Delivers [stacks] with [verdicts] and [cli].
  Future<void> list(
    WidgetTester tester, {
    List<ComposeProject>? stacks,
    Map<String, StackVerdict> verdicts = _verdicts,
    DockerComposeCli? cli = _cli,
  }) => emit(
    tester,
    dockerStackList(
      _serverId,
      stacks ?? _stacks,
      at: _now,
      verdicts: verdicts,
      cli: cli,
    ),
  );
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

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine, now: () => _now);
  final visible = ValueNotifier(true);
  final request = ValueNotifier<StackRequest?>(null);
  addTearDown(() async {
    monitoring.dispose();
    visible.dispose();
    request.dispose();
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
              child: ListenableBuilder(
                listenable: Listenable.merge([visible, request]),
                builder: (context, _) => StacksPanel(
                  monitoring: monitoring,
                  serverId: _serverId,
                  visible: visible.value,
                  request: request.value,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Panel(engine, visible, request);
}

Finder _row(String name) => find.byKey(ValueKey('stacks.row.$name'));

Finder _inRow(String name, Finder finder) =>
    find.descendant(of: _row(name), matching: finder);

/// The stack list's scrollable, apart from the header's and the
/// overview's.
Finder _listScrollable() => find
    .ancestor(
      of: find.byWidgetPredicate(
        (widget) => switch (widget.key) {
          ValueKey<String>(:final value) => value.startsWith('stacks.row.'),
          _ => false,
        },
      ),
      matching: find.byType(Scrollable),
    )
    .first;

Finder _inOverview(Finder finder) =>
    find.descendant(of: find.byType(StackOverview), matching: finder);

/// 03 §10.4's Stacks sub-tab (STK-01, STK-02, STK-05, STK-10) over the
/// stack watch.
void main() {
  setUpAll(() async {
    if (goldensCompareHere) await loadGoldenFonts();
  });

  testWidgets('watches the stacks alone while it shows, and nothing '
      'hidden, since a watch runs compose checks on the host', (tester) async {
    final panel = await _pump(tester);
    expect(panel.watches, hasLength(1));
    expect(panel.watches.single.lists, {DockerWatchList.stacks});
    expect(panel.watches.single.statsFor, isEmpty);
    expect(find.text('Reading the stacks…'), findsOneWidget);

    panel.visible.value = false;
    await tester.pumpAndSettle();
    expect(panel.unwatches.single.watchId, panel.watches.single.watchId);

    panel.visible.value = true;
    await tester.pumpAndSettle();
    expect(panel.watches, hasLength(2));
    expect(panel.watches.last.watchId, isNot(panel.watches.first.watchId));
  });

  testWidgets('lists each stack with its verdict chip, managed-by badge '
      'and counts', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester);

    for (final (name, chip) in [
      ('blog', 'Source not on host (deployed by Dockge)'),
      ('coolify-api', 'Verified source'),
      ('metrics', 'Unverified source: the files changed since the deploy'),
      ('queue', 'Checking source…'),
      ('web', 'Verified source'),
    ]) {
      expect(_inRow(name, find.text(chip)), findsOneWidget, reason: name);
    }
    expect(
      _inRow('blog', find.text('Managed by Dockge: read-only')),
      findsOneWidget,
    );
    expect(
      _inRow('coolify-api', find.text('Managed by Coolify: read-only')),
      findsOneWidget,
    );
    expect(_inRow('web', find.textContaining('Managed by')), findsNothing);
    expect(_inRow('web', find.text('3 services')), findsOneWidget);
    expect(_inRow('web', find.text('3 of 4 running')), findsOneWidget);
    expect(_inRow('web', find.text('1 unhealthy')), findsOneWidget);
    expect(_inRow('metrics', find.text('1 of 2 running')), findsOneWidget);
    expect(_inRow('metrics', find.textContaining('unhealthy')), findsNothing);
    expect(_inRow('queue', find.text('1 service')), findsOneWidget);
  });

  testWidgets('names every reason a source is unverified', (tester) async {
    final panel = await _pump(tester);
    final reasons = {
      StackUnverifiedReason.noSourceLabels: 'no compose files recorded',
      StackUnverifiedReason.unsafeLabels: 'unsafe names in the labels',
      StackUnverifiedReason.noHashLabels: 'a service has no config hash',
      StackUnverifiedReason.noComposeCli: 'no compose CLI',
      StackUnverifiedReason.standaloneComposeOnly:
          'standalone docker-compose only',
      StackUnverifiedReason.cliCouldNotHash: 'the compose CLI cannot hash',
      StackUnverifiedReason.configFailed: 'compose config failed',
      StackUnverifiedReason.hashMismatch: 'the files changed since the deploy',
      StackUnverifiedReason.checkFailed: 'the check could not run',
    };
    expect(reasons.keys, StackUnverifiedReason.values);
    final stacks = [
      for (final reason in reasons.keys)
        dockerStack(reason.name, [
          dockerService('app', [dockerContainer('${reason.name}-1')]),
        ]),
    ];
    await panel.list(
      tester,
      stacks: stacks,
      verdicts: {
        for (final reason in reasons.keys) reason.name: StackUnverified(reason),
      },
    );
    for (final MapEntry(key: reason, value: words) in reasons.entries) {
      await tester.scrollUntilVisible(
        _row(reason.name),
        100,
        scrollable: _listScrollable(),
      );
      expect(
        _inRow(reason.name, find.text('Unverified source: $words')),
        findsOneWidget,
        reason: reason.name,
      );
    }

    // A manager's paths the containers name, without a mark of which.
    await panel.list(
      tester,
      stacks: [stacks.first],
      verdicts: {stacks.first.name: const StackSourceNotOnHost()},
    );
    expect(find.text('Source not on host'), findsWidgets);
  });

  testWidgets('a project is checking until the engine sends its verdict '
      'again', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester, verdicts: const {}, cli: null);
    expect(find.text('Checking source…'), findsNWidgets(5 + 1));
    expect(find.textContaining('Compose CLI'), findsNothing);

    await panel.list(tester);
    expect(_inRow('queue', find.text('Checking source…')), findsOneWidget);
    expect(_inRow('web', find.text('Verified source')), findsOneWidget);
    expect(
      find.text(
        'Klabautermann is checking the compose files on the host against the '
        'running containers.',
      ),
      findsNothing,
      reason: 'the overview shows blog, which is checked',
    );
  });

  testWidgets('names the compose CLIs found, the standalone one read-only '
      '(STK-05)', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    expect(find.text('Compose CLI'), findsOneWidget);
    expect(find.text('Docker Compose 2.29.7'), findsOneWidget);
    expect(
      find.text('docker-compose 1.29.2 (Compose v1, unmaintained): read-only'),
      findsOneWidget,
    );

    await panel.list(
      tester,
      cli: const DockerComposeCli(standaloneVersion: '2.20.3'),
    );
    expect(find.textContaining('Docker Compose'), findsNothing);
    expect(
      find.text('docker-compose 2.20.3 (standalone): read-only'),
      findsOneWidget,
    );

    await panel.list(tester, cli: const DockerComposeCli());
    expect(
      find.text('None found, so no stack\'s source can be verified.'),
      findsOneWidget,
    );
  });

  testWidgets('shows the first stack\'s overview beside the list, and the '
      'one selected (STK-02)', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    expect(_inOverview(find.text('blog')), findsOneWidget);
    expect(
      _inOverview(
        find.text(
          'A compose file the containers name is not on the host. A manager '
          'that runs compose in its own container records paths inside that '
          'container.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      _inOverview(
        find.text(
          'Changes made outside Dockge can be overwritten by it, so '
          'Klabautermann treats this stack as read-only. The label '
          'dockge.stack marks it.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      _inOverview(find.text('/opt/stacks/blog/compose.yaml')),
      findsOneWidget,
    );

    await tester.tap(_row('web'));
    await tester.pumpAndSettle();
    final selected = tester.getSemantics(_row('web'));
    expect(selected.flagsCollection.isSelected, Tristate.isTrue);
    expect(selected.label, startsWith('web\n'));
    expect(
      tester.getSemantics(_row('blog')).flagsCollection.isSelected,
      Tristate.isFalse,
    );
    for (final text in [
      'web',
      'Verified source',
      'The compose files on the host are the ones these containers were '
          'deployed from.',
      'Source',
      'Working directory',
      '/srv/web',
      'Compose files',
      '/srv/web/compose.yaml',
      'Environment files',
      '/srv/web/.env',
      'Deployed with Compose',
      '2.29.7',
      'Services',
      'app',
      'nginx:1.27',
      'web-app-1',
      'web-app-2',
      'db',
      'postgres:16',
      'web-db-1',
      'migrate',
      'one-off',
      'web-migrate-run-1',
      'Ports 8080->80/tcp',
      'Exited',
      'Exited (0) 1 day ago',
    ]) {
      expect(_inOverview(find.text(text)), findsWidgets, reason: text);
    }
    expect(_inOverview(find.text('Running')), findsNWidgets(3));
    expect(_inOverview(find.text('Healthy')), findsNWidgets(2));
    expect(_inOverview(find.text('Unhealthy')), findsOneWidget);
    expect(_inOverview(find.textContaining('Managed by')), findsNothing);
  });

  testWidgets('a container in the overview opens its details', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    await tester.tap(_row('web'));
    await tester.pumpAndSettle();

    await tester.ensureVisible(_inOverview(find.text('web-db-1')));
    await tester.pumpAndSettle();
    await tester.tap(_inOverview(find.text('web-db-1')));
    await tester.pumpAndSettle();
    expect(find.byType(ContainerDetailsPage), findsOneWidget);
    final inspect = panel.engine.sentOfType<DockerQuery>().cast<DockerQuery>();
    expect(
      inspect.map((query) => query.query),
      contains(
        isA<DockerContainerQuery>().having((q) => q.containerId, 'id', 'w3'),
      ),
    );
  });

  testWidgets('says why the list failed, keeps the last one and watches '
      'anew on retry', (tester) async {
    final panel = await _pump(tester);
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.stacks,
        DockerQueryFailure.daemonError,
        at: _now,
        detail: 'Error response from daemon: client version too old',
      ),
    );
    expect(
      find.text(
        'The engine refused or failed to list the containers the stacks are '
        'read from.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('Error response from daemon: client version too old'),
      findsOneWidget,
    );
    expect(find.text('Reading the stacks…'), findsNothing);

    final before = panel.watches.last.watchId;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(panel.unwatches.single.watchId, before);
    expect(panel.watches.last.watchId, isNot(before));
    expect(panel.watches.last.lists, {DockerWatchList.stacks});

    await panel.list(tester);
    expect(find.text('Try again'), findsNothing);
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.stacks,
        DockerQueryFailure.connectionFailed,
        at: _now,
      ),
    );
    expect(
      find.text(
        'The connection to the engine failed while listing the stacks.',
      ),
      findsOneWidget,
    );
    expect(find.text('The list below is the last one read.'), findsOneWidget);
    expect(_row('web'), findsOneWidget);
  });

  testWidgets('a refused watch and an engine without stacks say so', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.emit(
      tester,
      dockerListFailed(
        _serverId,
        DockerWatchList.stacks,
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

    await panel.list(tester, stacks: const [], verdicts: const {});
    expect(find.text('This engine runs no compose stacks.'), findsOneWidget);
    expect(find.byType(StackOverview), findsNothing);
  });

  testWidgets('names low-session mode on a relay, where the list polls', (
    tester,
  ) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    await panel.emit(tester, dockerReady(_serverId, lowSession: true));
    expect(
      find.textContaining('Low-session mode'),
      findsNothing,
      reason: 'the socket forward follows events at no session cost',
    );

    await panel.emit(
      tester,
      dockerReady(_serverId, rank: DockerRank.cliRelay, lowSession: true),
    );
    expect(
      find.text(
        'Low-session mode: the stacks are read again every 15 seconds instead '
        'of following engine events.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a phone lists the stacks, and a stack opens its overview on '
      'a page that follows the list', (tester) async {
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.list(tester);
    expect(find.byType(StackOverview), findsNothing);
    final row = tester.getSemantics(_row('web'));
    expect(row.hint, 'Show the stack\'s overview');
    expect(row.flagsCollection.isButton, isTrue);

    await tester.scrollUntilVisible(
      _row('web'),
      100,
      scrollable: _listScrollable(),
    );
    await tester.tap(_row('web'));
    await tester.pumpAndSettle();
    expect(find.byType(StackOverviewPage), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('web')),
      findsOneWidget,
    );
    expect(_inOverview(find.text('web-db-1')), findsOneWidget);
    expect(panel.unwatches, isEmpty, reason: 'the sub-tab keeps the watch');

    await panel.list(tester, stacks: _stacks.take(4).toList());
    expect(
      _inOverview(find.text('This stack has no containers any more.')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a palette request selects its stack, again after another '
      'was chosen (PLT-07)', (tester) async {
    final panel = await _pump(tester);
    await panel.list(tester);
    panel.request.value = (project: 'metrics', serial: 1);
    await tester.pumpAndSettle();
    expect(_inOverview(find.text('metrics')), findsOneWidget);

    await tester.tap(_row('blog'));
    await tester.pumpAndSettle();
    expect(_inOverview(find.text('blog')), findsOneWidget);

    // The same stack asked for again: only the serial tells it apart.
    panel.request.value = (project: 'metrics', serial: 2);
    await tester.pumpAndSettle();
    expect(_inOverview(find.text('metrics')), findsOneWidget);
  });

  testWidgets('a palette request opens its stack on a page of its own on a '
      'phone (PLT-07)', (tester) async {
    final panel = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
    );
    await panel.list(tester);
    panel.request.value = (project: 'metrics', serial: 1);
    await tester.pumpAndSettle();
    expect(find.byType(StackOverviewPage), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('metrics')),
      findsOneWidget,
    );
  });

  testWidgets('at twice the text size a desktop panel lists the stacks '
      'alone rather than squeezing the overview beside them', (tester) async {
    final panel = await _pump(tester, textScale: 2);
    await panel.list(tester);
    expect(find.byType(StackOverview), findsNothing);
    expect(_row('blog'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  group('golden', () {
    // 03 §11.1: a verdict of each kind, managed-by badges, the CLI line
    // and a verified stack's overview, on desktop.
    for (final brightness in Brightness.values) {
      testWidgets('desktop, ${brightness.name}', (tester) async {
        final panel = await _pump(tester, brightness: brightness);
        await panel.list(tester);
        await tester.tap(_row('web'));
        await tester.pumpAndSettle();
        await expectLater(
          find.byType(StacksPanel),
          matchesGoldenFile(
            'goldens/stacks_panel_desktop_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
