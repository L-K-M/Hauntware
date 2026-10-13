import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/harness.dart';

/// Whether [request] could push catalog records or write server-side
/// state. Pull-only from the start (03 D14): the catalog applies pulled
/// records and never seals dirty ones, so no UI path may send these.
bool _pushesOrWrites(EngineRequest request) => switch (request) {
  // Enrollment and sync rounds write catalog state; a round can seal and
  // push once the engine's push policy opens (D14 keeps it closed).
  EnrollSync() || RunSyncRound() => true,
  // The action path mutates a host and its operation records.
  PlanAction() || RunAction() => true,
  // Alert acknowledgement and dismissal write `klabautermann:alertstatus`
  // catalog records (v1.x, D42).
  HandleAlert() => true,
  _ => false,
};

void main() {
  testWidgets('no surface sends a request that pushes or writes server '
      'records', (tester) async {
    final harness = await pumpApp(
      tester,
      size: const Size(1280, 800),
      servers: twoServers,
    );

    // Exercise every control the scaffold ships: select a server, collapse
    // the section, open the settings route and switch the theme, then run
    // a sampler subscription the way the monitor set will drive it (03
    // §10.1). The traffic this produces is the traffic to judge.
    await tester.tap(find.text('web-1'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Hide section'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    harness.monitoring.subscribe('srv-1', const {
      Collector.overview,
    }, const Duration(seconds: 2));
    harness.monitoring.unsubscribe('srv-1');
    await tester.pumpAndSettle();

    // Prove the drive reached the engine, then judge every request.
    expect(harness.engine.sent, isNotEmpty);
    for (final request in harness.engine.sent) {
      expect(
        _pushesOrWrites(request),
        isFalse,
        reason:
            'the app sent $request, which can push or write records '
            '(D14 pull-only)',
      );
    }
  });
}
