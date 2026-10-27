// OV-08: the Overview's quick actions and the unit page's pin that adds a
// service's restart to them.
import 'dart:io' show FileSystemException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/pinned_services.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
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
  }) async {
    final engine = FakeEngineClient();
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
            child: PinnedServicesScope(pins: pins, child: child!),
          ),
        ),
        home: Scaffold(body: child),
      ),
    );
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
}
