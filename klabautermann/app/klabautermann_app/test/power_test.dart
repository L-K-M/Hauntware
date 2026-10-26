// SYS-03's Power section: reboot and shut down in admin mode, each behind
// the host name typed, and the wait for a rebooted server to answer again,
// which a `core` reading of a later boot ends.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart'
    show OperationsScope;
import 'package:klabautermann_app/ui/actions/action_preview.dart'
    show ActionResultToasts;
import 'package:klabautermann_app/ui/admin_mode_chip.dart' show AdminScope;
import 'package:klabautermann_app/ui/power.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _server = 'srv-1';

final _bootBefore = DateTime.utc(2026, 10, 20, 8);

Sample _core(DateTime bootedAt, {int seq = 1}) => Sample(
  serverId: _server,
  stream: SampleStream.core,
  seq: seq,
  at: DateTime.utc(2026, 10, 26),
  result: CoreResult(bootedAt: bootedAt),
);

ActionPreview _preview(PowerVerb verb) => ActionPreview(
  intent: PowerAction(_server, verb),
  targetName: 'web-01',
  steps: [
    ShellStep(['systemctl', verb.name], elevated: true, endsLink: true),
  ],
  requiredLevel: RequiredLevel.admin,
  runner: const RunnerFacts(
    identity: 'root',
    credentials: RunnerCredentials.adminPassword,
  ),
  requiredTier: ConfirmationTier.typedPhrase,
  hostWrites: const [HostWriteRow.loginRecords],
  impact: PlanImpact(
    verb == PowerVerb.reboot ? ImpactKind.restartsHost : ImpactKind.stopsHost,
  ),
);

void main() {
  late FakeEngineClient engine;
  late AdminController admin;
  late OperationsController operations;
  late SafetyController safety;
  late ValueNotifier<Sample?> core;
  late DateTime now;

  setUp(() {
    engine = FakeEngineClient();
    admin = AdminController(engine);
    operations = OperationsController(engine);
    safety = SafetyController(
      initial: const SafetyPolicy(
        servers: {_server: ServerSafety(management: true)},
      ),
      apply: (_) {},
    );
    core = ValueNotifier(_core(_bootBefore));
    now = DateTime.utc(2026, 10, 26, 12);
  });

  tearDown(() async {
    admin.dispose();
    operations.dispose();
    safety.dispose();
    core.dispose();
    await engine.close();
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ActionResultToasts(
          operations: operations,
          child: Scaffold(
            body: SafetyScope(
              safety: safety,
              child: OperationsScope(
                operations: operations,
                child: AdminScope(
                  admin: admin,
                  child: PowerSection(
                    serverId: _server,
                    core: core,
                    now: () => now,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Taps [button], confirms the preview by typing the host name and
  /// runs it as plan-1.
  Future<void> confirm(
    WidgetTester tester,
    String button,
    PowerVerb verb,
  ) async {
    await tester.tap(find.text(button));
    await tester.pump();
    final plan = engine.sentOfType<PlanAction>().last as PlanAction;
    expect(plan.intent, isA<PowerAction>());
    expect((plan.intent as PowerAction).verb, verb);
    engine.emit(ActionPlanned('plan-1', _preview(verb)));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'web-01');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    final run = engine.sentOfType<RunAction>().single as RunAction;
    expect(run.confirmation.phrase, 'web-01');
  }

  testWidgets('reboot and shut down show only in admin mode', (tester) async {
    await pump(tester);
    expect(
      find.text('Turn on admin mode to reboot or shut down this server.'),
      findsOneWidget,
    );
    expect(find.text('Reboot'), findsNothing);

    engine.emit(const AdminModeState(_server, AdminModePhase.on));
    await tester.pumpAndSettle();
    expect(find.text('Reboot'), findsOneWidget);
    expect(find.text('Shut down'), findsOneWidget);
  });

  testWidgets('a reboot the host took waits for a later boot and says how '
      'long it took; the same boot does not end the wait', (tester) async {
    await pump(tester);
    engine.emit(const AdminModeState(_server, AdminModePhase.on));
    await tester.pumpAndSettle();
    await confirm(tester, 'Reboot', PowerVerb.reboot);

    // The run is still going: nothing waits yet.
    expect(find.textContaining('Waiting for the server'), findsNothing);

    engine.emit(
      const ActionFinished(planId: 'plan-1', outcome: ActionOutcome.succeeded),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.text(
        'Rebooting. Waiting for the server to answer again: '
        '0 seconds so far.',
      ),
      findsOneWidget,
    );
    expect(find.text('Reboot'), findsNothing);

    now = now.add(const Duration(seconds: 30));
    // A reading of the old boot, its btime stepped by a second, is no
    // new boot.
    core.value = _core(_bootBefore.add(const Duration(seconds: 1)), seq: 2);
    await tester.pump(const Duration(seconds: 1));
    expect(
      find.text(
        'Rebooting. Waiting for the server to answer again: '
        '30 seconds so far.',
      ),
      findsOneWidget,
    );

    now = now.add(const Duration(seconds: 60));
    core.value = _core(now.subtract(const Duration(seconds: 20)), seq: 3);
    await tester.pump();
    expect(
      find.text('The server answered again 90 seconds after the reboot.'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Reboot'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a shutdown the host took says it stays off, and a failed one '
      'leaves the buttons', (tester) async {
    await pump(tester);
    engine.emit(const AdminModeState(_server, AdminModePhase.on));
    await tester.pumpAndSettle();
    await confirm(tester, 'Shut down', PowerVerb.poweroff);
    engine.emit(
      const ActionFinished(planId: 'plan-1', outcome: ActionOutcome.succeeded),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.text(
        'The server is shutting down. It stays off until someone starts it.',
      ),
      findsOneWidget,
    );
    expect(find.text('Shut down'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a reboot the host refused leaves no wait', (tester) async {
    await pump(tester);
    engine.emit(const AdminModeState(_server, AdminModePhase.on));
    await tester.pumpAndSettle();
    await confirm(tester, 'Reboot', PowerVerb.reboot);
    engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.failed,
        failure: ActionFailure.stepFailed,
        exitCode: 1,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Waiting for the server'), findsNothing);
    expect(find.text('Reboot'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  test('a later boot is one btime apart by more than its jitter, or after '
      'the reboot was asked for when the old boot is unknown', () {
    final started = DateTime.utc(2026, 10, 26, 12);
    expect(
      isLaterBoot(
        _bootBefore.add(const Duration(seconds: 1)),
        before: _bootBefore,
        startedAt: started,
      ),
      isFalse,
    );
    expect(
      isLaterBoot(
        started.add(const Duration(seconds: 5)),
        before: _bootBefore,
        startedAt: started,
      ),
      isTrue,
    );
    expect(isLaterBoot(_bootBefore, before: null, startedAt: started), isFalse);
    expect(
      isLaterBoot(
        started.add(const Duration(seconds: 5)),
        before: null,
        startedAt: started,
      ),
      isTrue,
    );
  });
}
