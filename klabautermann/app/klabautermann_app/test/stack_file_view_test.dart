import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ghost_theme/ghost_theme.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/theme/app_theme.dart';
import 'package:klabautermann_app/ui/docker/container_details.dart'
    show ContainerInspectionScope, InspectedContainer;
import 'package:klabautermann_app/ui/docker/stack_file_view.dart';
import 'package:klabautermann_app/ui/docker/stacks_panel.dart';
import 'package:klabautermann_app/ui/docker/stacks_view.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:planchette_editor/planchette_editor.dart' show PlanchetteEditor;

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';

final _now = DateTime(2026, 10, 15, 14, 30);

/// The web stack: a compose file, a recorded environment file and the
/// working directory's `.env`.
final _web = dockerStack(
  'web',
  [
    dockerService('db', [dockerContainer('w1', name: 'web-db-1')]),
  ],
  environmentFiles: ['/srv/web/db.env'],
);

const _compose = '/srv/web/compose.yaml';
const _dbEnv = '/srv/web/db.env';
const _dotEnv = '/srv/web/.env';

/// [_compose] as the engine sends it: a password and a URL credential
/// masked (03 §8.9).
DockerStackFilePayload _composeFile({bool truncated = false, int? size}) =>
    DockerStackFilePayload(
      project: 'web',
      path: _compose,
      size: size ?? 160,
      truncated: truncated,
      text: [
        MaskedValue.plain(
          'services:\n  db:\n    image: postgres:16\n    environment:\n'
          '      POSTGRES_PASSWORD: ',
        ),
        MaskedValue.secret('hunter2'),
        MaskedValue.plain('\n      BACKUP_URL: s3://backup:'),
        MaskedValue.secret('s3cret'),
        MaskedValue.plain('@store/web\n'),
      ],
    );

const _maskedCompose =
    'services:\n  db:\n    image: postgres:16\n    environment:\n'
    '      POSTGRES_PASSWORD: ********\n'
    '      BACKUP_URL: s3://backup:********@store/web\n';

const _revealedCompose =
    'services:\n  db:\n    image: postgres:16\n    environment:\n'
    '      POSTGRES_PASSWORD: hunter2\n'
    '      BACKUP_URL: s3://backup:s3cret@store/web\n';

final class _View {
  _View(this.engine);

  final FakeEngineClient engine;

  List<DockerQuery> get queries => engine.sentOfType<DockerQuery>().cast();

  /// The file reads sent, oldest first.
  List<DockerStackFileQuery> get reads => [
    for (final query in queries)
      if (query.query case final DockerStackFileQuery read) read,
  ];

  Future<void> answer(WidgetTester tester, DockerPayload payload) async {
    engine.emit(dockerAnswer(queries.last, payload));
    await tester.pumpAndSettle();
  }
}

