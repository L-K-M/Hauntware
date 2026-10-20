// The remote editor (03 §8.5, SAF-12, X-05; M5 plan M17): the read, the
// review's diff and format checks, the save through the action preview,
// and the conflict sheet when the file changed under the edit.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/actions/action_preview.dart';
import 'package:klabautermann_app/ui/docker/stack_file_view.dart';
import 'package:klabautermann_app/ui/edit/remote_editor.dart';
import 'package:klabautermann_app/ui/server_safety.dart' show SafetyScope;
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_editor/planchette_editor.dart' show PlanchetteEditor;

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
const _path = '/srv/web/compose.yaml';
const _target = FileTarget(_path);
const _original = 'services:\n  web:\n    image: nginx:1.27\n';

EditContent _content(String text, {String sha = 'base'}) => EditContent(
  text: text,
  sha256: sha,
  privileged: false,
  uid: 1000,
  gid: 1000,
  mode: 420,
);

ActionPreview _preview(EditFile intent) => ActionPreview(
  intent: intent,
  targetName: _path,
  steps: [
    ShellStep(['cp', '-p', '--', _path, '/backups/x']),
  ],
  requiredLevel: RequiredLevel.login,
  runner: const RunnerFacts(identity: 'deploy'),
  requiredTier: ConfirmationTier.acknowledge,
  hostWrites: const [HostWriteRow.editTarget, HostWriteRow.userBackups],
);

final class _Editor {
  _Editor(this.engine);

  final FakeEngineClient engine;

  List<ReadEditable> get reads => engine.sentOfType<ReadEditable>().cast();

  List<EditFile> get plans => [
    for (final plan in engine.sentOfType<PlanAction>().cast<PlanAction>())
      plan.intent as EditFile,
  ];

  Future<void> answer(WidgetTester tester, EditReadResult result) async {
    final read = reads.last;
    engine.emit(
      EditRead(
        serverId: read.serverId,
        requestId: read.requestId,
        result: result,
      ),
    );
    await tester.pumpAndSettle();
  }

  String text(WidgetTester tester) => tester
      .widget<PlanchetteEditor>(find.byType(PlanchetteEditor))
      .controller
      .text
      .text;

  /// Opens the review and lets its diff isolate answer, which a widget
  /// test's fake time does not run.
  Future<void> review(WidgetTester tester) async {
    await tester.tap(find.text('Review changes'));
    await tester.pump();
    await settleDiff(tester);
  }

  Future<void> type(WidgetTester tester, String text) async {
    tester
            .widget<PlanchetteEditor>(find.byType(PlanchetteEditor))
            .controller
            .text
            .text =
        text;
    await tester.pumpAndSettle();
  }
}

