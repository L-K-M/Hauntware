import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_fonts/testing.dart' show loadBundledMonoFonts;
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/services/hand_off.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/docker/container_details.dart';
import 'package:klabautermann_app/ui/docker/container_details_view.dart';
import 'package:klabautermann_app/ui/docker/containers_panel.dart';
import 'package:klabautermann_app/ui/hand_off_actions.dart' show HandOffScope;
import 'package:klabautermann_app/ui/processes_panel.dart' show kRevealDuration;
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart'
    show goldenFontFamily, goldensCompareHere, loadGoldenFonts;
import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
const _id = 'b7e9d0c1a2f3';

/// Tall enough that the inspector builds every section.
const _desktop = Size(1000, 3200);

/// A desktop window's height, for the goldens.
const _window = Size(1000, 900);
const _phone = Size(390, 900);

final _now = DateTime(2026, 10, 15, 14, 30);

/// The container's row as the list delivers it.
final _row = dockerContainer(
  _id,
  name: 'web-db',
  project: 'web',
  image: 'postgres:16',
  status: 'Up 3 hours (unhealthy)',
  health: HealthStatus.unhealthy,
  ports: const [ContainerPort(privatePort: 5432, type: 'tcp')],
);

final class _Harness {
  _Harness(this.engine, this.inspection);

  final FakeEngineClient engine;
  final ValueNotifier<InspectedContainer?> inspection;

  List<DockerQuery> get inspects => [
    for (final query in engine.sentOfType<DockerQuery>().cast<DockerQuery>())
      if (query.query is DockerContainerQuery) query,
  ];

  Future<void> emit(WidgetTester tester, EngineEvent event) async {
    engine.emit(event);
    await tester.pumpAndSettle();
  }

  /// Answers the latest inspect with [payload].
  Future<void> answer(WidgetTester tester, DockerPayload payload) =>
      emit(tester, dockerAnswer(inspects.last, payload));
}

