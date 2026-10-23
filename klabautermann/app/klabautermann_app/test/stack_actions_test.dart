import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/docker/stacks_panel.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
final _now = DateTime(2026, 10, 15, 14, 30);

const _allowed = SafetyPolicy(
  servers: {_serverId: ServerSafety(management: true)},
);

/// A verified web stack with a scaled service and a one-off run, and an
/// unverified one.
final _stacks = [
  dockerStack(
    'web',
    [
      dockerService('app', [
        dockerContainer('w1', name: 'web-app-1', image: 'nginx:1.27'),
        dockerContainer('w2', name: 'web-app-2', image: 'nginx:1.27'),
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
    workingDir: '/srv/web',
    configFiles: ['/srv/web/compose.yaml'],
  ),
  dockerStack('metrics', [
    dockerService('prometheus', [
      dockerContainer('m1', name: 'metrics-prometheus-1', image: 'prom:3'),
    ]),
  ]),
];

const _verdicts = <String, StackVerdict>{
  'web': StackVerified(),
  'metrics': StackUnverified(StackUnverifiedReason.hashMismatch),
};

Finder _inOverview(Finder finder) =>
    find.descendant(of: find.byType(StackOverview), matching: finder);

void main() {
  late FakeEngineClient engine;
  late SafetyController safety;

  /// The Stacks sub-tab under [policy], listing [_stacks], with
  /// [project]'s overview beside the list.
  Future<void> pump(
    WidgetTester tester, {
    SafetyPolicy policy = _allowed,
    String project = 'web',
  }) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    engine = FakeEngineClient();
    final monitoring = MonitoringController(engine, now: () => _now);
    final operations = OperationsController(engine);
    safety = SafetyController(initial: policy, apply: (_) {});
    addTearDown(() async {
      operations.dispose();
      monitoring.dispose();
      safety.dispose();
      await engine.close();
    });

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: SafetyScope(
          safety: safety,
          child: OperationsScope(
            operations: operations,
            child: Scaffold(
              body: StacksPanel(
                monitoring: monitoring,
                serverId: _serverId,
                visible: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    engine.emit(
      dockerStackList(_serverId, _stacks, at: _now, verdicts: _verdicts),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('stacks.row.$project')));
    await tester.pumpAndSettle();
  }

  List<ActionIntent> planned() => [
    for (final request in engine.sentOfType<PlanAction>())
      (request as PlanAction).intent,
  ];

  Future<void> choose(WidgetTester tester, String service, String item) async {
    await tester.tap(find.byTooltip('Actions for $service'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item).last);
    await tester.pumpAndSettle();
  }

  testWidgets("a service's menu plans its start, stop, restart, pull and "
      'recreate (STK-23)', (tester) async {
    await pump(tester);

    await choose(tester, 'app', 'Restart');
    final restart = planned().last as StackAction;
    expect(
      (restart.project, restart.service, restart.verb),
      ('web', 'app', StackVerb.restart),
    );

    // The preview is not answered, so the next plan waits for it; answer
    // it as refused so the next one goes out.
    engine.emit(
      ActionRefused(ActionRefusalReason.invalidTarget, intent: restart),
    );
    await tester.pumpAndSettle();
    await choose(tester, 'app', 'Recreate');
    final recreate = planned().last as StackComposeAction;
    expect(
      (recreate.service, recreate.verb),
      ('app', StackComposeVerb.recreateService),
    );
  });

  testWidgets('Scale asks for a count in range, starting from the '
      "service's containers", (tester) async {
    await pump(tester);
    await choose(tester, 'app', 'Scale');

    expect(find.text('Scale app'), findsOneWidget);
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(tester.widget<TextField>(field).controller!.text, '2');

    await tester.enterText(field, '${kComposeMaxScale + 1}');
    await tester.pump();
    expect(
      find.text('Enter a number from 0 to $kComposeMaxScale.'),
      findsOneWidget,
    );
    final confirm = find.widgetWithText(FilledButton, 'Scale');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);

    await tester.enterText(field, '3');
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    final scale = planned().single as StackComposeAction;
    expect(
      (scale.service, scale.verb, scale.replicas),
      ('app', StackComposeVerb.scaleService, 3),
    );
  });

  testWidgets('Down plans taking the whole stack down', (tester) async {
    await pump(tester);
    await tester.tap(_inOverview(find.text('Down')));
    await tester.pumpAndSettle();

    final down = planned().single as StackComposeAction;
    expect(
      (down.project, down.verb, down.service),
      ('web', StackComposeVerb.down, null),
    );
  });

  testWidgets('a one-off run has no menu, and an unverified stack offers '
      'neither menus nor Down', (tester) async {
    await pump(tester);
    expect(find.byTooltip('Actions for app'), findsOneWidget);
    expect(find.byTooltip('Actions for migrate'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('stacks.row.metrics')));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Actions for prometheus'), findsNothing);
    expect(_inOverview(find.text('Down')), findsNothing);
  });

  testWidgets('read-only hides the menus and Down', (tester) async {
    await pump(tester);
    await safety.setGlobalReadOnly(true);
    await tester.pumpAndSettle();

    expect(find.byTooltip('Actions for app'), findsNothing);
    expect(_inOverview(find.text('Down')), findsNothing);
  });

  testWidgets("a verified stack lists its files' profiles (STK-09)", (
    tester,
  ) async {
    await pump(tester);
    final query = engine
        .sentOfType<DockerQuery>()
        .cast<DockerQuery>()
        .lastWhere((q) => q.query is DockerStackProfilesQuery);
    expect((query.query as DockerStackProfilesQuery).project, 'web');
    expect(_inOverview(find.text('Profiles')), findsOneWidget);

    engine.emit(
      dockerAnswer(
        query,
        DockerStackProfilesPayload(
          project: 'web',
          profiles: ['debug', 'tools'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_inOverview(find.text('debug')), findsOneWidget);
    expect(_inOverview(find.text('tools')), findsOneWidget);
  });

  testWidgets('profiles that could not be listed say so', (tester) async {
    await pump(tester);
    final query = engine
        .sentOfType<DockerQuery>()
        .cast<DockerQuery>()
        .lastWhere((q) => q.query is DockerStackProfilesQuery);
    engine.emit(
      dockerAnswer(
        query,
        const DockerQueryFailed(DockerQueryFailure.daemonError),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _inOverview(find.text('The profiles could not be listed.')),
      findsOneWidget,
    );
  });
}