Future<_View> _pump(
  WidgetTester tester, {
  ComposeProject? project,
  Widget Function(MonitoringController monitoring)? child,
}) async {
  tester.view.physicalSize = const Size(900, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final engine = FakeEngineClient();
  final monitoring = MonitoringController(engine, now: () => _now);
  addTearDown(() async {
    monitoring.dispose();
    await engine.close();
  });

  await tester.pumpWidget(
    MaterialApp(
      theme: GhostTheme.light(klabautermannThemeStyle),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body:
            child?.call(monitoring) ??
            Padding(
              padding: const EdgeInsets.all(16),
              child: StackFileView(
                monitoring: monitoring,
                serverId: _serverId,
                project: project ?? _web,
              ),
            ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return _View(engine);
}

String _editorText(WidgetTester tester) => tester
    .widget<PlanchetteEditor>(find.byType(PlanchetteEditor))
    .controller
    .text
    .text;

/// 03 §7.16 STK-04 and M11: a verified stack's files, read-only and
/// masked, with the 30 s reveal of 03 §8.9.
void main() {
  test('a stack offers its compose files, its environment files and its '
      'working directory\'s .env, each once', () {
    expect(stackFilesOf(_web), [
      (path: _compose, role: StackFileRole.compose),
      (path: _dbEnv, role: StackFileRole.environment),
      (path: _dotEnv, role: StackFileRole.environment),
    ]);
    expect(
      stackFilesOf(
        dockerStack(
          'app',
          const [],
          workingDir: '/opt/app/',
          configFiles: ['/opt/app/compose.yaml', '/opt/app/override.yaml'],
          environmentFiles: ['/opt/app/.env'],
        ),
      ).map((file) => file.path),
      ['/opt/app/compose.yaml', '/opt/app/override.yaml', '/opt/app/.env'],
    );
    expect(stackFileName('/srv/web/compose.yaml'), 'compose.yaml');
  });

  testWidgets('reads the first file and shows it masked in a locked '
      'editor, and nothing but the file', (tester) async {
    final view = await _pump(tester);
    expect(view.reads, hasLength(1));
    expect(view.reads.single.project, 'web');
    expect(view.reads.single.path, _compose);
    expect(find.text('Reading compose.yaml…'), findsOneWidget);

    await view.answer(tester, _composeFile());
    expect(_editorText(tester), _maskedCompose);
    final editor = tester.widget<PlanchetteEditor>(
      find.byType(PlanchetteEditor),
    );
    expect(editor.controller.editingLocked, isTrue);
    expect(editor.editingLocked, isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('planchette.document')))
          .readOnly,
      isTrue,
    );
    expect(
      find.bySemanticsLabel(RegExp(r'^compose\.yaml, read-only')),
      findsOneWidget,
    );

    // Typing changes nothing.
    await tester.tap(find.byType(PlanchetteEditor));
    await tester.enterText(
      find.byKey(const ValueKey('planchette.document')),
      'x',
    );
    await tester.pumpAndSettle();
    expect(_editorText(tester), _maskedCompose);

    expect(
      find.text(
        '2 values are masked. Reveal values shows them for 30 seconds.',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('hunter2'), findsNothing);
    // The view asks for the file alone: `compose config` output, whose
    // interpolation holds the secrets, is never read or shown.
    expect(
      view.queries.map((query) => query.query),
      everyElement(isA<DockerStackFileQuery>()),
    );
  });

  testWidgets('reveals the values for 30 seconds, masks them again early '
      'on request and when the app turns inactive', (tester) async {
    final view = await _pump(tester);
    await view.answer(tester, _composeFile());

    await tester.tap(find.text('Reveal values'));
    await tester.pumpAndSettle();
    expect(_editorText(tester), _revealedCompose);
    expect(find.text('Hide values'), findsOneWidget);

    await tester.pump(const Duration(seconds: 29));
    expect(_editorText(tester), _revealedCompose);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(_editorText(tester), _maskedCompose);
    expect(find.text('Reveal values'), findsOneWidget);

    await tester.tap(find.text('Reveal values'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide values'));
    await tester.pumpAndSettle();
    expect(_editorText(tester), _maskedCompose);

    await tester.tap(find.text('Reveal values'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pumpAndSettle();
    expect(_editorText(tester), _maskedCompose);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(_editorText(tester), _maskedCompose);
    expect(view.reads, hasLength(1), reason: 'a reveal reads nothing');
  });

  testWidgets('another file masks what was revealed and reads that one, '
      'dropping a late answer for the first', (tester) async {
    final view = await _pump(tester);
    final first = view.queries.single;
    await tester.tap(find.widgetWithText(ChoiceChip, '.env'));
    await tester.pumpAndSettle();
    expect(view.reads.last.path, _dotEnv);

    // The compose file's answer comes too late.
    view.engine.emit(dockerAnswer(first, _composeFile()));
    await tester.pumpAndSettle();
    expect(find.byType(PlanchetteEditor), findsNothing);
    expect(find.text('Reading .env…'), findsOneWidget);

    await view.answer(
      tester,
      DockerStackFilePayload(
        project: 'web',
        path: _dotEnv,
        size: 12,
        text: [MaskedValue.plain('TZ=UTC\nDEBUG=0\n')],
      ),
    );
    expect(_editorText(tester), 'TZ=UTC\nDEBUG=0\n');
    expect(find.text('Reveal values'), findsNothing, reason: 'nothing masked');

    await tester.tap(find.widgetWithText(ChoiceChip, 'compose.yaml'));
    await tester.pumpAndSettle();
    await view.answer(tester, _composeFile());
    await tester.tap(find.text('Reveal values'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'db.env'));
    await tester.pumpAndSettle();
    expect(find.byType(PlanchetteEditor), findsNothing);
    await tester.tap(find.widgetWithText(ChoiceChip, 'compose.yaml'));
    await tester.pumpAndSettle();
    await view.answer(tester, _composeFile());
    expect(_editorText(tester), _maskedCompose);
  });

  testWidgets('says how much of a file over 1 MiB shows', (tester) async {
    final view = await _pump(tester);
    await view.answer(tester, _composeFile(truncated: true, size: 1468006));
    expect(
      find.text(
        'This file is 1.4 MiB, so only its complete lines within the first '
        '1 MiB show.',
      ),
      findsOneWidget,
    );
    expect(_editorText(tester), _maskedCompose);
  });

  testWidgets('says why the engine read no file', (tester) async {
    for (final (failure, words) in [
      (
        StackFileFailure.unknownStack,
        'No container belongs to this stack any more.',
      ),
      (
        StackFileFailure.notVerified,
        'This stack\'s source is no longer verified, so its files do not '
            'show.',
      ),
      (
        StackFileFailure.notStackFile,
        'This path is none of the stack\'s files.',
      ),
      (StackFileFailure.notFound, 'There is no file at this path on the host.'),
      (
        StackFileFailure.permissionDenied,
        'Your account cannot read this file. Admin mode reads it through '
            'sudo.',
      ),
      (
        StackFileFailure.notRegularFile,
        'This path is a link, a directory or another special file, which is '
            'not read.',
      ),
      (
        StackFileFailure.readFailed,
        'The file could not be read, or it changed while it was read.',
      ),
    ]) {
      final view = await _pump(tester);
      await view.answer(tester, DockerStackFileFailed(failure));
      expect(find.text(words), findsOneWidget, reason: failure.name);
      expect(find.byType(PlanchetteEditor), findsNothing);
      expect(
        find.text('Try again'),
        // Once admin mode is on, a refused read goes through sudo.
        switch (failure) {
          StackFileFailure.readFailed ||
          StackFileFailure.permissionDenied => findsOneWidget,
          _ => findsNothing,
        },
        reason: failure.name,
      );
      await tester.pumpWidget(const SizedBox());
    }
  });

  testWidgets('a read that could not run says why and reads again on '
      'retry', (tester) async {
    final view = await _pump(tester);
    await view.answer(
      tester,
      const DockerQueryFailed(
        DockerQueryFailure.connectionFailed,
        detail: 'connection reset',
      ),
    );
    expect(
      find.text('The connection to the engine failed while reading the file.'),
      findsOneWidget,
    );
    expect(find.text('connection reset'), findsOneWidget);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(view.reads, hasLength(2));
    expect(view.reads.last.path, _compose);
    await view.answer(tester, _composeFile());
    expect(_editorText(tester), _maskedCompose);
  });

  group('the overview', () {
    Future<_View> overview(
      WidgetTester tester,
      StackVerdict verdict, {
      bool desktop = false,
    }) async {
      final view = await _pump(
        tester,
        child: (monitoring) {
          final overview = StackOverview(
            monitoring: monitoring,
            serverId: _serverId,
            project: 'web',
          );
          if (!desktop) return overview;
          return ContainerInspectionScope(
            inspection: ValueNotifier<InspectedContainer?>(null),
            child: overview,
          );
        },
      );
      view.engine.emit(
        dockerStackList(
          _serverId,
          [_web],
          at: _now,
          verdicts: {'web': verdict},
        ),
      );
      await tester.pumpAndSettle();
      return view;
    }

    testWidgets('an unverified stack offers no files', (tester) async {
      for (final verdict in const [
        StackVerifying(),
        StackUnverified(StackUnverifiedReason.hashMismatch),
        StackSourceNotOnHost(deployedBy: ExternalManager.dockge),
      ]) {
        final view = await overview(tester, verdict);
        expect(find.text('View files'), findsNothing);
        expect(
          find.text('Its files show only once its source is verified.'),
          findsOneWidget,
        );
        expect(view.reads, isEmpty);
        await tester.pumpWidget(const SizedBox());
      }
    });

    testWidgets('a verified stack opens its files on a page on a phone', (
      tester,
    ) async {
      final view = await overview(tester, const StackVerified());
      await tester.tap(find.text('View files'));
      await tester.pumpAndSettle();
      expect(find.byType(StackFileView), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('web: files'),
        ),
        findsOneWidget,
      );
      expect(view.reads.single.path, _compose);
      await view.answer(tester, _composeFile());

      await tester.tap(find.text('Reveal values'));
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(StackFileView), findsNothing);
      // The reveal's timer went with the view.
      await tester.pump(const Duration(seconds: 30));
    });

    testWidgets('a verified stack opens its files in a dialog on the '
        'desktop', (tester) async {
      final view = await overview(tester, const StackVerified(), desktop: true);
      await tester.tap(find.text('View files'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.byType(StackFileView),
        ),
        findsOneWidget,
      );
      expect(find.text('web: files'), findsOneWidget);
      expect(view.reads, hasLength(1));

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });
  });
}
