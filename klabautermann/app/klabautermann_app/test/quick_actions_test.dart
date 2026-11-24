// OV-08: the Overview's quick actions and the unit page's pin that adds a
// service's restart to them.
import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/pinned_services.dart';
import 'package:klabautermann_app/controllers/power_waits.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/admin_mode_chip.dart' show AdminScope;
import 'package:klabautermann_app/ui/power.dart' show PowerWaitsScope;
import 'package:klabautermann_app/ui/quick_actions.dart';
import 'package:klabautermann_app/ui/server_safety.dart' show SafetyScope;
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _serverId = 'srv-1';
const _nginx = PinnedService('nginx.service');

void main() {
  test('a pin is stored as scope and unit, and an unreadable form is left '
      'out', () {
    const user = PinnedService('sync.service', scope: UnitScope.user);
    expect(user.encoded, 'user/sync.service');
    expect(PinnedService.parse(user.encoded), user);
    expect(PinnedService.parse('system/nginx.service'), _nginx);
    for (final bad in ['nginx.service', 'root/x.service', 'system/', '/x']) {
      expect(PinnedService.parse(bad), isNull, reason: bad);
    }
  });

  test('a toggle pins and unpins, takes no pin past the most, and says '
      'when it was not saved', () async {
    final saved = <List<String>>[];
    final pins = PinnedServicesController(
      save: (_, encoded) async => saved.add(encoded),
    );
    addTearDown(pins.dispose);

    await pins.toggle(_serverId, _nginx);
    expect(pins.pinsFor(_serverId), [_nginx]);
    await pins.toggle(_serverId, _nginx);
    expect(pins.pinsFor(_serverId), isEmpty);
    expect(saved, [
      ['system/nginx.service'],
      <String>[],
    ]);

    for (var i = 0; i < kPinnedServicesMax + 1; i++) {
      await pins.toggle(_serverId, PinnedService('unit-$i.service'));
    }
    expect(pins.pinsFor(_serverId), hasLength(kPinnedServicesMax));
    expect(pins.fullFor(_serverId), isTrue);

    final failing = PinnedServicesController(
      save: (_, _) async => throw const FileSystemException('disk full'),
    );
    addTearDown(failing.dispose);
    await expectLater(
      failing.toggle(_serverId, _nginx),
      throwsA(isA<PinnedServicesNotSavedException>()),
    );
    expect(failing.pinsFor(_serverId), [_nginx], reason: 'it still applies');
  });

  Future<(FakeEngineClient, PinnedServicesController)> pump(
    WidgetTester tester, {
    required Widget child,
    bool management = true,
    bool adminMode = true,
  }) async {
    final engine = FakeEngineClient();
    final admin = AdminController(engine);
    final operations = OperationsController(engine);
    final safety = SafetyController(
      initial: SafetyPolicy(
        servers: {_serverId: ServerSafety(management: management)},
      ),
      apply: (_) {},
    );
    final pins = PinnedServicesController();
    addTearDown(() async {
      pins.dispose();
      admin.dispose();
      safety.dispose();
      operations.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => SafetyScope(
          safety: safety,
          child: OperationsScope(
            operations: operations,
            child: AdminScope(
              admin: admin,
              child: PinnedServicesScope(pins: pins, child: child!),
            ),
          ),
        ),
        home: Scaffold(body: child),
      ),
    );
    if (adminMode) {
      engine.emit(const AdminModeState(_serverId, AdminModePhase.on));
      await tester.pumpAndSettle();
    }
    return (engine, pins);
  }

  testWidgets('a unit\'s pin adds its restart to the quick actions, which '
      'plan it as the Services tab would', (tester) async {
    final (engine, pins) = await pump(
      tester,
      child: Column(
        children: [
          const PinServiceButton(
            serverId: _serverId,
            unit: 'nginx.service',
            scope: UnitScope.system,
          ),
          Builder(
            builder: (context) => quickActionsShown(context, _serverId)
                ? const QuickActionsCard(serverId: _serverId)
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
    expect(find.text('Reboot'), findsOneWidget);
    expect(find.text('Restart nginx.service'), findsNothing);

    await tester.tap(find.byTooltip("Pin to the Overview's quick actions"));
    await tester.pumpAndSettle();
    expect(pins.pinsFor(_serverId), [_nginx]);

    await tester.tap(find.text('Restart nginx.service'));
    await tester.pump();
    final planned = engine.sentOfType<PlanAction>().cast<PlanAction>();
    expect(planned, hasLength(1));
    final intent = planned.single.intent as UnitAction;
    expect(
      (intent.unit, intent.verb, intent.scope),
      ('nginx.service', SystemctlVerb.restart, UnitScope.system),
    );
  });

  testWidgets('without management or a hand-off there is nothing to offer', (
    tester,
  ) async {
    late bool shown;
    await pump(
      tester,
      management: false,
      child: Builder(
        builder: (context) {
          shown = quickActionsShown(context, _serverId);
          return const SizedBox.shrink();
        },
      ),
    );
    expect(shown, isFalse);
    expect(
      actionsAllowedAt(
        tester.element(find.byType(Scaffold)),
        _serverId,
        ActionEntryPoint.power,
      ),
      isFalse,
    );
  });

  testWidgets('Reboot is offered in admin mode only, as the System tab does', (
    tester,
  ) async {
    late bool shown;
    final (engine, _) = await pump(
      tester,
      adminMode: false,
      child: Builder(
        builder: (context) {
          shown = quickActionsShown(context, _serverId);
          return shown
              ? const QuickActionsCard(serverId: _serverId)
              : const SizedBox.shrink();
        },
      ),
    );
    expect(shown, isFalse);
    expect(find.text('Reboot'), findsNothing);

    engine.emit(const AdminModeState(_serverId, AdminModePhase.on));
    await tester.pumpAndSettle();
    expect(shown, isTrue);
    expect(find.text('Reboot'), findsOneWidget);
  });

  testWidgets('a reboot from the card keeps the card with only its progress '
      'after admin mode ends, until the server is back (Q1)', (tester) async {
    final engine = FakeEngineClient();
    final admin = AdminController(engine);
    final operations = OperationsController(engine);
    final safety = SafetyController(
      initial: const SafetyPolicy(
        servers: {_serverId: ServerSafety(management: true)},
      ),
      apply: (_) {},
    );
    final bootBefore = DateTime.utc(2026, 10, 20, 8);
    var now = DateTime.utc(2026, 10, 26, 12);
    Sample core(DateTime bootedAt, int seq) => Sample(
      serverId: _serverId,
      stream: SampleStream.core,
      seq: seq,
      at: now,
      result: CoreResult(bootedAt: bootedAt),
    );
    final cores = ValueNotifier<Sample?>(core(bootBefore, 1));
    final waits = PowerWaits(
      core: (_) => cores,
      operations: operations,
      now: () => now,
    );
    addTearDown(() async {
      waits.dispose();
      cores.dispose();
      admin.dispose();
      safety.dispose();
      operations.dispose();
      await engine.close();
    });
    late bool shown;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => SafetyScope(
          safety: safety,
          child: OperationsScope(
            operations: operations,
            child: AdminScope(
              admin: admin,
              child: PowerWaitsScope(waits: waits, child: child!),
            ),
          ),
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) {
              shown = quickActionsShown(context, _serverId);
              return shown
                  ? const QuickActionsCard(serverId: _serverId)
                  : const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    engine.emit(const AdminModeState(_serverId, AdminModePhase.on));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Reboot'));
    await tester.pump();
    engine.emit(
      ActionPlanned(
        'plan-1',
        ActionPreview(
          intent: const PowerAction(_serverId, PowerVerb.reboot),
          targetName: 'web-01',
          steps: [
            ShellStep(
              const ['systemctl', 'reboot'],
              elevated: true,
              endsLink: true,
            ),
          ],
          requiredLevel: RequiredLevel.admin,
          runner: const RunnerFacts(
            identity: 'root',
            credentials: RunnerCredentials.adminPassword,
          ),
          requiredTier: ConfirmationTier.typedPhrase,
          hostWrites: const [HostWriteRow.loginRecords],
          impact: const PlanImpact(ImpactKind.restartsHost),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'web-01');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    // The run's progress bar never settles.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(engine.sentOfType<RunAction>(), hasLength(1));

    // The reboot drops the link, and admin mode ends with it, before the
    // host's answer: the card stays, with a bare progress bar and no
    // admin action.
    engine.emit(const AdminModeState(_serverId, AdminModePhase.off));
    await tester.pump();
    expect(shown, isTrue);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text('Reboot'), findsNothing);

    engine.emit(
      const ActionFinished(planId: 'plan-1', outcome: ActionOutcome.succeeded),
    );
    await tester.pump();
    await tester.pump();
    now = now.add(const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 1));
    expect(shown, isTrue);
    expect(
      find.text(
        'Rebooting. Waiting for the server to answer again: '
        '20 seconds so far.',
      ),
      findsOneWidget,
    );
    expect(find.text('Stop waiting'), findsOneWidget);
    expect(find.text('Reboot'), findsNothing);

    // Back on a later boot: nothing is left to offer outside admin mode.
    now = now.add(const Duration(seconds: 40));
    cores.value = core(now.subtract(const Duration(seconds: 15)), 2);
    await tester.pump();
    expect(shown, isFalse);
    expect(find.byType(QuickActionsCard), findsNothing);
    // Let the finished wait's short hold expire rather than leave its
    // timer pending.
    await tester.pump(kPowerWaitBackHold);
  });

  testWidgets('a reboot not back in time leaves the card outside admin '
      'mode', (tester) async {
    final engine = FakeEngineClient();
    final operations = OperationsController(engine);
    final cores = ValueNotifier<Sample?>(null);
    final waits = PowerWaits(core: (_) => cores, operations: operations);
    addTearDown(() async {
      waits.dispose();
      cores.dispose();
      operations.dispose();
      await engine.close();
    });
    late bool shown;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PowerWaitsScope(
          waits: waits,
          child: Builder(
            builder: (context) {
              shown = quickActionsShown(context, _serverId);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    operations.run(
      'plan-1',
      const ActionConfirmation(
        tier: ConfirmationTier.typedPhrase,
        phrase: 'web-01',
      ),
    );
    waits.start(_serverId, 'plan-1', PowerVerb.reboot);
    await tester.pump();
    expect(shown, isTrue);

    engine.emit(
      const ActionFinished(planId: 'plan-1', outcome: ActionOutcome.succeeded),
    );
    await tester.pump();
    expect(waits.waitFor(_serverId)!.phase, PowerWaitPhase.waiting);
    expect(shown, isTrue);

    await tester.pump(kRebootWaitTimeout);
    expect(waits.waitFor(_serverId)!.phase, PowerWaitPhase.notBack);
    expect(shown, isFalse);
  });

  testWidgets('the reboot timeout counts from the host taking the run', (
    tester,
  ) async {
    final engine = FakeEngineClient();
    final operations = OperationsController(engine);
    final cores = ValueNotifier<Sample?>(null);
    final waits = PowerWaits(core: (_) => cores, operations: operations);
    addTearDown(() async {
      waits.dispose();
      cores.dispose();
      operations.dispose();
      await engine.close();
    });
    late bool shown;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: PowerWaitsScope(
          waits: waits,
          child: Builder(
            builder: (context) {
              shown = quickActionsShown(context, _serverId);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    operations.run(
      'plan-1',
      const ActionConfirmation(
        tier: ConfirmationTier.typedPhrase,
        phrase: 'web-01',
      ),
    );
    waits.start(_serverId, 'plan-1', PowerVerb.reboot);
    await tester.pump();
    expect(shown, isTrue);

    // The run is taken only after a full timeout span has passed.
    await tester.pump(kRebootWaitTimeout + const Duration(minutes: 1));
    expect(waits.waitFor(_serverId)!.phase, PowerWaitPhase.running);

    engine.emit(
      const ActionFinished(planId: 'plan-1', outcome: ActionOutcome.succeeded),
    );
    await tester.pump();
    expect(waits.waitFor(_serverId)!.phase, PowerWaitPhase.waiting);
    expect(shown, isTrue);

    await tester.pump(kRebootWaitTimeout - const Duration(seconds: 1));
    expect(waits.waitFor(_serverId)!.phase, PowerWaitPhase.waiting);
    await tester.pump(const Duration(seconds: 1));
    expect(waits.waitFor(_serverId)!.phase, PowerWaitPhase.notBack);
    expect(shown, isFalse);
  });
}
