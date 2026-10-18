// Admin mode in the app (03 §8.2, SAF-02, E19b): the header's chip asks
// the engine to turn it on or off and follows the engine's states, tinted
// while it is on; the notices word why it failed or ended; read-only
// disables the chip.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/ui/server_header.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';

const _managed = SafetyPolicy(
  servers: {'srv-1': ServerSafety(management: true)},
);

Finder _inHeader(Finder finder) =>
    find.descendant(of: find.byType(ServerHeader), matching: finder);

FilterChip _chip(WidgetTester tester) =>
    tester.widget<FilterChip>(_inHeader(find.byType(FilterChip)));

Future<AppHarness> _openWeb1(
  WidgetTester tester, {
  SafetyPolicy policy = _managed,
}) async {
  final safety = SafetyController(initial: policy, apply: (_) {});
  addTearDown(safety.dispose);
  final harness = await pumpApp(
    tester,
    servers: twoServers,
    safety: safety,
    admin: true,
  );
  await tester.tap(find.text('web-1'));
  await tester.pumpAndSettle();
  return harness;
}

void main() {
  testWidgets('the chip turns admin mode on and off, following the '
      'engine\'s states', (tester) async {
    final harness = await _openWeb1(tester);
    expect(_inHeader(find.text('Admin mode')), findsOneWidget);
    expect(_chip(tester).selected, isFalse);

    await tester.tap(_inHeader(find.text('Admin mode')));
    await tester.pumpAndSettle();
    expect(
      harness.engine.sentOfType<SetAdminMode>().cast<SetAdminMode>().map(
        (r) => (r.serverId, r.enabled),
      ),
      [('srv-1', true)],
    );

    harness.engine.emit(
      const AdminModeState('srv-1', AdminModePhase.awaitingPassword),
    );
    await tester.pumpAndSettle();
    expect(_inHeader(find.text('Turning on admin mode')), findsOneWidget);
    expect(_chip(tester).selected, isTrue);

    harness.engine.emit(
      AdminModeState(
        'srv-1',
        AdminModePhase.on,
        expiresAt: DateTime.now().add(const Duration(minutes: 15)),
      ),
    );
    await tester.pumpAndSettle();
    expect(_inHeader(find.textContaining('Admin mode until ')), findsOneWidget);
    expect(
      _inHeader(
        find.text('Admin mode is on: actions you confirm here run as root.'),
      ),
      findsOneWidget,
    );
    final scheme = Theme.of(
      tester.element(find.byType(ServerHeader)),
    ).colorScheme;
    expect(_chip(tester).selectedColor, scheme.errorContainer);

    await tester.tap(_inHeader(find.byType(FilterChip)));
    await tester.pumpAndSettle();
    expect(
      harness.engine
          .sentOfType<SetAdminMode>()
          .cast<SetAdminMode>()
          .last
          .enabled,
      isFalse,
    );
  });

  testWidgets('says why admin mode failed or ended', (tester) async {
    final harness = await _openWeb1(tester);
    harness.engine.emit(
      const AdminModeState(
        'srv-1',
        AdminModePhase.failed,
        failure: AdminFailure.notInSudoers,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _inHeader(find.text('Your account on this server may not use sudo.')),
      findsOneWidget,
    );
    expect(_chip(tester).selected, isFalse);

    harness.engine.emit(
      const AdminModeState(
        'srv-1',
        AdminModePhase.expired,
        ended: AdminEnd.background,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      _inHeader(
        find.text(
          'Admin mode ended when Klabautermann went to the background.',
        ),
      ),
      findsOneWidget,
    );
  });

  testWidgets('read-only disables the chip; observe-only hides it', (
    tester,
  ) async {
    await _openWeb1(
      tester,
      policy: const SafetyPolicy(
        globalReadOnly: true,
        servers: {'srv-1': ServerSafety(management: true)},
      ),
    );
    expect(_chip(tester).onSelected, isNull);
    expect(
      find.byTooltip(
        'Admin mode is not available while the server is read-only.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('a server whose actions are not allowed has no chip', (
    tester,
  ) async {
    await _openWeb1(tester, policy: const SafetyPolicy());
    expect(_inHeader(find.byType(FilterChip)), findsNothing);
  });

  test('a stopped engine forgets every state and sends nothing more', () async {
    final engine = FakeEngineClient();
    final admin = AdminController(engine);
    addTearDown(admin.dispose);
    engine.emit(AdminModeState('srv-1', AdminModePhase.on));
    await pumpEventQueue();
    expect(admin.isActive('srv-1'), isTrue);

    await engine.close();
    await pumpEventQueue();
    expect(admin.stateFor('srv-1'), isNull);
    admin.setEnabled('srv-1', enabled: true);
    expect(engine.sentOfType<SetAdminMode>(), isEmpty);
  });
}
