// The action framework (03 §8.5, §8.6, M4 E20): the operations controller
// pairs the engine's answers with the app's requests, the preview shows
// exactly what runs and confirms by tier, the result toasts word each end,
// and read-only hides every action entry point.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/actions/action_preview.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart';
import 'support/fake_engine.dart';

const _intent = UnitAction(
  'srv-1',
  unit: 'sshd.service',
  verb: SystemctlVerb.restart,
);

ActionPreview _preview({
  ConfirmationTier tier = ConfirmationTier.typedPhrase,
}) => ActionPreview(
  intent: _intent,
  targetName: 'sshd.service',
  steps: [
    ShellStep([
      'systemctl',
      '--no-ask-password',
      'restart',
      '--',
      'sshd.service',
    ], elevated: true),
  ],
  requiredLevel: RequiredLevel.admin,
  runner: const RunnerFacts(
    identity: 'root',
    credentials: RunnerCredentials.adminPassword,
  ),
  requiredTier: tier,
  hostWrites: const [HostWriteRow.loginRecords],
  danger: const [
    DangerFinding(
      severity: DangerSeverity.critical,
      pattern: 'systemctl restart sshd',
      explanation: 'Restarting sshd can drop your session.',
      line: 1,
    ),
  ],
  impact: const PlanImpact(ImpactKind.dropsSession),
  ownership: const PlanOwnership('Coolify'),
  protected: ProtectedReason.sessionPath,
);

Widget _app(Widget home, {OperationsController? operations}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: operations == null
      ? home
      : ActionResultToasts(operations: operations, child: home),
);

