import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/alert_rules_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/pin_publication_controller.dart';
import 'package:klabautermann_app/controllers/server_prefs_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

/// Controllers over an engine that ended by itself: its events closed,
/// while a request sent after that is dropped without an error, as a
/// dead isolate's port drops it. Nothing will answer such a request, so
/// each one must settle at once rather than wait forever.
void main() {
  late FakeEngineClient engine;

  setUp(() => engine = FakeEngineClient());
  tearDown(() => engine.close());

  const settles = Duration(seconds: 1);

  test('an alert rule write after the engine ended fails', () async {
    final rules = AlertRulesController(engine);
    addTearDown(rules.dispose);
    await engine.endEvents();

    await expectLater(
      rules.remove('rule-1').timeout(settles),
      throwsA(
        isA<AlertRuleNotSavedException>().having(
          (e) => e.failure,
          'failure',
          isNull,
        ),
      ),
    );
  });

  test('a preferences write after the engine ended fails', () async {
    final prefs = ServerPrefsController(engine);
    addTearDown(prefs.dispose);
    await engine.endEvents();

    await expectLater(
      prefs.write('srv-1', null).timeout(settles),
      throwsA(isA<ServerPrefsNotSavedException>()),
    );
  });

  test('a pin publication change after the engine ended fails', () async {
    final pins = PinPublicationController(
      engine,
      initial: const PinPublicationState(release: 'r1', asserted: false),
    );
    addTearDown(pins.dispose);
    await engine.endEvents();

    await expectLater(
      pins.setAsserted(true).timeout(settles),
      throwsA(isA<PinPublicationNotChangedException>()),
    );
  });

  test('a run in progress ends when the engine ends', () async {
    final operations = OperationsController(engine);
    addTearDown(operations.dispose);
    final ended = operations.ends.first;
    operations.run(
      'plan-1',
      const ActionConfirmation(tier: ConfirmationTier.none),
    );

    await engine.endEvents();

    final (planId, state) = await ended.timeout(settles);
    expect(planId, 'plan-1');
    expect(
      state,
      isA<RunRefused>().having(
        (s) => s.reason,
        'reason',
        ActionRefusalReason.noLink,
      ),
    );
    expect(operations.runOf('plan-1'), isA<RunRefused>());
  });

  test('a run started after the engine ended ends at once', () async {
    final operations = OperationsController(engine);
    addTearDown(operations.dispose);
    await engine.endEvents();
    final ended = operations.ends.first;

    operations.run(
      'plan-2',
      const ActionConfirmation(tier: ConfirmationTier.none),
    );

    final (planId, state) = await ended.timeout(settles);
    expect(planId, 'plan-2');
    expect(state, isA<RunRefused>());
    expect(engine.sentOfType<RunAction>(), isEmpty);
  });
}
