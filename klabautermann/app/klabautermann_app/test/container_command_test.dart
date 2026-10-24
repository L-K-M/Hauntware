import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/docker/container_command.dart';
import 'package:klabautermann_app/ui/docker/container_details.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
const _id = 'b7e9d0c1a2f3';

final _row = dockerContainer(_id, name: 'web-db', image: 'postgres:16');

const _allowed = SafetyPolicy(
  servers: {_serverId: ServerSafety(management: true)},
);

ActionPreview _preview(ContainerExec intent) => ActionPreview(
  intent: intent,
  targetName: 'web-db',
  steps: [
    ExecStep(
      path: '/v1.47/containers/$_id/exec',
      containerId: _id,
      argv: intent.argv,
      user: intent.user,
    ),
  ],
  requiredLevel: RequiredLevel.login,
  runner: const RunnerFacts(
    identity: 'deploy',
    credentials: RunnerCredentials.session,
  ),
  requiredTier: ConfirmationTier.acknowledge,
);

final _runButton = find.widgetWithIcon(FilledButton, Icons.play_arrow);

/// Lets an engine event reach the sheet through the operations
/// controller and draws it. Not pumpAndSettle: the command field's cursor
/// blinks once the preview hands focus back.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeEngineClient engine;
  late OperationsController operations;

  /// The engine and operations controller, made inside the test's zone:
  /// made in setUp, their events would wait for the real event loop.
  void start() {
    engine = FakeEngineClient();
    operations = OperationsController(engine);
    addTearDown(() async {
      operations.dispose();
      await engine.close();
    });
  }

  Future<void> pumpSheet(WidgetTester tester) async {
    start();
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ContainerCommandSheet(
            operations: operations,
            serverId: _serverId,
            container: _row,
          ),
        ),
      ),
    );
  }

  /// Types [command] and [user], runs it, and confirms its preview.
  Future<ContainerExec> run(
    WidgetTester tester,
    String command, {
    String user = '',
  }) async {
    await tester.enterText(find.byType(TextField).first, command);
    await tester.enterText(find.byType(TextField).last, user);
    await tester.tap(_runButton);
    await tester.pump();

    final intent =
        (engine.sentOfType<PlanAction>().last as PlanAction).intent
            as ContainerExec;
    engine.emit(ActionPlanned('plan-1', _preview(intent)));
    await tester.pumpAndSettle();
    // The preview's own Run confirms it. The run's progress bar never
    // settles, so time passes instead.
    await tester.tap(find.text('Run').last);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    return intent;
  }

  testWidgets('runs the words as typed, as the user given, and shows the '
      'exit code and both outputs', (tester) async {
    await pumpSheet(tester);
    final intent = await run(
      tester,
      "sh -c 'echo hi; echo oops >&2; exit 3'",
      user: ' app ',
    );

    expect(intent.containerId, _id);
    expect(intent.argv, ['sh', '-c', 'echo hi; echo oops >&2; exit 3']);
    expect(intent.user, 'app');
    expect(engine.sentOfType<RunAction>(), hasLength(1));
    expect(find.text('Running…'), findsOneWidget);
    expect(tester.widget<FilledButton>(_runButton).onPressed, isNull);

    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.failed,
        failure: ActionFailure.stepFailed,
        failedStep: 0,
        exitCode: 3,
        output: ExecOutput(stdout: 'hi\n', stderr: 'oops\n'),
      ),
    );
    await _settle(tester);

    expect(find.text('Running…'), findsNothing);
    expect(find.text('Exit code 3.'), findsOneWidget);
    expect(find.text('Output'), findsOneWidget);
    expect(find.text('hi\n'), findsOneWidget);
    expect(find.text('Errors'), findsOneWidget);
    expect(find.text('oops\n'), findsOneWidget);
    expect(tester.widget<FilledButton>(_runButton).onPressed, isNotNull);
  });

  testWidgets('says when a command printed nothing, and when its output was '
      'cut', (tester) async {
    await pumpSheet(tester);
    await run(tester, 'true');
    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.succeeded,
        exitCode: 0,
        output: ExecOutput(stdout: '', stderr: ''),
      ),
    );
    await _settle(tester);
    expect(find.text('Exit code 0.'), findsOneWidget);
    expect(find.text('The command printed nothing.'), findsOneWidget);

    await run(tester, 'yes');
    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.succeeded,
        exitCode: 0,
        output: ExecOutput(stdout: 'y\n', stderr: '', truncated: true),
      ),
    );
    await _settle(tester);
    expect(
      find.text('The output was longer than 1 MiB; the rest was dropped.'),
      findsOneWidget,
    );
  });

  testWidgets('a command that never ran says why', (tester) async {
    await pumpSheet(tester);
    await run(tester, 'ls');
    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.failed,
        failure: ActionFailure.transport,
      ),
    );
    await _settle(tester);
    expect(
      find.text('web-db did not finish: the connection failed during the run.'),
      findsOneWidget,
    );
    expect(find.text('Output'), findsNothing);
  });

  testWidgets('a run that succeeded without an exit code is not shown as '
      'an error', (tester) async {
    await pumpSheet(tester);
    await run(tester, 'true');
    engine.emit(
      const ActionFinished(planId: 'plan-1', outcome: ActionOutcome.succeeded),
    );
    await _settle(tester);
    final headline = tester.widget<Text>(find.text('Done: web-db'));
    final error = Theme.of(
      tester.element(find.byType(ContainerCommandSheet)),
    ).colorScheme.error;
    expect(headline.style?.color, isNot(error));
  });

  testWidgets('an open quote or an empty field plans nothing', (tester) async {
    await pumpSheet(tester);
    await tester.enterText(find.byType(TextField).first, "echo 'open");
    await tester.tap(_runButton);
    await tester.pump();
    expect(
      find.text(
        'Enter a complete command: close any open quote and remove a trailing backslash.',
      ),
      findsOneWidget,
    );
    // Typing takes the complaint away until the next Run.
    await tester.enterText(find.byType(TextField).first, "echo 'open'");
    await tester.pump();
    expect(
      find.text(
        'Enter a complete command: close any open quote and remove a trailing backslash.',
      ),
      findsNothing,
    );

    await tester.enterText(find.byType(TextField).first, r'echo \');
    await tester.tap(_runButton);
    await tester.pump();
    expect(
      find.text(
        'Enter a complete command: close any open quote and remove a '
        'trailing backslash.',
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.tap(_runButton);
    await tester.pump();
    expect(engine.sentOfType<PlanAction>(), isEmpty);
  });

  testWidgets('another run of the same sheet ignores an earlier plan', (
    tester,
  ) async {
    await pumpSheet(tester);
    // An end for a plan this sheet did not start changes nothing.
    engine.emit(
      const ActionFinished(
        planId: 'plan-9',
        outcome: ActionOutcome.succeeded,
        exitCode: 0,
        output: ExecOutput(stdout: 'not ours', stderr: ''),
      ),
    );
    await _settle(tester);
    expect(find.text('not ours'), findsNothing);
  });

  group('entries (CTX-08)', () {
    Future<SafetyController> pumpInspector(
      WidgetTester tester,
      SafetyPolicy policy,
    ) async {
      start();
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final monitoring = MonitoringController(engine);
      addTearDown(monitoring.dispose);
      final safety = SafetyController(initial: policy, apply: (_) {});
      addTearDown(safety.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SafetyScope(
            safety: safety,
            child: OperationsScope(
              operations: operations,
              child: Scaffold(
                body: ContainerInspectorBody(
                  monitoring: monitoring,
                  inspected: InspectedContainer(
                    serverId: _serverId,
                    container: _row,
                  ),
                  onClose: () {},
                ),
              ),
            ),
          ),
        ),
      );
      return safety;
    }

    testWidgets('the inspector opens the sheet where actions are allowed', (
      tester,
    ) async {
      await pumpInspector(tester, _allowed);
      await tester.tap(find.byTooltip('Run a command'));
      await tester.pumpAndSettle();
      expect(find.text('Run a command in web-db'), findsOneWidget);
      expect(find.byType(ContainerCommandSheet), findsOneWidget);
    });

    testWidgets('read-only hides the entry', (tester) async {
      final safety = await pumpInspector(tester, _allowed);
      expect(find.byTooltip('Run a command'), findsOneWidget);

      await safety.setGlobalReadOnly(true);
      await tester.pump();
      expect(find.byTooltip('Run a command'), findsNothing);
    });

    testWidgets('an observe-only server shows no entry', (tester) async {
      await pumpInspector(tester, const SafetyPolicy());
      expect(find.byTooltip('Run a command'), findsNothing);
    });
  });
}