void main() {
  group('OperationsController', () {
    late FakeEngineClient engine;
    late OperationsController operations;

    setUp(() {
      engine = FakeEngineClient();
      operations = OperationsController(engine);
      addTearDown(() async {
        operations.dispose();
        await engine.close();
      });
    });

    test('a plan answers with the preview, or the refusal', () async {
      final ready = operations.plan(_intent);
      expect(engine.sentOfType<PlanAction>(), hasLength(1));
      expect(() => operations.plan(_intent), throwsStateError);
      engine.emit(ActionPlanned('plan-1', _preview()));
      final answer = await ready as PlanReady;
      expect(answer.planId, 'plan-1');
      expect(operations.targetOf('plan-1'), 'sshd.service');

      final refused = operations.plan(_intent);
      engine.emit(
        const ActionRefused(ActionRefusalReason.readOnly, intent: _intent),
      );
      expect(
        (await refused as PlanRefused).reason,
        ActionRefusalReason.readOnly,
      );
    });

    test('a run follows its progress to its end', () async {
      final ends = <(String, RunState)>[];
      operations.ends.listen(ends.add);
      operations.run(
        'plan-1',
        const ActionConfirmation(tier: ConfirmationTier.acknowledge),
      );
      expect(
        engine.sentOfType<RunAction>().cast<RunAction>().single.planId,
        'plan-1',
      );

      engine.emit(
        const ActionProgress(planId: 'plan-1', stepIndex: 0, stepCount: 2),
      );
      await pumpEventQueue();
      expect(operations.runOf('plan-1'), isA<RunInProgress>());

      engine
        ..emit(
          const ActionFinished(
            planId: 'plan-1',
            outcome: ActionOutcome.succeeded,
          ),
        )
        ..emit(
          const ActionRefused(ActionRefusalReason.stalePlan, planId: 'plan-2'),
        );
      await pumpEventQueue();
      expect(ends.map((e) => e.$1), ['plan-1', 'plan-2']);
      expect(ends.last.$2, isA<RunRefused>());
    });

    test('a stopped engine answers a pending plan with no link', () async {
      final pending = operations.plan(_intent);
      await engine.close();
      expect((await pending as PlanRefused).reason, ActionRefusalReason.noLink);
      expect(
        (await operations.plan(_intent) as PlanRefused).reason,
        ActionRefusalReason.noLink,
      );
    });
  });

  group('the preview', () {
    Future<List<ActionConfirmation?>> open(
      WidgetTester tester,
      ActionPreview preview, {
      Size size = const Size(1280, 900),
    }) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final results = <ActionConfirmation?>[];
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  results.add(await showActionPreview(context, preview)),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('shows exactly what runs, with the root badge, the risk '
        'facts, the runner and the host writes', (tester) async {
      await open(tester, _preview());
      expect(find.byType(Dialog), findsOneWidget);
      final step = _preview().steps.single as ShellStep;
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        step.commandLine,
      );
      expect(step.commandLine, contains('sshd.service'));
      expect(find.text('root'), findsOneWidget);
      expect(
        find.byTooltip('This step runs as root through admin mode.'),
        findsOneWidget,
      );
      expect(
        find.text('Critical: Restarting sshd can drop your session.'),
        findsOneWidget,
      );
      expect(
        find.text('Protected: your connection to the server runs through it.'),
        findsOneWidget,
      );
      expect(
        find.text('This can drop your connection to the server.'),
        findsOneWidget,
      );
      expect(find.textContaining('Managed by Coolify.'), findsOneWidget);
      expect(find.text('Runs as root'), findsOneWidget);
      expect(find.text('Uses the admin mode password.'), findsOneWidget);
      expect(
        find.text('Login records, as every SSH command leaves'),
        findsOneWidget,
      );
    });

    testWidgets('tier 2 runs only once the target\'s name is typed exactly, '
        'by Run or Enter', (tester) async {
      final results = await open(tester, _preview());
      final run = find.widgetWithText(FilledButton, 'Run');
      expect(tester.widget<FilledButton>(run).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'sshd.servic');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(results, isEmpty, reason: 'Enter does nothing until it matches');
      expect(tester.widget<FilledButton>(run).onPressed, isNull);

      await tester.enterText(find.byType(TextField), 'sshd.service');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(results.single?.tier, ConfirmationTier.typedPhrase);
      expect(results.single?.phrase, 'sshd.service');
    });

    testWidgets('tier 1 names the target, and Escape cancels', (tester) async {
      final results = await open(
        tester,
        _preview(tier: ConfirmationTier.acknowledge),
      );
      expect(find.text('This acts on sshd.service.'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(results, [null]);
    });

    testWidgets('a phone gets a bottom sheet', (tester) async {
      final results = await open(
        tester,
        _preview(tier: ConfirmationTier.acknowledge),
        size: const Size(400, 800),
      );
      expect(find.byType(BottomSheet), findsOneWidget);
      await tester.ensureVisible(find.text('Run'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Run'));
      await tester.pumpAndSettle();
      expect(results.single?.tier, ConfirmationTier.acknowledge);
    });
  });

  testWidgets('previewAndRun plans, confirms, runs and toasts the result', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final engine = FakeEngineClient();
    final operations = OperationsController(engine);
    addTearDown(() async {
      operations.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => previewAndRun(context, operations, _intent),
            child: const Text('restart'),
          ),
        ),
        operations: operations,
      ),
    );

    await tester.tap(find.text('restart'));
    await tester.pump();
    engine.emit(
      ActionPlanned('plan-1', _preview(tier: ConfirmationTier.acknowledge)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();
    expect(
      engine.sentOfType<RunAction>().cast<RunAction>().single.confirmation.tier,
      ConfirmationTier.acknowledge,
    );
    expect(find.text('Running on sshd.service'), findsOneWidget);

    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.failed,
        failure: ActionFailure.revalidation,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(
        'sshd.service did not finish: the target changed since the preview.',
      ),
      findsOneWidget,
    );

    // A refused plan says why, and shows no preview.
    await tester.tap(find.text('restart'));
    await tester.pump();
    engine.emit(
      const ActionRefused(ActionRefusalReason.observeOnly, intent: _intent),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(
      find.text('Turn on Allow actions for this server first.'),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 10));
  });

  group('the action entry registry (SAF-06)', () {
    const allowed = SafetyPolicy(
      servers: {'srv-1': ServerSafety(management: true)},
    );
    final hiding = <String, SafetyPolicy?>{
      'without safety preferences': null,
      'observe-only': const SafetyPolicy(),
      'read-only server': const SafetyPolicy(
        servers: {'srv-1': ServerSafety(management: true, readOnly: true)},
      ),
      'global read-only': const SafetyPolicy(
        globalReadOnly: true,
        servers: {'srv-1': ServerSafety(management: true)},
      ),
    };

    Future<void> pumpEntries(WidgetTester tester, SafetyPolicy? policy) async {
      final entries = ListView(
        children: [
          for (final point in ActionEntryPoint.values)
            ActionEntry(
              serverId: 'srv-1',
              point: point,
              child: Text('entry ${point.name}'),
            ),
        ],
      );
      if (policy == null) {
        await tester.pumpWidget(_app(entries));
        return;
      }
      final safety = SafetyController(initial: policy, apply: (_) {});
      addTearDown(safety.dispose);
      await tester.pumpWidget(
        _app(SafetyScope(safety: safety, child: entries)),
      );
    }

    testWidgets('a server whose actions are allowed shows every entry', (
      tester,
    ) async {
      await pumpEntries(tester, allowed);
      for (final point in ActionEntryPoint.values) {
        expect(find.text('entry ${point.name}'), findsOneWidget);
      }
    });

    for (final MapEntry(key: name, value: policy) in hiding.entries) {
      testWidgets('$name hides every entry', (tester) async {
        await pumpEntries(tester, policy);
        expect(find.textContaining('entry '), findsNothing);
      });
    }
  });

  group('goldens', () {
    setUpAll(() async {
      if (!goldensCompareHere) return;
      await loadGoldenFonts();
      // The steps' monospace stack drawn in the SDK's Roboto, so the
      // golden shows their text rather than the test font's boxes.
      final roboto = File(
        '${Platform.environment['FLUTTER_ROOT']}/bin/cache/artifacts/'
        'material_fonts/Roboto-Regular.ttf',
      ).readAsBytesSync();
      await (FontLoader(
        klabautermannThemeStyle.monoFontFamilies.first,
      )..addFont(Future.value(ByteData.sublistView(roboto)))).load();
    });

    for (final brightness in Brightness.values) {
      testWidgets('the preview in the ${brightness.name} theme', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(640, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final theme = chartTheme(brightness, fontFamily: goldenFontFamily);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: RepaintBoundary(
              key: const ValueKey('preview'),
              child: Material(
                color: theme.colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: ActionPreviewView(preview: _preview()),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await expectLater(
          find.byKey(const ValueKey('preview')),
          matchesGoldenFile('goldens/action_preview_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