/// The Containers sub-tab beside an inspector that shows the container it
/// opens, as the desktop shell holds them, or on a [phone] alone, where a
/// row pushes the details.
Future<_Harness> _pump(
  WidgetTester tester, {
  Size size = _desktop,
  Brightness brightness = Brightness.light,
  TargetPlatform platform = TargetPlatform.linux,
  bool phone = false,
  HandOffLauncher? launcher,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine, now: () => _now);
  final inspection = ValueNotifier<InspectedContainer?>(null);
  addTearDown(() async {
    monitoring.dispose();
    inspection.dispose();
    await engine.close();
  });

  final base = brightness == Brightness.light
      ? GhostTheme.light(klabautermannThemeStyle, platform: platform)
      : GhostTheme.dark(klabautermannThemeStyle, platform: platform);
  final theme = base.copyWith(
    textTheme: base.textTheme.apply(fontFamily: goldenFontFamily),
  );
  final panel = ContainersPanel(
    monitoring: monitoring,
    serverId: _serverId,
    visible: true,
  );
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: launcher == null
          ? null
          : (context, child) => HandOffScope(launcher: launcher, child: child!),
      home: Scaffold(
        body: phone
            ? panel
            : ContainerInspectionScope(
                inspection: inspection,
                child: Row(
                  children: [
                    Expanded(child: panel),
                    SizedBox(
                      width: 300,
                      child: RepaintBoundary(
                        key: const ValueKey('inspector'),
                        child: ColoredBox(
                          color: theme.colorScheme.surfaceContainerLow,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: ValueListenableBuilder(
                              valueListenable: inspection,
                              builder: (context, inspected, _) =>
                                  inspected == null
                                  ? const SizedBox.expand()
                                  : ContainerInspectorBody(
                                      key: ValueKey(inspected.container.id),
                                      monitoring: monitoring,
                                      inspected: inspected,
                                      onClose: () => inspection.value = null,
                                    ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
    ),
  );
  final harness = _Harness(engine, inspection);
  await harness.emit(
    tester,
    dockerContainerList(_serverId, [
      _row,
      dockerContainer('a1f3c2e4b5d6', name: 'web-frontend', project: 'web'),
    ], at: _now),
  );
  return harness;
}

/// Opens web-db's details from its row.
Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('web-db').first);
  await tester.pumpAndSettle();
}

/// Inside the details.
Finder _inDetails(Finder finder) =>
    find.descendant(of: find.byType(ContainerDetailsView), matching: finder);

/// The node a screen reader reads for [label].
Finder _spoken(String label) => find.bySemanticsLabel(label);

/// 03 §7.12 CTR-03, CTR-04, DKE-10 and §8.9's SAF-07: a container's
/// details, opened from its row.
void main() {
  setUpAll(() async {
    if (!goldensCompareHere) return;
    await loadGoldenFonts();
    // The command line, the checks' output and the raw JSON draw in the
    // bundled monospace family.
    await loadBundledMonoFonts();
  });

  testWidgets('a row opens the details in the inspector, read once', (
    tester,
  ) async {
    final harness = await _pump(tester);
    expect(harness.inspects, isEmpty);

    await _open(tester);
    expect(harness.inspection.value?.container.id, _id);
    expect(harness.inspects, hasLength(1));
    expect(
      (harness.inspects.single.query as DockerContainerQuery).containerId,
      _id,
    );
    expect(_inDetails(find.text('Reading the container details…')), findsOne);

    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );
    for (final text in [
      'Overview',
      'Running',
      'Unhealthy',
      '3 failed checks in a row',
      'Restart unless stopped',
      'postgres:16',
      '3f1c9a6b2e8d',
      // The image's id is the digest without its algorithm.
      'Health checks',
      // CLDR's narrow no-break space before the day period.
      'Exit code 1, Oct 15 2:30:00\u202fPM',
      'Entrypoint',
      'docker-entrypoint.sh',
      'POSTGRES_USER',
      'app',
      'com.docker.compose.service',
      '/var/lib/postgresql/data',
      'web_pgdata',
      'Volume, read-write',
      'Bind mount, read-only',
      // The row's ports: the inspect carries none.
      '5432/tcp',
      'web_default',
      'IP address: 172.18.0.3',
      'Aliases: db, web-db',
      'Raw JSON',
    ]) {
      expect(_inDetails(find.text(text)), findsWidgets, reason: text);
    }
    // No zero time: the container never stopped.
    expect(_inDetails(find.text('Stopped')), findsNothing);
    // No label points at a page (CTR-11).
    expect(_inDetails(find.text('Links')), findsNothing);
    expect(tester.takeException(), isNull);

    // Another row replaces it.
    await tester.tap(find.text('web-frontend').first);
    await tester.pumpAndSettle();
    expect(harness.inspects, hasLength(2));
  });

  testWidgets('the keyboard opens a row, the close button takes focus, and '
      'Escape closes', (tester) async {
    final harness = await _pump(tester);
    bool closeFocused() =>
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
            .focusNode ==
        FocusManager.instance.primaryFocus;

    await _open(tester);
    expect(closeFocused(), isTrue, reason: 'focus moves to the details');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(harness.inspection.value, isNull);
    expect(find.byType(ContainerDetailsView), findsNothing);

    // Back in the table, Enter opens the active row again.
    FocusManager.instance.rootScope.descendants
        .firstWhere((node) => node.debugLabel == 'SortableTable')
        .requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(harness.inspection.value?.container.id, _id);
    expect(closeFocused(), isTrue);
  });

  testWidgets('a screen reader opens a row with a tap', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await _pump(tester);
    final row = find.byKey(const ValueKey('containers.row.$_id'));
    expect(
      tester.getSemantics(row),
      isSemantics(
        isButton: true,
        hasTapAction: true,
        label:
            'Name: web-db\nState: Running\nHealth: Unhealthy\n'
            'Status: Up 3 hours\nImage: postgres:16\nPorts: 5432/tcp\n'
            'Stack: web\nCPU: unknown\nMemory: unknown',
      ),
    );
    final node = tester.getSemantics(row);
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(harness.inspection.value?.container.id, _id);
    handle.dispose();
  });

  testWidgets('a masked value shows for 30 s once selected, and a screen '
      'reader hears "(masked)" in its place', (tester) async {
    final handle = tester.ensureSemantics();
    final harness = await _pump(tester);
    await _open(tester);
    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );
    expect(
      _inDetails(find.text('Select a masked value to show it for 30 seconds.')),
      findsOneWidget,
    );
    expect(_inDetails(find.text('hunter2')), findsNothing);
    expect(_inDetails(find.text('t0ken')), findsNothing);
    expect(
      _inDetails(find.text('connect postgres://app:********@db:5432 failed')),
      findsOneWidget,
    );

    // Read as masked, never as eight asterisks.
    final password = _spoken('POSTGRES_PASSWORD: (masked)');
    expect(
      tester.getSemantics(password),
      matchesSemantics(
        label: 'POSTGRES_PASSWORD: (masked)',
        hint: 'Show the masked value',
        isButton: true,
        hasTapAction: true,
      ),
    );
    expect(_spoken('backup.token: (masked)'), findsOneWidget);
    expect(_spoken('(masked)'), findsOneWidget, reason: 'the masked argument');
    expect(
      _spoken('connect postgres://app:(masked)@db:5432 failed'),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel(RegExp(r'\*{8}')), findsNothing);

    await tester.tap(password);
    await tester.pumpAndSettle();
    expect(_inDetails(find.text('hunter2')), findsOneWidget);
    expect(
      tester.getSemantics(_spoken('POSTGRES_PASSWORD: hunter2')),
      matchesSemantics(
        label: 'POSTGRES_PASSWORD: hunter2',
        hint: 'Mask again',
        isButton: true,
        hasTapAction: true,
      ),
    );
    // Only the one selected.
    expect(_inDetails(find.text('t0ken')), findsNothing);

    await tester.pump(kRevealDuration - const Duration(seconds: 1));
    expect(_inDetails(find.text('hunter2')), findsOneWidget);
    await tester.pump(const Duration(seconds: 1));
    expect(_inDetails(find.text('hunter2')), findsNothing);

    // Selected again, it masks at once on a second selection.
    await tester.tap(_spoken('POSTGRES_PASSWORD: (masked)'));
    await tester.pumpAndSettle();
    await tester.tap(_spoken('POSTGRES_PASSWORD: hunter2'));
    await tester.pumpAndSettle();
    expect(_inDetails(find.text('hunter2')), findsNothing);

    // The redacted output reveals whole.
    await tester.tap(_spoken('connect postgres://app:(masked)@db:5432 failed'));
    await tester.pumpAndSettle();
    expect(
      _inDetails(find.text('connect postgres://app:s3cret@db:5432 failed')),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('everything revealed is masked again when the app turns '
      'inactive, or the details close or show another container', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await _open(tester);
    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );
    Future<void> revealBoth() async {
      await tester.tap(_inDetails(find.text('POSTGRES_PASSWORD')));
      await tester.tap(_inDetails(find.text('backup.token')));
      await tester.pumpAndSettle();
      expect(_inDetails(find.text('hunter2')), findsOneWidget);
      expect(_inDetails(find.text('t0ken')), findsOneWidget);
    }

    await revealBoth();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(_inDetails(find.text('hunter2')), findsNothing);
    expect(_inDetails(find.text('t0ken')), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(_inDetails(find.text('hunter2')), findsNothing);

    // Another container: masked.
    await revealBoth();
    await tester.tap(find.text('web-frontend').first);
    await tester.pumpAndSettle();
    expect(harness.inspection.value?.container.id, 'a1f3c2e4b5d6');
    await harness.answer(
      tester,
      DockerContainerPayload(
        dockerContainerDetails('a1f3c2e4b5d6', name: 'web-frontend'),
      ),
    );
    expect(_inDetails(find.text('hunter2')), findsNothing);
    expect(_inDetails(find.text('t0ken')), findsNothing);
    await tester.tap(find.byTooltip('Close the container details'));
    await tester.pumpAndSettle();
    await _open(tester);
    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );

    // Closed and opened again: masked.
    await revealBoth();
    await tester.tap(find.byTooltip('Close the container details'));
    await tester.pumpAndSettle();
    await _open(tester);
    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );
    expect(_inDetails(find.text('hunter2')), findsNothing);

    // The timers of a closed view fire into nothing.
    await tester.pump(kRevealDuration);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a reveal stays with the check selected when a read again '
      'shifts the health log', (tester) async {
    ContainerHealthCheck check(int minute, String secret) =>
        ContainerHealthCheck(
          start: DateTime(2026, 10, 15, 14, minute),
          end: DateTime(2026, 10, 15, 14, minute, 1),
          exitCode: 1,
          output: MaskedValue.redacted(
            'token ******** refused',
            'token $secret refused',
          ),
        );
    final harness = await _pump(tester);
    await _open(tester);
    await harness.answer(
      tester,
      DockerContainerPayload(
        dockerContainerDetails(
          _id,
          healthLog: [check(28, 'first'), check(29, 'second')],
        ),
      ),
    );
    // The newest check shows first.
    await tester.tap(_inDetails(find.text('token ******** refused')).first);
    await tester.pumpAndSettle();
    expect(_inDetails(find.text('token second refused')), findsOneWidget);

    // The row changes and the details are read again: the oldest check
    // left the log and a new one took the newest place.
    await harness.emit(
      tester,
      dockerContainerList(_serverId, [
        dockerContainer(
          _id,
          name: 'web-db',
          project: 'web',
          status: 'Up 4 hours (unhealthy)',
          health: HealthStatus.unhealthy,
        ),
      ], at: _now),
    );
    await harness.answer(
      tester,
      DockerContainerPayload(
        dockerContainerDetails(
          _id,
          healthLog: [check(29, 'second'), check(30, 'third')],
        ),
      ),
    );
    expect(_inDetails(find.text('token second refused')), findsOneWidget);
    expect(_inDetails(find.text('token third refused')), findsNothing);
  });

  testWidgets('the raw JSON is drawn from the masked model, even with a '
      'value revealed', (tester) async {
    final harness = await _pump(tester, size: const Size(1000, 4000));
    await _open(tester);
    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );
    await tester.tap(_inDetails(find.text('POSTGRES_PASSWORD')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(_inDetails(find.text('Raw JSON')));
    await tester.tap(_inDetails(find.text('Raw JSON')));
    await tester.pumpAndSettle();

    final json = tester
        .widget<SelectableText>(_inDetails(find.byType(SelectableText)))
        .data!;
    expect(json, contains('"POSTGRES_PASSWORD=********"'));
    expect(json, contains('"backup.token": "********"'));
    expect(json, contains('"Name": "unless-stopped"'));
    expect(json, isNot(contains('hunter2')));
    expect(json, isNot(contains('s3cret')));
    expect(json, isNot(contains('t0ken')));
    expect(json, isNot(contains('never-shown')), reason: 'log options');
    expect(json, isNot(contains('0001-01-01')), reason: 'the zero time');
  });

  testWidgets('a container another tool manages carries its badge', (
    tester,
  ) async {
    final harness = await _pump(tester);
    await _open(tester);
    await harness.answer(
      tester,
      DockerContainerPayload(
        dockerContainerDetails(
          _id,
          labels: {'coolify.managed': MaskedValue.plain('true')},
        ),
      ),
    );
    expect(_inDetails(find.text('Managed by Coolify')), findsOneWidget);
    expect(
      _inDetails(
        find.text(
          'Changes made outside Coolify can be overwritten by it. The label '
          'coolify.managed marks it.',
        ),
      ),
      findsOneWidget,
    );

    // Unowned: no badge.
    await harness.emit(
      tester,
      dockerContainerList(_serverId, [
        dockerContainer(_id, name: 'web-db', status: 'Up 1 second'),
      ], at: _now),
    );
    expect(harness.inspects, hasLength(2), reason: 'the row changed');
    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );
    expect(_inDetails(find.textContaining('Managed by')), findsNothing);
  });

  testWidgets('a removed container says so over what was read', (tester) async {
    final harness = await _pump(tester);
    await _open(tester);
    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );
    await harness.emit(
      tester,
      dockerContainerList(_serverId, [
        dockerContainer('a1f3c2e4b5d6', name: 'web-frontend', project: 'web'),
      ], at: _now),
    );
    expect(_inDetails(find.text('This container was removed.')), findsOne);
    expect(
      _inDetails(find.text('The details below are the last ones read.')),
      findsOne,
    );
    expect(_inDetails(find.text('POSTGRES_USER')), findsOneWidget);

    // Opened when already gone: nothing was read.
    harness.inspection.value = InspectedContainer(
      serverId: _serverId,
      container: dockerContainer('0d0d0d0d0d0d', name: 'gone'),
    );
    await tester.pumpAndSettle();
    await harness.answer(
      tester,
      const DockerQueryFailed(DockerQueryFailure.notFound),
    );
    expect(_inDetails(find.text('This container was removed.')), findsOne);
    expect(
      _inDetails(find.text('The details below are the last ones read.')),
      findsNothing,
    );
  });

  for (final phone in [false, true]) {
    testWidgets('details open on a server that leaves the fleet say so, '
        'keep what was read and close cleanly (SYN-08, '
        '${phone ? 'phone page' : 'inspector'})', (tester) async {
      final harness = await _pump(
        tester,
        size: phone ? _phone : _desktop,
        phone: phone,
      );
      await _open(tester);
      await harness.answer(
        tester,
        DockerContainerPayload(dockerContainerDetails(_id)),
      );

      await harness.emit(tester, CatalogReplaced(const []));
      expect(tester.takeException(), isNull);
      expect(
        _inDetails(find.text('This server is no longer in the fleet.')),
        findsOne,
      );

      // The view still draws and reveals what was read.
      final masked = _inDetails(find.text('POSTGRES_PASSWORD'));
      await tester.ensureVisible(masked);
      await tester.tap(masked);
      await tester.pumpAndSettle();
      expect(_inDetails(find.text('hunter2')), findsOneWidget);
      expect(tester.takeException(), isNull);

      if (phone) {
        await tester.pageBack();
      } else {
        harness.inspection.value = null;
      }
      await tester.pumpAndSettle();
      expect(find.byType(ContainerDetailsView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('says why the details could not be read, keeps the last ones '
      'and reads again', (tester) async {
    final harness = await _pump(tester);
    await _open(tester);
    await harness.answer(
      tester,
      const DockerQueryFailed(
        DockerQueryFailure.connectionFailed,
        detail: 'read: connection reset by peer',
      ),
    );
    expect(
      _inDetails(
        find.text(
          'The connection to the engine failed while inspecting the '
          'container.',
        ),
      ),
      findsOneWidget,
    );
    expect(
      _inDetails(find.text('read: connection reset by peer')),
      findsOneWidget,
    );

    await tester.tap(_inDetails(find.text('Try again')));
    await tester.pumpAndSettle();
    expect(harness.inspects, hasLength(2));
    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );
    expect(_inDetails(find.text('Try again')), findsNothing);

    harness.engine.emit(
      dockerContainerList(_serverId, [
        dockerContainer(_id, name: 'web-db', status: 'Up 2 seconds'),
      ], at: _now),
    );
    await tester.pumpAndSettle();
    await harness.answer(
      tester,
      const DockerQueryFailed(DockerQueryFailure.daemonError),
    );
    expect(
      _inDetails(
        find.text('The engine refused or failed to inspect the container.'),
      ),
      findsOneWidget,
    );
    expect(
      _inDetails(find.text('The details below are the last ones read.')),
      findsOne,
    );
    expect(_inDetails(find.text('POSTGRES_USER')), findsOneWidget);
  });

  testWidgets('a stopped container names its exit code, its stop and an '
      'out-of-memory kill', (tester) async {
    final harness = await _pump(tester);
    await _open(tester);
    final details = dockerContainerDetails(
      _id,
      status: 'exited',
      exitCode: 137,
      oomKilled: true,
      health: HealthStatus.none,
      restartPolicy: 'on-failure',
    );
    await harness.answer(
      tester,
      DockerContainerPayload(
        ContainerDetails(
          id: details.id,
          name: details.name,
          created: details.created,
          state: ContainerDetailsState(
            status: 'exited',
            exitCode: 137,
            oomKilled: true,
            startedAt: DateTime(2026, 10, 15, 11, 30),
            finishedAt: DateTime(2026, 10, 15, 12),
          ),
          config: details.config,
          hostConfig: const ContainerHostConfig(
            restartPolicy: ContainerRestartPolicy(
              name: 'on-failure',
              maximumRetryCount: 5,
            ),
          ),
        ),
      ),
    );
    expect(_inDetails(find.text('Exited, exit code 137')), findsOneWidget);
    expect(_inDetails(find.text('Stopped')), findsOneWidget);
    expect(
      _inDetails(
        find.text('Its last run was stopped for running out of memory.'),
      ),
      findsOneWidget,
    );
    expect(
      _inDetails(find.text('Restart on failure, at most 5 times')),
      findsOneWidget,
    );
    expect(_inDetails(find.text('Health checks')), findsNothing);
    expect(_inDetails(find.text('No mounts.')), findsOneWidget);
    expect(_inDetails(find.text('Not attached to a network.')), findsOneWidget);
  });

  group('label links (CTR-11)', () {
    final labels = {
      'dockhand.url': MaskedValue.plain('[Admin](https://db.example.com/ui)'),
      'traefik.http.routers.db.rule': MaskedValue.plain(
        'Host(`pg.example.com`)',
      ),
      'traefik.http.routers.db.tls': MaskedValue.plain('true'),
    };

    testWidgets('the labels\' pages are listed with where each came from, '
        'and open in the browser', (tester) async {
      final launcher = _Launcher();
      final harness = await _pump(tester, launcher: launcher);
      await _open(tester);
      await harness.answer(
        tester,
        DockerContainerPayload(dockerContainerDetails(_id, labels: labels)),
      );
      expect(_inDetails(find.text('Links')), findsOneWidget);
      expect(_inDetails(find.text('Admin')), findsOneWidget);
      expect(_inDetails(find.text('https://db.example.com/ui')), findsWidgets);
      expect(_inDetails(find.text('From a Dockhand label')), findsOneWidget);
      expect(_inDetails(find.text('https://pg.example.com')), findsOneWidget);
      expect(_inDetails(find.text('A Traefik route')), findsOneWidget);

      await tester.tap(
        _inDetails(
          find.byTooltip('Open https://pg.example.com in the browser'),
        ),
      );
      await tester.pumpAndSettle();
      expect(launcher.opened, [Uri.parse('https://pg.example.com')]);

      launcher.answer = false;
      await tester.tap(_inDetails(find.byTooltip('Open Admin in the browser')));
      await tester.pumpAndSettle();
      expect(
        find.text('The link could not be opened in a browser.'),
        findsOneWidget,
      );
    });

    testWidgets('without a launcher the addresses are text to copy', (
      tester,
    ) async {
      final harness = await _pump(tester);
      await _open(tester);
      await harness.answer(
        tester,
        DockerContainerPayload(dockerContainerDetails(_id, labels: labels)),
      );
      expect(
        _inDetails(find.widgetWithText(SelectableText, 'Admin')),
        findsOneWidget,
      );
      expect(_inDetails(find.byIcon(Icons.open_in_new)), findsNothing);
    });
  });

  group('processes (CTR-10)', () {
    List<DockerQuery> tops(_Harness harness) => [
      for (final query
          in harness.engine.sentOfType<DockerQuery>().cast<DockerQuery>())
        if (query.query is DockerContainerTopQuery) query,
    ];

    final top = DockerContainerTopPayload(
      titles: const ['PID', 'USER', '%CPU', 'RSS', 'ELAPSED', 'COMMAND'],
      commandColumn: 5,
      processes: [
        [
          for (final cell in ['4211', 'postgres', '0.3', '20480', '03:01:02'])
            MaskedValue.plain(cell),
          MaskedValue.redacted(
            'postgres -c password=${MaskedValue.maskToken}',
            'postgres -c password=s3cret',
          ),
        ],
        [
          for (final cell in ['4250', 'postgres', '0.0', '4096', '03:01:00'])
            MaskedValue.plain(cell),
          MaskedValue.plain('postgres: checkpointer'),
        ],
      ],
    );

    testWidgets('a running container reads its processes once the details '
        'show, masked until revealed, and reads again on request', (
      tester,
    ) async {
      final harness = await _pump(tester);
      await _open(tester);
      expect(tops(harness), isEmpty);
      await harness.answer(
        tester,
        DockerContainerPayload(dockerContainerDetails(_id)),
      );
      expect(tops(harness), hasLength(1));
      expect(
        (tops(harness).single.query as DockerContainerTopQuery).containerId,
        _id,
      );
      expect(_inDetails(find.text('Reading processes…')), findsOneWidget);

      await harness.emit(tester, dockerAnswer(tops(harness).last, top));
      expect(_inDetails(find.text('Processes')), findsOneWidget);
      expect(_inDetails(find.text('2 processes')), findsOneWidget);
      expect(
        _inDetails(find.text('postgres -c password=${MaskedValue.maskToken}')),
        findsOneWidget,
      );
      expect(_inDetails(find.text('postgres: checkpointer')), findsOneWidget);
      expect(_inDetails(find.text('PID: 4211')), findsOneWidget);
      expect(_inDetails(find.text('RSS: 20 MiB')), findsOneWidget);

      final reveal = _inDetails(
        find.widgetWithText(TextButton, 'Reveal values'),
      ).last;
      await tester.ensureVisible(reveal);
      await tester.tap(reveal);
      await tester.pumpAndSettle();
      expect(
        _inDetails(find.text('postgres -c password=s3cret')),
        findsOneWidget,
      );
      await tester.pump(kRevealDuration);
      await tester.pumpAndSettle();
      expect(
        _inDetails(find.text('postgres -c password=s3cret')),
        findsNothing,
      );

      final again = _inDetails(find.text('Read again'));
      await tester.ensureVisible(again);
      await tester.tap(again);
      await tester.pumpAndSettle();
      expect(tops(harness), hasLength(2));
      await harness.emit(
        tester,
        dockerAnswer(
          tops(harness).last,
          const DockerQueryFailed(
            DockerQueryFailure.daemonError,
            detail: 'Container is not running',
          ),
        ),
      );
      expect(
        _inDetails(
          find.text(
            'The engine refused or failed to list the container\'s '
            'processes.',
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a stopped container reads none and says why', (tester) async {
      final harness = await _pump(tester);
      await harness.emit(
        tester,
        dockerContainerList(_serverId, [
          dockerContainer(_id, name: 'web-db', state: 'exited'),
        ], at: _now),
      );
      await _open(tester);
      await harness.answer(
        tester,
        DockerContainerPayload(dockerContainerDetails(_id, status: 'exited')),
      );
      expect(tops(harness), isEmpty);
      expect(
        _inDetails(
          find.text('The container is not running, so it has no processes.'),
        ),
        findsOneWidget,
      );
    });
  });

  testWidgets('a phone pushes the details on a page of their own', (
    tester,
  ) async {
    final harness = await _pump(
      tester,
      size: _phone,
      platform: TargetPlatform.android,
      phone: true,
    );
    await _open(tester);
    expect(find.byType(ContainerDetailsPage), findsOneWidget);
    expect(
      find.descendant(of: find.byType(AppBar), matching: find.text('web-db')),
      findsOneWidget,
    );
    expect(harness.inspects, hasLength(1));
    await harness.answer(
      tester,
      DockerContainerPayload(dockerContainerDetails(_id)),
    );

    // A touch target of 48 dp for a masked value (A11Y-01).
    final masked = _inDetails(find.text('POSTGRES_PASSWORD'));
    await tester.ensureVisible(masked);
    await tester.pumpAndSettle();
    final target = find.ancestor(of: masked, matching: find.byType(InkWell));
    expect(tester.getSize(target.first).height, greaterThanOrEqualTo(48));
    await tester.tap(masked);
    await tester.pumpAndSettle();
    expect(_inDetails(find.text('hunter2')), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(ContainerDetailsPage), findsNothing);
    expect(find.byType(ContainersPanel), findsOneWidget);
  });

  test('restart policies read by the Engine API\'s names', () {
    expect(RestartPolicyKind.of(null), RestartPolicyKind.no);
    expect(RestartPolicyKind.of(''), RestartPolicyKind.no);
    expect(
      RestartPolicyKind.of('unless-stopped'),
      RestartPolicyKind.unlessStopped,
    );
    expect(RestartPolicyKind.of('on-failure'), RestartPolicyKind.onFailure);
    expect(RestartPolicyKind.of('sometimes'), isNull);
    expect(engineTime(DateTime.utc(1)), isNull);
  });

  group('golden', () {
    // 03 §11.1: the desktop inspector's details of an unhealthy compose
    // service with masked values, one revealed being out of the picture.
    for (final brightness in Brightness.values) {
      testWidgets('desktop inspector, ${brightness.name}', (tester) async {
        final harness = await _pump(
          tester,
          size: _window,
          brightness: brightness,
        );
        await _open(tester);
        await harness.answer(
          tester,
          DockerContainerPayload(
            dockerContainerDetails(
              _id,
              labels: {'coolify.managed': MaskedValue.plain('true')},
            ),
          ),
        );
        await expectLater(
          find.byKey(const ValueKey('inspector')),
          matchesGoldenFile(
            'goldens/container_details_desktop_${brightness.name}.png',
          ),
        );
      }, skip: !goldensCompareHere);
    }
  });
}

/// Opens every link with [answer] and records each.
final class _Launcher implements HandOffLauncher {
  final opened = <Uri>[];
  bool answer = true;

  @override
  bool available(HandOffTarget target) => false;

  @override
  Future<bool> open(Uri link) async {
    opened.add(link);
    return answer;
  }
}
