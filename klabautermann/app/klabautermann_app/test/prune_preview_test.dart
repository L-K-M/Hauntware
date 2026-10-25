// The prune preview in the app (M6 N12, DKE-05, IMG-06): what the prune
// removes, with sizes and the bytes it frees, what it keeps and why, and
// the typed confirmation it asks for.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_preview.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';

const _prune = PruneDocker('srv-1', kind: DockerPruneKind.images, all: true);

ActionPreview _preview(PrunePreview prune) => ActionPreview(
  intent: _prune,
  targetName: 'images-all',
  steps: [
    ApiStep(
      method: 'POST',
      path: '/v1.52/images/prune',
      query: {'filters': '{"dangling":["false"]}'},
    ),
  ],
  requiredLevel: RequiredLevel.login,
  runner: const RunnerFacts(
    identity: 'deploy',
    engine: 'docker /var/run/docker.sock',
  ),
  requiredTier: ConfirmationTier.typedPhrase,
  hostWrites: const [HostWriteRow.engineState],
  prune: prune,
);

void main() {
  late FakeEngineClient engine;

  Future<void> open(WidgetTester tester, PrunePreview prune) async {
    tester.view.physicalSize = const Size(1280, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    engine = FakeEngineClient();
    final operations = OperationsController(engine);
    addTearDown(() async {
      operations.dispose();
      await engine.close();
    });
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => previewAndRun(context, operations, _prune),
            child: const Text('prune'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('prune'));
    await tester.pump();
    engine.emit(ActionPlanned('plan-0', _preview(prune)));
    await tester.pumpAndSettle();
  }

  testWidgets('lists what the prune removes with sizes, what it frees and '
      'what it keeps, and asks for the typed name', (tester) async {
    await open(
      tester,
      PrunePreview(
        removes: const [
          PruneItem('app:old', size: 2 * 1024 * 1024),
          PruneItem('0123456789ab', size: 1024),
        ],
        kept: const [
          PruneKept('app:1', PruneExemption.inUse),
          PruneKept('bridge', PruneExemption.builtin),
        ],
        freed: 2 * 1024 * 1024 + 1024,
      ),
    );

    expect(find.text('Removes 2 objects'), findsOneWidget);
    expect(find.text('Frees 2 MiB'), findsOneWidget);
    expect(find.text('app:old (2 MiB)'), findsOneWidget);
    expect(find.text('0123456789ab (1 KiB)'), findsOneWidget);
    expect(find.text('Kept'), findsOneWidget);
    expect(find.text('app:1: in use'), findsOneWidget);
    expect(find.text("bridge: the engine's own"), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget, reason: 'typed name');
  });

  testWidgets('the build cache shows its count and bytes, and no list', (
    tester,
  ) async {
    await open(tester, PrunePreview(removes: const [], count: 3, freed: 0));
    expect(find.text('Removes 3 objects'), findsOneWidget);
    expect(find.text('Frees 0 B'), findsOneWidget);
    expect(find.text('Kept'), findsNothing);
  });
}
