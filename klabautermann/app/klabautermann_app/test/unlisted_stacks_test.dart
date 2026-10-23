import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/stack_folders.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/docker/stacks_panel.dart';
import 'package:klabautermann_app/ui/docker/unlisted_stacks.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
final _now = DateTime(2026, 10, 15, 14, 30);

final _web = dockerStack(
  'web',
  [
    dockerService('app', [dockerContainer('w1', name: 'web-app-1')]),
  ],
  workingDir: '/opt/stacks/web',
  configFiles: [
    '/opt/stacks/web/compose.yaml',
    '/opt/stacks/shared/compose.web.yaml',
  ],
);

void main() {
  group('unlistedStacks (STK-08)', () {
    test("leaves out a listed stack's folder and the files it names, and "
        'groups the rest by folder, sorted', () {
      final found = unlistedStacks(
        [
          '/opt/stacks/web/compose.yaml',
          '/opt/stacks/web/compose.override.yaml',
          '/opt/stacks/shared/compose.web.yaml',
          '/opt/stacks/shared/compose.db.yaml',
          '/opt/stacks/blog/docker-compose.yml',
          '/opt/stacks/blog/compose.override.yml',
        ],
        [_web],
      );
      expect(
        [for (final stack in found) stack.folder],
        ['/opt/stacks/blog', '/opt/stacks/shared'],
      );
      expect(found.first.files, [
        '/opt/stacks/blog/compose.override.yml',
        '/opt/stacks/blog/docker-compose.yml',
      ]);
      expect(found.last.files, ['/opt/stacks/shared/compose.db.yaml']);
    });
  });

  group('parseStackFolders', () {
    test('takes one folder per line, dropping blanks and repeats', () {
      final parsed = parseStackFolders(
        ' /opt/stacks \n\n/srv/apps\n/opt/stacks\n',
      );
      expect(parsed.folders, ['/opt/stacks', '/srv/apps']);
      expect(parsed.problem, isNull);
      expect(parseStackFolders('').folders, isEmpty);
    });

    test('refuses a relative or climbing path, and too many', () {
      expect(
        parseStackFolders('/opt/stacks\nstacks').problem,
        StackFoldersProblem.notAbsolute,
      );
      expect(
        parseStackFolders('/opt/../etc').problem,
        StackFoldersProblem.notAbsolute,
      );
      expect(
        parseStackFolders(
          [
            for (var i = 0; i <= kStackScanDirectoriesMax; i++) '/s$i',
          ].join('\n'),
        ).problem,
        StackFoldersProblem.tooMany,
      );
    });
  });

  test('StackFolders saves each change, and none removes the entry', () async {
    final saved = <(String, List<String>)>[];
    final folders = StackFolders(
      stored: {
        'srv-2': ['/srv'],
      },
      save: (serverId, value) async => saved.add((serverId, value)),
    );
    expect(folders.foldersFor('srv-2'), ['/srv']);

    await folders.setFolders(_serverId, ['/opt/stacks']);
    await folders.setFolders('srv-2', const []);
    expect(folders.foldersFor(_serverId), ['/opt/stacks']);
    expect(folders.foldersFor('srv-2'), isEmpty);
    expect([for (final (id, _) in saved) id], [_serverId, 'srv-2']);
    expect(saved.first.$2, ['/opt/stacks']);
    expect(saved.last.$2, isEmpty);
  });

  group('the Stacks sub-tab', () {
    late FakeEngineClient engine;
    late List<(String, List<String>)> saved;

    Future<void> pump(
      WidgetTester tester, {
      Map<String, List<String>> stored = const {},
      List<ComposeProject>? stacks,
    }) async {
      tester.view.physicalSize = const Size(1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      saved = [];
      engine = FakeEngineClient();
      final monitoring = MonitoringController(
        engine,
        now: () => _now,
        stackFolders: StackFolders(
          stored: stored,
          save: (serverId, folders) async => saved.add((serverId, folders)),
        ),
      );
      addTearDown(() async {
        monitoring.dispose();
        await engine.close();
      });
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StacksPanel(
              monitoring: monitoring,
              serverId: _serverId,
              visible: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      engine.emit(dockerStackList(_serverId, stacks ?? [_web], at: _now));
      await tester.pumpAndSettle();
    }

    List<DockerQuery> scans() => [
      for (final query in engine.sentOfType<DockerQuery>().cast<DockerQuery>())
        if (query.query is DockerStackScanQuery) query,
    ];

    testWidgets('without folders it asks for them and scans nothing', (
      tester,
    ) async {
      await pump(tester);
      expect(find.text('Stacks without containers'), findsOneWidget);
      expect(find.textContaining('Name the folders'), findsOneWidget);
      expect(scans(), isEmpty);
    });

    testWidgets('chosen folders are kept and scanned, and the stacks no '
        'listed one accounts for show', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Choose folders'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '/opt/stacks\n/srv/apps',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(saved.single.$1, _serverId);
      expect(saved.single.$2, ['/opt/stacks', '/srv/apps']);
      expect(find.text('Folders: /opt/stacks, /srv/apps'), findsOneWidget);
      final scan = scans().single;
      expect((scan.query as DockerStackScanQuery).directories, [
        '/opt/stacks',
        '/srv/apps',
      ]);

      engine.emit(
        dockerAnswer(
          scan,
          DockerStackScanPayload([
            '/opt/stacks/blog/compose.yaml',
            '/opt/stacks/web/compose.yaml',
          ], incomplete: true),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('blog'), findsOneWidget);
      expect(find.text('/opt/stacks/blog/compose.yaml'), findsOneWidget);
      expect(
        find.text('A folder could not be read, so some stacks may be missing.'),
        findsOneWidget,
      );
    });

    testWidgets('stored folders scan as the tab opens; a server with no '
        'stacks still shows them, and Scan again scans again', (tester) async {
      await pump(
        tester,
        stored: {
          _serverId: ['/opt/stacks'],
        },
        stacks: const [],
      );
      expect(
        find.text('There are no compose stacks on this server.'),
        findsNothing,
      );
      final first = scans().single;
      engine.emit(dockerAnswer(first, DockerStackScanPayload(const [])));
      await tester.pumpAndSettle();
      expect(
        find.text('Every stack in these folders has containers.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Scan again'));
      await tester.pumpAndSettle();
      expect(scans(), hasLength(2));
    });

    testWidgets('a relative folder is refused in the dialog', (tester) async {
      await pump(tester);
      await tester.tap(find.text('Choose folders'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'stacks',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        find.text('Each folder must be an absolute path, such as /opt/stacks.'),
        findsOneWidget,
      );
      expect(saved, isEmpty);
    });
  });
}
