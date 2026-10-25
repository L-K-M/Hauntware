// Docker actions in the app (M4 E22): which verbs each container state
// offers and what they plan (CTR-02, CTR-05, CTR-06), image removal and
// its forced form (IMG-02), a volume's create and remove (VOL-02), a
// stack's verbs (STK-03), and the "Turn on
// admin mode" button where something needs root (SAF-02).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/admin_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/actions/docker_actions.dart';
import 'package:klabautermann_app/ui/admin_mode_chip.dart';
import 'package:klabautermann_app/ui/docker/images_view.dart';
import 'package:klabautermann_app/ui/docker/networks_view.dart';
import 'package:klabautermann_app/ui/docker/volumes_view.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/charts.dart';
import 'support/fake_engine.dart';

const _srv = 'srv-1';
const _managed = SafetyPolicy(servers: {_srv: ServerSafety(management: true)});

ContainerSummary _container(String state) =>
    ContainerSummary(id: 'c1', names: const ['/web'], state: state);

final class _Harness {
  _Harness(this.engine);

  final FakeEngineClient engine;

  List<ActionIntent> get planned => [
    for (final PlanAction(:intent)
        in engine.sentOfType<PlanAction>().cast<PlanAction>())
      intent,
  ];

  /// Answers the open plan with a refusal, so the next one may start.
  Future<void> refuse(WidgetTester tester) async {
    engine.emit(
      ActionRefused(ActionRefusalReason.readOnly, intent: planned.last),
    );
    await tester.pumpAndSettle();
  }
}

Future<_Harness> _pump(
  WidgetTester tester,
  Widget child, {
  SafetyPolicy safety = _managed,
  ThemeData? theme,
}) async {
  final engine = FakeEngineClient();
  final operations = OperationsController(engine);
  final admin = AdminController(engine);
  final policy = SafetyController(initial: safety, apply: (_) {});
  addTearDown(() async {
    operations.dispose();
    admin.dispose();
    policy.dispose();
    await engine.close();
  });
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => SafetyScope(
        safety: policy,
        child: AdminScope(
          admin: admin,
          child: OperationsScope(operations: operations, child: child!),
        ),
      ),
      home: Scaffold(body: Center(child: child)),
    ),
  );
  return _Harness(engine);
}

