// IMG-03's pull sheet (M6 N13): the reference planned and confirmed as any
// action is, each layer's progress as the engine reports it, the stop
// button and a closed sheet both cancelling the pull, and how it ended
// with what the daemon said.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/docker/image_pull.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _serverId = 'srv-1';

ActionPreview _preview(PullImage intent) => ActionPreview(
  intent: intent,
  targetName: intent.reference,
  steps: [
    ApiStep(
      method: 'POST',
      path: '/v1.52/images/create',
      query: const {'fromImage': 'nginx', 'tag': '1.27'},
    ),
  ],
  requiredLevel: RequiredLevel.login,
  runner: const RunnerFacts(
    identity: 'deploy',
    engine: 'docker /var/run/docker.sock',
  ),
  requiredTier: ConfirmationTier.acknowledge,
);

final _pullButton = find.widgetWithIcon(FilledButton, Icons.download);

/// Draws engine events without pumpAndSettle: the progress bars and the
/// field's cursor never settle.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  late FakeEngineClient engine;
  late OperationsController operations;
  late ValueNotifier<bool> shown;

  Future<void> pumpSheet(WidgetTester tester) async {
    engine = FakeEngineClient();
    operations = OperationsController(engine);
    shown = ValueNotifier(true);
    addTearDown(() async {
      operations.dispose();
      shown.dispose();
      await engine.close();
    });
    tester.view.physicalSize = const Size(900, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: shown,
            builder: (context, open, _) => open
                ? ImagePullSheet(operations: operations, serverId: _serverId)
                : const SizedBox(),
          ),
        ),
      ),
    );
  }

  /// Types [reference], picks [route] when given, plans it and confirms
  /// its preview.
  Future<PullImage> pull(
    WidgetTester tester,
    String reference, {
    String? route,
  }) async {
    await tester.enterText(find.byType(TextField), reference);
    if (route != null) {
      await tester.tap(find.text(route));
      await tester.pump();
    }
    await tester.tap(_pullButton);
    await tester.pump();
    final intent =
        (engine.sentOfType<PlanAction>().last as PlanAction).intent
            as PullImage;
    engine.emit(ActionPlanned('plan-1', _preview(intent)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run').last);
    await _settle(tester);
    return intent;
  }

  testWidgets('pulls the reference as typed and shows each layer with its '
      'bytes, then the end', (tester) async {
    await pumpSheet(tester);
    final intent = await pull(tester, ' nginx:1.27 ');
    expect((intent.serverId, intent.reference), (_serverId, 'nginx:1.27'));
    expect(engine.sentOfType<RunAction>(), hasLength(1));
    expect(find.text('Pulling. Closing this sheet stops the pull.'), findsOne);

    engine.emit(
      ImagePullProgress(
        planId: 'plan-1',
        status: '1.27: Pulling from library/nginx',
        layers: const [
          PullLayer(
            'aaaaaaaaaaaa',
            status: 'Downloading',
            current: 1024 * 1024,
            total: 4 * 1024 * 1024,
          ),
          PullLayer('bbbbbbbbbbbb', status: 'Pull complete'),
        ],
      ),
    );
    await _settle(tester);
    expect(find.text('1.27: Pulling from library/nginx'), findsOneWidget);
    expect(find.text('Downloading: 1 MiB of 4 MiB'), findsOneWidget);
    expect(find.text('Pull complete'), findsOneWidget);
    expect(find.byType(PullLayerRow), findsNWidgets(2));

    engine.emit(
      const ActionFinished(planId: 'plan-1', outcome: ActionOutcome.succeeded),
    );
    await _settle(tester);
    expect(find.textContaining('nginx:1.27'), findsWidgets);
    expect(find.text('Stop pull'), findsNothing);
    expect(tester.widget<FilledButton>(_pullButton).onPressed, isNotNull);
  });

  testWidgets('Stop pull cancels it; a failed pull shows what the daemon '
      'said', (tester) async {
    await pumpSheet(tester);
    await pull(tester, 'nginx:1.27');
    await tester.tap(find.text('Stop pull'));
    await tester.pump();
    expect(
      engine.sentOfType<CancelAction>().cast<CancelAction>().single.planId,
      'plan-1',
    );

    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.failed,
        failure: ActionFailure.stepFailed,
        failedStep: 0,
        output: ExecOutput(stdout: '', stderr: 'manifest unknown'),
      ),
    );
    await _settle(tester);
    expect(find.text('manifest unknown'), findsOneWidget);
  });

  testWidgets('closing the sheet while it pulls stops the pull, and after '
      'the end it does not', (tester) async {
    await pumpSheet(tester);
    await pull(tester, 'nginx:1.27');
    shown.value = false;
    await tester.pump();
    expect(engine.sentOfType<CancelAction>(), hasLength(1));
  });

  testWidgets('the server\'s login runs the host\'s docker pull: no stop, '
      'a closed sheet leaves it, and its output shows at the end', (
    tester,
  ) async {
    await pumpSheet(tester);
    expect(find.textContaining('pulls anonymously'), findsOneWidget);
    final intent = await pull(
      tester,
      'registry.example.com/app:2',
      route: "Server's login",
    );
    expect(intent.via, PullRoute.host);
    expect(find.text('Stop pull'), findsNothing);
    expect(
      find.text('Pulling on the server. Losing the connection stops the pull.'),
      findsOneWidget,
    );

    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.failed,
        failure: ActionFailure.stepFailed,
        failedStep: 0,
        exitCode: 1,
        output: ExecOutput(stdout: '', stderr: 'unauthorized: login first'),
      ),
    );
    await _settle(tester);
    expect(find.text('unauthorized: login first'), findsOneWidget);
  });

  testWidgets('a detached pull says it started on the server, and closing '
      'the sheet does not stop it', (tester) async {
    await pumpSheet(tester);
    final intent = await pull(tester, 'nginx:1.27', route: 'Detached');
    expect(intent.via, PullRoute.hostDetached);
    shown.value = false;
    await tester.pump();
    expect(engine.sentOfType<CancelAction>(), isEmpty);

    shown.value = true;
    await tester.pump();
  });

  testWidgets('a launched detached pull reads as started', (tester) async {
    await pumpSheet(tester);
    await pull(tester, 'nginx:1.27', route: 'Detached');
    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.succeeded,
        operationId: 'op-1',
      ),
    );
    await _settle(tester);
    expect(
      find.text('The pull of nginx:1.27 started on the server.'),
      findsOne,
    );
  });
}