/// Waits in real time for the review's diff isolate, then settles.
Future<void> settleDiff(WidgetTester tester) async {
  for (
    var i = 0;
    i < 50 && find.text('Comparing…').evaluate().isNotEmpty;
    i++
  ) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<_Editor> _pump(
  WidgetTester tester, {
  Widget? home,
  Widget Function(FakeEngineClient engine)? homeOver,
  SafetyPolicy? policy,
}) async {
  tester.view.physicalSize = const Size(1280, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final operations = OperationsController(engine);
  addTearDown(() async {
    operations.dispose();
    await engine.close();
  });
  final safety = policy == null
      ? null
      : SafetyController(initial: policy, apply: (_) {});
  if (safety != null) addTearDown(safety.dispose);

  await tester.pumpWidget(
    MaterialApp(
      theme: GhostTheme.light(klabautermannThemeStyle),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      // As in the app, the scopes sit above the navigator, so dialogs see
      // them.
      builder: (context, child) {
        final scoped = OperationsScope(
          operations: operations,
          child: ActionResultToasts(operations: operations, child: child!),
        );
        return safety == null
            ? scoped
            : SafetyScope(safety: safety, child: scoped);
      },
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(16),
          child:
              homeOver?.call(engine) ??
              home ??
              const RemoteEditor(serverId: _serverId, target: _target),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _Editor(engine);
}

void main() {
  testWidgets('reads the file, and offers Review only once it changed', (
    tester,
  ) async {
    final editor = await _pump(tester);

    expect(editor.reads.single.target, _target);
    expect(find.text('Reading the file…'), findsOneWidget);
    await editor.answer(tester, _content(_original));

    expect(editor.text(tester), _original);
    final review = find.widgetWithText(FilledButton, 'Review changes');
    expect(tester.widget<FilledButton>(review).onPressed, isNull);
    expect(find.text('Not saved'), findsNothing);

    await editor.type(tester, '$_original    restart: always\n');
    expect(tester.widget<FilledButton>(review).onPressed, isNotNull);
    expect(find.text('Not saved'), findsOneWidget);

    // Back to the server's text is nothing to save.
    await editor.type(tester, _original);
    expect(tester.widget<FilledButton>(review).onPressed, isNull);
  });

  testWidgets('a failed read says why, and one that may pass offers to read '
      'again', (tester) async {
    final editor = await _pump(tester);
    await editor.answer(tester, const EditReadFailed(EditReadFailure.noLink));

    expect(find.text('There is no connection to this server.'), findsOneWidget);
    await tester.tap(find.text('Read again'));
    await tester.pump();
    expect(editor.reads, hasLength(2));

    await editor.answer(tester, const EditReadFailed(EditReadFailure.notText));
    expect(find.text('This file is not text.'), findsOneWidget);
    expect(find.text('Read again'), findsNothing);
  });

  testWidgets('the review shows the diff and the format problems, and saves '
      'against the hash it read', (tester) async {
    final editor = await _pump(tester);
    await editor.answer(tester, _content(_original, sha: 'abc123'));
    // A key set twice in one mapping.
    const edited =
        'services:\n  web:\n    image: nginx:1.28\n    image: nginx:1.29\n';
    await editor.type(tester, edited);

    await editor.review(tester);

    expect(find.text('-    image: nginx:1.27'), findsOneWidget);
    expect(find.text('+    image: nginx:1.28'), findsOneWidget);
    expect(find.textContaining('Line 4: key set again'), findsOneWidget);
    await tester.tap(find.text('Save anyway'));
    await tester.pumpAndSettle();

    final plan = editor.plans.single;
    expect(plan.serverId, _serverId);
    expect(plan.target, _target);
    expect(plan.text, edited);
    expect(plan.baseSha256, 'abc123');
  });

  testWidgets('a target changed before planning opens the conflict sheet; '
      '"Discard mine" takes the server\'s text', (tester) async {
    final editor = await _pump(tester);
    await editor.answer(tester, _content(_original));
    await editor.type(tester, '$_original# mine\n');
    await editor.review(tester);
    await tester.tap(find.text('Save to server'));
    await tester.pumpAndSettle();

    final plan = editor.plans.single;
    editor.engine.emit(
      ActionRefused(ActionRefusalReason.targetChanged, intent: plan),
    );
    await tester.pumpAndSettle();
    expect(find.text('The file changed on the server'), findsOneWidget);

    await tester.tap(find.text('Discard mine'));
    await tester.pumpAndSettle();
    expect(editor.reads, hasLength(2));
    await editor.answer(tester, _content('$_original# theirs\n', sha: 'b'));

    expect(editor.text(tester), '$_original# theirs\n');
    expect(find.text('Not saved'), findsNothing);
  });

  testWidgets('a file changed right before the rename opens the conflict '
      'sheet; "Reload and compare" keeps the user\'s text and reviews it '
      'against the server\'s', (tester) async {
    final editor = await _pump(tester);
    await editor.answer(tester, _content(_original));
    await editor.type(tester, '$_original# mine\n');
    await editor.review(tester);
    await tester.tap(find.text('Save to server'));
    await tester.pump();
    editor.engine.emit(ActionPlanned('plan-1', _preview(editor.plans.single)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    editor.engine.emit(
      const ActionFinished(
        planId: 'plan-1',
        outcome: ActionOutcome.failed,
        failure: ActionFailure.revalidation,
        revalidation: RevalidationFailure.contentChanged,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reload and compare'));
    await tester.pumpAndSettle();
    await editor.answer(tester, _content('$_original# theirs\n', sha: 'b'));
    await settleDiff(tester);

    expect(editor.text(tester), '$_original# mine\n');
    expect(find.text('-# theirs'), findsOneWidget);
    expect(find.text('+# mine'), findsOneWidget);
    await tester.tap(find.text('Save to server'));
    await tester.pumpAndSettle();
    expect(editor.plans.last.baseSha256, 'b');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a finished save reads the new base, so nothing is left '
      'unsaved', (tester) async {
    final editor = await _pump(tester);
    await editor.answer(tester, _content(_original));
    const mine = '$_original# mine\n';
    await editor.type(tester, mine);
    await editor.review(tester);
    await tester.tap(find.text('Save to server'));
    await tester.pump();
    editor.engine.emit(ActionPlanned('plan-1', _preview(editor.plans.single)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Run'));
    await tester.pumpAndSettle();

    editor.engine.emit(
      const ActionFinished(planId: 'plan-1', outcome: ActionOutcome.succeeded),
    );
    await tester.pumpAndSettle();
    expect(editor.reads, hasLength(2));
    await editor.answer(tester, _content(mine, sha: 'saved'));

    expect(editor.text(tester), mine);
    expect(find.text('Not saved'), findsNothing);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('closing with changes asks first', (tester) async {
    final editor = await _pump(
      tester,
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () =>
              openRemoteEditor(context, serverId: _serverId, target: _target),
          child: const Text('open'),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await editor.answer(tester, _content(_original));
    expect(find.text('Edit compose.yaml'), findsOneWidget);
    await editor.type(tester, '$_original# mine\n');

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Discard your changes?'), findsOneWidget);
    await tester.tap(find.text('Keep editing'));
    await tester.pumpAndSettle();
    expect(find.byType(PlanchetteEditor), findsOneWidget);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Discard changes'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PlanchetteEditor), findsNothing);
  });

  testWidgets('a read for the new base that fails keeps the user\'s text', (
    tester,
  ) async {
    final editor = await _pump(tester);
    await editor.answer(tester, _content(_original));
    await editor.type(tester, '$_original# mine\n');
    await editor.review(tester);
    await tester.tap(find.text('Save to server'));
    await tester.pumpAndSettle();
    editor.engine.emit(
      ActionRefused(
        ActionRefusalReason.targetChanged,
        intent: editor.plans.single,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reload and compare'));
    await tester.pumpAndSettle();

    await editor.answer(tester, const EditReadFailed(EditReadFailure.noLink));

    expect(editor.text(tester), '$_original# mine\n');
    expect(find.text('There is no connection to this server.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });

  group("a stack file's Edit (STK-07)", () {
    final web = dockerStack('web', [
      dockerService('db', [dockerContainer('w1', name: 'web-db-1')]),
    ]);

    Widget view(FakeEngineClient engine) {
      final monitoring = MonitoringController(engine);
      addTearDown(monitoring.dispose);
      return StackFileView(
        monitoring: monitoring,
        serverId: _serverId,
        project: web,
      );
    }

    testWidgets('opens the file in the editor where actions are allowed', (
      tester,
    ) async {
      final editor = await _pump(
        tester,
        homeOver: view,
        policy: const SafetyPolicy(
          servers: {_serverId: ServerSafety(management: true)},
        ),
      );

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(editor.reads.single.target, _target);
      await editor.answer(tester, _content(_original));
      expect(editor.text(tester), _original);
    });

    testWidgets('is hidden on a read-only server', (tester) async {
      await _pump(
        tester,
        homeOver: view,
        policy: const SafetyPolicy(
          servers: {_serverId: ServerSafety(management: true, readOnly: true)},
        ),
      );
      expect(find.text('Edit'), findsNothing);
    });
  });
}
