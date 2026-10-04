import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations_en.dart';
import 'package:poltergeist_app/services/archive_queue_tasks.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_file_ops.dart';
import 'package:poltergeist_app/services/registered_command.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/theme/family_hues.dart';
import 'package:poltergeist_app/ui/shell/shell_commands.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/pane_controller_test.dart' as controller_test;
import '../../support/fake_app_transfer_queue.dart';
import '../../support/fake_local_archive_job.dart';
import '../../support/test_panes.dart';

class _NoContext extends Fake implements BuildContext {}

Bookmark _server() {
  final now = DateTime.utc(2026, 9, 30);
  return Bookmark(
    id: 'srv-1',
    kind: BookmarkKind.remotePath,
    label: 'web.example.com',
    server: const BookmarkServerRef(
      identity: EmbeddedHostIdentity(
        host: 'web.example.com',
        port: 22,
        username: 'deploy',
        authMethod: AuthMethod.password,
      ),
    ),
    remotePath: '/srv',
    sortKey: 'srv-1',
    createdAt: now,
    updatedAt: now,
  );
}

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController pane;
  late WorkspaceController workspace;
  late FakeAppTransferQueue queue;
  late ArchiveQueueTasks archives;
  late List<FakeLocalArchiveJob> archiveJobs;
  late PaneFileOps fileOps;
  late List<Object> failures;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    pane = PaneController(paneTabId: 'pane.left', lanes: lanes);
    workspace = WorkspaceController(
      left: testPaneStrip(pane),
      right: testPaneStrip(
        PaneController(paneTabId: 'pane.right', lanes: lanes),
      ),
    );
    queue = FakeAppTransferQueue();
    failures = [];
    archiveJobs = [];
    archives = ArchiveQueueTasks.forTesting(
      createZip: ({required sourcePaths, required destinationPath}) {
        final job = FakeLocalArchiveJob(
          operation: LocalArchiveOperation.createZip,
        );
        archiveJobs.add(job);
        return job;
      },
      extractZip: ({required archivePath, required destinationPath}) {
        final job = FakeLocalArchiveJob(
          operation: LocalArchiveOperation.extractZip,
        );
        archiveJobs.add(job);
        return job;
      },
    );
    fileOps = PaneFileOps(queue, archives: archives);
  });

  tearDown(() async {
    workspace.dispose();
    for (final job in archiveJobs) {
      if (!job.isDone) job.fail(LocalArchiveErrorKind.cancelled);
    }
    await archives.dispose();
    for (final job in archiveJobs) {
      await job.close();
    }
    await queue.close();
  });

  Future<void> bindLocal() async {
    lanes.nextLocalChannel = controller_test.FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = const [
        RemoteFileEntry(
          path: '/home/tester/a.txt',
          name: 'a.txt',
          type: RemoteFileType.file,
          size: 3,
        ),
        RemoteFileEntry(
          path: '/home/tester/BUNDLE.ZIP',
          name: 'BUNDLE.ZIP',
          type: RemoteFileType.file,
          size: 12,
        ),
      ];
    await pane.openLocalHome();
    await pumpEventQueue();
  }

  Future<void> bindRemote() async {
    lanes.nextRemoteChannel = controller_test.FakePaneChannel('/srv')
      ..listings['/srv'] = const [
        RemoteFileEntry(
          path: '/srv/bundle.zip',
          name: 'bundle.zip',
          type: RemoteFileType.file,
          size: 12,
        ),
      ];
    await pane.connectRemote(_server(), initialPath: '/srv');
    await pumpEventQueue();
  }

  Future<void> bindNestedArchive() async {
    lanes.nextLocalChannel = controller_test.FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = const [
        RemoteFileEntry(
          path: '/home/tester/nested',
          name: 'nested',
          type: RemoteFileType.directory,
        ),
      ]
      ..listings['/home/tester/nested'] = const [
        RemoteFileEntry(
          path: '/home/tester/nested/bundle.zip',
          name: 'bundle.zip',
          type: RemoteFileType.file,
          size: 12,
        ),
      ];
    await pane.openLocalHome();
    await pumpEventQueue();
    pane.expandAt(0);
    await pumpEventQueue();
  }

  List<RegisteredCommand> commands() => buildShellCommands(
    workspace: workspace,
    dropDelegate: () => null,
    openConnect: () {},
    allCommands: () => const [],
    openUrl: (_) async {},
    fileOps: () => fileOps,
    reportFailure: failures.add,
    locationLabel: (_) => '',
  );

  RegisteredCommand command(String id) =>
      commands().singleWhere((candidate) => candidate.id == id);

  test('registers the exact File menu rows', () async {
    await bindLocal();
    final l10n = AppLocalizationsEn();
    final create = command(kFileCreateArchiveCommandId);
    final extract = command(kFileExtractArchiveCommandId);

    expect(create.label(l10n), 'Create ZIP Archive');
    expect(extract.label(l10n), 'Extract ZIP Archive');
    expect(create.scope, CommandScope.selection);
    expect(extract.scope, CommandScope.selection);
    expect(create.hue, FamilyHue.brown);
    expect(extract.hue, FamilyHue.brown);
    expect(create.menuPlacement?.menu, AppMenuId.file);
    expect(extract.menuPlacement?.menu, AppMenuId.file);
    expect(create.menuPlacement?.order, lessThan(extract.menuPlacement!.order));
  });

  test('requires a selection and exactly one ZIP for extraction', () async {
    await bindLocal();
    final l10n = AppLocalizationsEn();

    expect(command(kFileCreateArchiveCommandId).enabled(), isFalse);
    expect(
      command(kFileCreateArchiveCommandId).disabledReason!(l10n),
      'Requires a selected item',
    );
    expect(command(kFileExtractArchiveCommandId).enabled(), isFalse);
    expect(
      command(kFileExtractArchiveCommandId).disabledReason!(l10n),
      'Select one ZIP archive.',
    );

    pane.setCursorIndex(0);
    expect(command(kFileCreateArchiveCommandId).enabled(), isTrue);
    expect(command(kFileExtractArchiveCommandId).enabled(), isFalse);

    pane.setCursorIndex(1);
    expect(command(kFileCreateArchiveCommandId).enabled(), isTrue);
    expect(command(kFileExtractArchiveCommandId).enabled(), isTrue);

    pane.setCursorIndex(0, update: SelectionUpdate.toggle);
    expect(command(kFileCreateArchiveCommandId).enabled(), isTrue);
    expect(command(kFileExtractArchiveCommandId).enabled(), isFalse);
  });

  test('enqueues create and extract against the shown local folder', () async {
    await bindLocal();

    pane.setCursorIndex(0);
    expect(command(kFileCreateArchiveCommandId).enabled(), isTrue);
    await command(kFileCreateArchiveCommandId).run(_NoContext());
    expect(failures, isEmpty);
    expect(archives.tasks, hasLength(1));
    expect(archives.tasks.single.rootPaths, ['/home/tester/a.txt']);
    expect(archives.tasks.single.destinationDir, '/home/tester');

    pane.setCursorIndex(1);
    await command(kFileExtractArchiveCommandId).run(_NoContext());
    expect(archives.tasks, hasLength(2));
    expect(archives.tasks.last.rootPaths, ['/home/tester/BUNDLE.ZIP']);
    expect(archives.tasks.last.destinationDir, '/home/tester');
  });

  test('keeps both archive commands local-only', () async {
    await bindRemote();
    final l10n = AppLocalizationsEn();
    pane.setCursorIndex(0);

    for (final id in [
      kFileCreateArchiveCommandId,
      kFileExtractArchiveCommandId,
    ]) {
      expect(command(id).enabled(), isFalse);
      expect(
        command(id).disabledReason!(l10n),
        'Archives are available for local files only.',
      );
    }
  });

  test('extracts an expanded ZIP beside that ZIP', () async {
    await bindNestedArchive();
    pane.setCursorIndex(1);

    await command(kFileExtractArchiveCommandId).run(_NoContext());

    expect(archives.tasks.single.rootPaths, ['/home/tester/nested/bundle.zip']);
    expect(archives.tasks.single.destinationDir, '/home/tester/nested');
  });
}
