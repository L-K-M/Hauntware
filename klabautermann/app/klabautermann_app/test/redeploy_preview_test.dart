// The redeploy preview in the app (M4 E23b, STK-06, 03 §7.17): a detached
// operation says it continues on the server, the orphans are listed with
// the switch that plans their removal again, the warnings are worded, and
// a started operation toasts that it started.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_preview.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _keep = RedeployStack('srv-1', project: 'shop');
const _remove = RedeployStack('srv-1', project: 'shop', removeOrphans: true);

ActionPreview _preview(
  RedeployStack intent, {
  List<String> orphans = const ['shop-cache-1'],
  Set<PlanWarning> warnings = const {},
}) => ActionPreview(
  intent: intent,
  targetName: 'shop',
  steps: [
    ShellStep(['docker', 'compose', 'config', '-q'], discardOutput: true),
    ShellStep(['docker', 'compose', 'pull']),
    ShellStep([
      'docker',
      'compose',
      'up',
      '-d',
      if (intent.removeOrphans) '--remove-orphans',
    ]),
  ],
  requiredLevel: RequiredLevel.login,
  runner: const RunnerFacts(
    identity: 'deploy',
    engine: 'docker /var/run/docker.sock',
  ),
  requiredTier: intent.removeOrphans
      ? ConfirmationTier.typedPhrase
      : ConfirmationTier.acknowledge,
  hostWrites: const [
    HostWriteRow.engineState,
    HostWriteRow.userOperationRecords,
  ],
  detached: true,
  orphans: orphans,
  warnings: warnings,
);

void main() {
  late FakeEngineClient engine;
  late OperationsController operations;

  Future<void> open(WidgetTester tester, {TargetPlatform? platform}) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    engine = FakeEngineClient();
    operations = OperationsController(engine);
    addTearDown(() async {
      operations.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: platform),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ActionResultToasts(
          operations: operations,
          child: Builder(
            builder: (context) => TextButton(
              onPressed: () => previewAndRun(context, operations, _keep),
              child: const Text('redeploy'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('redeploy'));
    await tester.pump();
  }

  Future<void> planned(WidgetTester tester, ActionPreview preview) async {
    final id = 'plan-${engine.sentOfType<PlanAction>().length}';
    engine.emit(ActionPlanned(id, preview));
    await tester.pumpAndSettle();
  }

  testWidgets('the preview lists the orphans and says the operation '
      'continues on the server', (tester) async {
    await open(tester);
    await planned(tester, _preview(_keep));

    expect(find.text("Containers the stack's files no longer name"), findsOne);
    expect(find.text('shop-cache-1'), findsOneWidget);
    expect(
      find.textContaining('continues if you leave or the connection drops'),
      findsOneWidget,
    );
    expect(
      find.text('Runs as deploy through docker /var/run/docker.sock'),
      findsOne,
    );
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });

  testWidgets('removing the orphans plans again and asks for the name', (
    tester,
  ) async {
    await open(tester);
    await planned(tester, _preview(_keep));

    await tester.tap(find.text('Also remove these containers'));
    await tester.pump();
    final asked = engine.sentOfType<PlanAction>().cast<PlanAction>();
    expect(asked.map((p) => (p.intent as RedeployStack).removeOrphans), [
      false,
      true,
    ]);

    await planned(tester, _preview(_remove));
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(find.textContaining('--remove-orphans'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget, reason: 'typed name');
  });

  testWidgets('each warning is worded', (tester) async {
    await open(tester);
    await planned(
      tester,
      _preview(_keep, warnings: PlanWarning.values.toSet()),
    );
    expect(find.textContaining('enabled only by a compose profile'), findsOne);
    expect(find.textContaining('could not list every profile'), findsOne);
    expect(find.textContaining('when you log out'), findsOneWidget);
  });

  testWidgets('without orphans there is no switch', (tester) async {
    await open(tester);
    await planned(tester, _preview(_keep, orphans: const []));
    expect(find.byType(SwitchListTile), findsNothing);
    expect(
      find.text("Containers the stack's files no longer name"),
      findsNothing,
    );
  });

  testWidgets('on iOS the result shows on return', (tester) async {
    await open(tester, platform: TargetPlatform.iOS);
    await planned(tester, _preview(_keep));
    expect(find.textContaining('when you come back'), findsOneWidget);
  });

  testWidgets('a started operation toasts that it started', (tester) async {
    await open(tester);
    await planned(tester, _preview(_keep));
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.succeeded,
        operationId: '0123456789abcdef',
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Started on the server: shop'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });
}