void main() {
  group('container offers', () {
    test('each state offers its verbs, and only a stopped container is '
        'removed', () {
      expect(containerOffers('running'), [
        ContainerOffer.stop,
        ContainerOffer.restart,
        ContainerOffer.pause,
        ContainerOffer.kill,
      ]);
      expect(containerOffers('restarting'), [
        ContainerOffer.stop,
        ContainerOffer.kill,
      ]);
      expect(containerOffers('paused'), [
        ContainerOffer.unpause,
        ContainerOffer.kill,
      ]);
      for (final state in ['created', 'exited', 'dead', 'Exited']) {
        expect(containerOffers(state), [
          ContainerOffer.start,
          ContainerOffer.remove,
          ContainerOffer.removeVolumes,
        ], reason: state);
      }
      for (final state in ['removing', 'gone', null]) {
        expect(containerOffers(state), isEmpty, reason: '$state');
      }
    });

    test('each offer plans its intent, never a forced removal', () {
      final intents = {
        for (final offer in ContainerOffer.values)
          offer: containerIntent(_srv, 'c1', offer),
      };
      for (final (offer, verb) in [
        (ContainerOffer.start, ContainerVerb.start),
        (ContainerOffer.stop, ContainerVerb.stop),
        (ContainerOffer.restart, ContainerVerb.restart),
        (ContainerOffer.pause, ContainerVerb.pause),
        (ContainerOffer.unpause, ContainerVerb.unpause),
        (ContainerOffer.kill, ContainerVerb.kill),
      ]) {
        expect(
          intents[offer],
          isA<ContainerAction>()
              .having((a) => a.containerId, 'containerId', 'c1')
              .having((a) => a.verb, 'verb', verb)
              .having((a) => a.signal, 'signal', isNull),
        );
      }
      expect(
        intents[ContainerOffer.remove],
        isA<RemoveContainer>()
            .having((r) => r.volumes, 'volumes', isFalse)
            .having((r) => r.force, 'force', isFalse),
      );
      expect(
        intents[ContainerOffer.removeVolumes],
        isA<RemoveContainer>()
            .having((r) => r.volumes, 'volumes', isTrue)
            .having((r) => r.force, 'force', isFalse),
      );
    });

    test('an image in use is removed by force, an unused or uncounted one '
        'plainly', () {
      const image = ImageSummary(id: 'sha256:1');
      for (final (count, force) in [(2, true), (0, false), (null, false)]) {
        expect(
          imageIntent(_srv, ImageEntry(image, count)),
          isA<RemoveImage>()
              .having((r) => r.image, 'image', 'sha256:1')
              .having((r) => r.force, 'force', force),
          reason: '$count',
        );
      }
    });
  });

  group('buttons', () {
    testWidgets('a running container stops, restarts, pauses, is killed '
        'and gets any other signal', (tester) async {
      final h = await _pump(
        tester,
        ContainerActionButtons(
          serverId: _srv,
          container: _container('running'),
        ),
      );
      for (final label in ['Stop', 'Restart', 'Pause', 'Kill', 'Send signal']) {
        expect(find.text(label), findsOneWidget, reason: label);
      }
      expect(find.text('Remove'), findsNothing);

      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();
      await h.refuse(tester);
      await tester.tap(find.text('Send signal'));
      await tester.pumpAndSettle();
      expect(find.text('SIGKILL'), findsNothing);
      await tester.tap(find.text('SIGHUP'));
      await tester.pumpAndSettle();
      expect(h.planned, [
        isA<ContainerAction>().having(
          (a) => a.verb,
          'verb',
          ContainerVerb.stop,
        ),
        isA<ContainerAction>()
            .having((a) => a.verb, 'verb', ContainerVerb.kill)
            .having((a) => a.signal, 'signal', KillSignal.sighup),
      ]);
    });

    testWidgets('a stopped container starts and is removed, with its '
        'volumes too', (tester) async {
      final h = await _pump(
        tester,
        ContainerActionButtons(serverId: _srv, container: _container('exited')),
      );
      await tester.tap(find.text('Remove with volumes'));
      await tester.pumpAndSettle();
      expect(h.planned.single, isA<RemoveContainer>());
      expect((h.planned.single as RemoveContainer).volumes, isTrue);
    });

    testWidgets('a stack starts, stops and restarts', (tester) async {
      final h = await _pump(
        tester,
        const StackActionButtons(serverId: _srv, project: 'demo'),
      );
      await tester.tap(find.text('Restart'));
      await tester.pumpAndSettle();
      expect(
        h.planned.single,
        isA<StackAction>()
            .having((a) => a.project, 'project', 'demo')
            .having((a) => a.verb, 'verb', StackVerb.restart),
      );
    });

    testWidgets('the image button forces the removal of an image in use', (
      tester,
    ) async {
      final h = await _pump(
        tester,
        const ImageActionsButton(
          serverId: _srv,
          entry: ImageEntry(ImageSummary(id: 'sha256:1'), 1),
        ),
      );
      await tester.tap(find.byTooltip('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Force remove'));
      await tester.pumpAndSettle();
      expect((h.planned.single as RemoveImage).force, isTrue);
    });

    testWidgets('Create volume asks for a name and an optional driver, and '
        'plans only a name Docker takes', (tester) async {
      final h = await _pump(tester, const CreateVolumeButton(serverId: _srv));
      await tester.tap(find.text('Create volume…'));
      await tester.pumpAndSettle();

      final submit = find.widgetWithText(FilledButton, 'Continue');
      expect(tester.widget<FilledButton>(submit).onPressed, isNull);
      await tester.enterText(find.widgetWithText(TextField, 'Name'), '-bad');
      await tester.pumpAndSettle();
      expect(find.textContaining('starting with a letter or digit'), findsOne);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(h.planned, isEmpty);

      await tester.enterText(find.widgetWithText(TextField, 'Name'), 'cache');
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(
        h.planned.single,
        isA<CreateVolume>()
            .having((c) => c.name, 'name', 'cache')
            .having((c) => c.driver, 'driver', isNull),
      );
      await h.refuse(tester);

      await tester.tap(find.text('Create volume…'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Name'),
        'nfs-data',
      );
      await tester.enterText(find.widgetWithText(TextField, 'Driver'), 'nfs');
      await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
      await tester.pumpAndSettle();
      expect((h.planned.last as CreateVolume).driver, 'nfs');
    });

    testWidgets('the volume button plans its removal', (tester) async {
      final h = await _pump(
        tester,
        const VolumeActionsButton(
          serverId: _srv,
          entry: VolumeEntry(VolumeSummary(name: 'pgdata'), 0),
        ),
      );
      await tester.tap(find.byTooltip('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect((h.planned.single as RemoveVolume).name, 'pgdata');
    });

    testWidgets('the network button plans its removal, and a built-in '
        'network offers none', (tester) async {
      final h = await _pump(
        tester,
        const Column(
          children: [
            NetworkActionsButton(
              serverId: _srv,
              entry: NetworkEntry(
                NetworkSummary(id: 'n1', name: 'shop_default'),
                0,
              ),
            ),
            NetworkActionsButton(
              serverId: _srv,
              entry: NetworkEntry(NetworkSummary(id: 'n2', name: 'bridge'), 0),
            ),
          ],
        ),
      );
      expect(find.byTooltip('Actions'), findsOneWidget);
      await tester.tap(find.byTooltip('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect((h.planned.single as RemoveNetwork).networkId, 'n1');
    });

    testWidgets('observe-only and read-only offer none', (tester) async {
      for (final safety in [
        const SafetyPolicy(),
        const SafetyPolicy(
          servers: {_srv: ServerSafety(management: true, readOnly: true)},
        ),
        const SafetyPolicy(
          globalReadOnly: true,
          servers: {_srv: ServerSafety(management: true)},
        ),
      ]) {
        await _pump(
          tester,
          Column(
            children: [
              ContainerActionButtons(
                serverId: _srv,
                container: _container('running'),
              ),
              const StackActionButtons(serverId: _srv, project: 'demo'),
              const ImageActionsButton(
                serverId: _srv,
                entry: ImageEntry(ImageSummary(id: 'sha256:1'), 0),
              ),
              const VolumeActionsButton(
                serverId: _srv,
                entry: VolumeEntry(VolumeSummary(name: 'pgdata'), 0),
              ),
              const CreateVolumeButton(serverId: _srv),
              const NetworkActionsButton(
                serverId: _srv,
                entry: NetworkEntry(
                  NetworkSummary(id: 'n1', name: 'shop_default'),
                  0,
                ),
              ),
              const TurnOnAdminModeButton(serverId: _srv),
            ],
          ),
          safety: safety,
        );
        expect(find.byType(OutlinedButton), findsNothing);
        expect(find.byType(IconButton), findsNothing);
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  group('Turn on admin mode', () {
    testWidgets('asks the engine to turn admin mode on, and hides once it '
        'starts', (tester) async {
      final h = await _pump(
        tester,
        const TurnOnAdminModeButton(serverId: _srv),
      );
      await tester.tap(find.text('Turn on admin mode'));
      await tester.pump();
      expect(
        h.engine.sentOfType<SetAdminMode>().cast<SetAdminMode>().single,
        isA<SetAdminMode>()
            .having((s) => s.serverId, 'serverId', _srv)
            .having((s) => s.enabled, 'enabled', isTrue),
      );

      h.engine.emit(
        const AdminModeState(_srv, AdminModePhase.awaitingPassword),
      );
      await tester.pumpAndSettle();
      expect(find.text('Turn on admin mode'), findsNothing);
    });
  });

  group('goldens', () {
    setUpAll(() async {
      if (goldensCompareHere) await loadGoldenFonts();
    });

    for (final brightness in Brightness.values) {
      testWidgets('the buttons in the ${brightness.name} theme', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(420, 260);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final theme = chartTheme(brightness, fontFamily: goldenFontFamily);
        await _pump(
          tester,
          RepaintBoundary(
            key: const ValueKey('buttons'),
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    ContainerActionButtons(
                      serverId: _srv,
                      container: _container('running'),
                    ),
                    ContainerActionButtons(
                      serverId: _srv,
                      container: _container('exited'),
                    ),
                    const StackActionButtons(serverId: _srv, project: 'demo'),
                    const TurnOnAdminModeButton(serverId: _srv),
                  ],
                ),
              ),
            ),
          ),
          theme: theme,
        );
        await expectLater(
          find.byKey(const ValueKey('buttons')),
          matchesGoldenFile('goldens/docker_actions_${brightness.name}.png'),
        );
      }, skip: !goldensCompareHere);
    }
  });
}
