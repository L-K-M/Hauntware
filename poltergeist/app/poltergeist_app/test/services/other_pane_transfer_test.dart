import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/other_pane_transfer.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_drop.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/fake_app_transfer_queue.dart';
import '../support/fake_pane_channel.dart';
import '../support/test_panes.dart';
import 'pane_controller_test.dart' as controller_test;

/// "Double-click action: Transfer to other pane" (02 §2.6): the file goes
/// to the pane opposite the one it was opened in, as a copy under F5's
/// rules, or the outcome says why it could not.
void main() {
  late controller_test.FakePaneLanes lanes;
  late FakeAppTransferQueue queue;
  late Map<PaneController, FakePaneChannel> channels;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    queue = FakeAppTransferQueue();
    channels = {};
  });

  RemoteFileEntry file(String path) => RemoteFileEntry(
    path: path,
    name: path.split('/').last,
    type: RemoteFileType.file,
    size: 12,
  );

  /// A pane bound to a local folder [home] listing [names].
  Future<PaneController> localPane(
    String tabId,
    String home, {
    List<String> names = const [],
  }) async {
    final channel = FakePaneChannel(home);
    channel.listings[home] = [for (final name in names) file('$home/$name')];
    lanes.nextLocalChannel = channel;
    final pane = PaneController(paneTabId: tabId, lanes: lanes);
    await pane.openLocalHome();
    await Future<void>.delayed(Duration.zero);
    addTearDown(pane.dispose);
    channels[pane] = channel;
    return pane;
  }

  WorkspaceController workspaceOf(PaneController left, PaneController right) {
    final workspace = WorkspaceController(
      left: testPaneStrip(left, lanes: lanes),
      right: testPaneStrip(right, lanes: lanes),
    );
    addTearDown(workspace.dispose);
    return workspace;
  }

  OtherPaneTransferOutcome transfer(
    WorkspaceController workspace,
    PaneController source,
    String path, {
    bool withQueue = true,
  }) => transferEntryToOtherPane(
    workspace: workspace,
    dropDelegate: withQueue ? PaneDropDelegate(queue: queue) : null,
    source: source,
    entry: file(path),
  );

  test('a file opened in pane A is queued as a copy into pane B', () async {
    final left = await localPane(
      'pane.left.tab1',
      '/home/tester',
      names: ['notes.txt'],
    );
    final right = await localPane('pane.right.tab1', '/srv/backups');
    final workspace = workspaceOf(left, right);

    final outcome = transfer(workspace, left, '/home/tester/notes.txt');

    expect(outcome, OtherPaneTransferOutcome.queued);
    final spec = queue.enqueuedSpecs.single;
    expect(spec.operation, TransferOperation.copy);
    expect(spec.rootPaths, ['/home/tester/notes.txt']);
    expect(spec.destinationDir, '/srv/backups');
    expect(spec.source, isA<LocalFsLocation>());
    expect(spec.destination, isA<LocalFsLocation>());
  });

  test('a file opened in pane B goes to pane A, whichever pane is active',
      () async {
    final left = await localPane('pane.left.tab1', '/home/tester');
    final right = await localPane(
      'pane.right.tab1',
      '/srv/backups',
      names: ['dump.sql'],
    );
    final workspace = workspaceOf(left, right);
    // F5 sends from the active pane; a double-click sends from the pane
    // it happened in.
    workspace.setActivePane(workspace.left);

    final outcome = transfer(workspace, right, '/srv/backups/dump.sql');

    expect(outcome, OtherPaneTransferOutcome.queued);
    final spec = queue.enqueuedSpecs.single;
    expect(spec.rootPaths, ['/srv/backups/dump.sql']);
    expect(spec.destinationDir, '/home/tester');
  });

  test('both panes on one folder still queue, as F5 does', () async {
    final left = await localPane(
      'pane.left.tab1',
      '/home/tester',
      names: ['notes.txt'],
    );
    final right = await localPane('pane.right.tab1', '/home/tester');
    final workspace = workspaceOf(left, right);

    // The queue's conflict policy decides about the name already there.
    expect(
      transfer(workspace, left, '/home/tester/notes.txt'),
      OtherPaneTransferOutcome.queued,
    );
    expect(queue.enqueuedSpecs.single.destinationDir, '/home/tester');
  });

  test('a source whose listing failed sends nothing, as F5 refuses', () async {
    final left = await localPane(
      'pane.left.tab1',
      '/home/tester',
      names: ['notes.txt'],
    );
    final right = await localPane('pane.right.tab1', '/srv/backups');
    final workspace = workspaceOf(left, right);
    // A re-list of the same folder fails: its rows stay up and clickable.
    channels[left]!.listingFailure = StateError('disk gone');
    left.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(left.error, isNotNull);
    expect(left.entries, isNotEmpty);

    expect(
      transfer(workspace, left, '/home/tester/notes.txt'),
      OtherPaneTransferOutcome.unavailable,
    );
    expect(queue.enqueuedSpecs, isEmpty);
  });

  test('a directory watch re-list in flight still sends', () async {
    final left = await localPane(
      'pane.left.tab1',
      '/home/tester',
      names: ['notes.txt'],
    );
    final right = await localPane('pane.right.tab1', '/srv/backups');
    final workspace = workspaceOf(left, right);
    final hold = Completer<void>();
    addTearDown(hold.complete);
    channels[left]!
      ..holdNext = hold
      ..emitWatch(DirectoryWatchSignal.changed);
    // F5 waits out every listing; a double-click does not wait on this one.
    expect(left.verbsEnabled, isFalse);

    expect(
      transfer(workspace, left, '/home/tester/notes.txt'),
      OtherPaneTransferOutcome.queued,
    );
  });

  test('a hidden second pane has nowhere to receive it', () async {
    final left = await localPane('pane.left.tab1', '/home/tester');
    final right = await localPane('pane.right.tab1', '/srv/backups');
    final workspace = workspaceOf(left, right);
    workspace.setSecondPaneHidden(true);

    expect(
      transfer(workspace, left, '/home/tester/notes.txt'),
      OtherPaneTransferOutcome.needsOtherPane,
    );
    expect(queue.enqueuedSpecs, isEmpty);
  });

  test('another pane showing no folder has nowhere to receive it', () async {
    final left = await localPane('pane.left.tab1', '/home/tester');
    final right = PaneController(paneTabId: 'pane.right.tab1', lanes: lanes);
    addTearDown(right.dispose);
    final workspace = workspaceOf(left, right);

    expect(
      transfer(workspace, left, '/home/tester/notes.txt'),
      OtherPaneTransferOutcome.needsOtherPane,
    );
    expect(queue.enqueuedSpecs, isEmpty);
  });

  test('without a queue nothing is sent', () async {
    final left = await localPane('pane.left.tab1', '/home/tester');
    final right = await localPane('pane.right.tab1', '/srv/backups');
    final workspace = workspaceOf(left, right);

    expect(
      transfer(workspace, left, '/home/tester/notes.txt', withQueue: false),
      OtherPaneTransferOutcome.unavailable,
    );
  });

  test('a pane outside the workspace sends nothing', () async {
    final left = await localPane('pane.left.tab1', '/home/tester');
    final right = await localPane('pane.right.tab1', '/srv/backups');
    final workspace = workspaceOf(left, right);
    final stray = await localPane('pane.left.tab9', '/tmp');

    expect(
      transfer(workspace, stray, '/tmp/notes.txt'),
      OtherPaneTransferOutcome.unavailable,
    );
    expect(queue.enqueuedSpecs, isEmpty);
  });
}
