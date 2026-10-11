import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_comparison.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/selection_state.dart';
import 'package:poltergeist_app/services/sync_compare_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart';

import '../support/test_panes.dart';
import 'pane_controller_test.dart' as controller_test;

const _serverId = 'srv-1';
final _remoteModified = DateTime.utc(2026, 10, 1, 12, 30, 15, 900);

Bookmark _server() {
  final now = DateTime.utc(2026, 10, 1);
  return Bookmark(
    id: _serverId,
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
    sortKey: _serverId,
    createdAt: now,
    updatedAt: now,
  );
}

/// The visible row named [name]: folders sort first, so listing order is
/// not the order the fake channel lists.
int _row(PaneController pane, String name) =>
    pane.entries.indexWhere((entry) => entry.name == name);

void main() {
  late controller_test.FakePaneLanes lanes;
  late PaneController left;
  late PaneController right;
  late WorkspaceController workspace;

  setUp(() {
    lanes = controller_test.FakePaneLanes();
    left = PaneController(paneTabId: 'pane.left', lanes: lanes);
    right = PaneController(paneTabId: 'pane.right', lanes: lanes);
    workspace = WorkspaceController(
      left: testPaneStrip(left),
      right: testPaneStrip(right),
    );
  });

  tearDown(() => workspace.dispose());

  // Left: a.txt, b.txt, c.txt, docs/ and link.
  Future<void> bindLeftLocal() async {
    lanes.nextLocalChannel = controller_test.FakePaneChannel('/home/tester')
      ..listings['/home/tester'] = const [
        RemoteFileEntry(
          path: '/home/tester/a.txt',
          name: 'a.txt',
          type: RemoteFileType.file,
          size: 3,
        ),
        RemoteFileEntry(
          path: '/home/tester/b.txt',
          name: 'b.txt',
          type: RemoteFileType.file,
          size: 4,
        ),
        RemoteFileEntry(
          path: '/home/tester/c.txt',
          name: 'c.txt',
          type: RemoteFileType.file,
          size: 5,
        ),
        RemoteFileEntry(
          path: '/home/tester/docs',
          name: 'docs',
          type: RemoteFileType.directory,
        ),
        RemoteFileEntry(
          path: '/home/tester/link',
          name: 'link',
          type: RemoteFileType.symbolicLink,
        ),
      ];
    await left.openLocalHome();
    await pumpEventQueue();
  }

  // Right: a.txt, www/ and b.txt.
  Future<void> bindRightRemote() async {
    lanes.nextRemoteChannel = controller_test.FakePaneChannel('/srv')
      ..listings['/srv'] = [
        RemoteFileEntry(
          path: '/srv/a.txt',
          name: 'a.txt',
          type: RemoteFileType.file,
          size: 7,
          modifiedAt: _remoteModified,
          mode: 0x81a4,
        ),
        const RemoteFileEntry(
          path: '/srv/www',
          name: 'www',
          type: RemoteFileType.directory,
        ),
        const RemoteFileEntry(
          path: '/srv/b.txt',
          name: 'b.txt',
          type: RemoteFileType.file,
          size: 8,
        ),
      ];
    await right.connectRemote(_server(), initialPath: '/srv');
    await pumpEventQueue();
  }

  test('two files in the focused pane compare in listing order', () async {
    await bindLeftLocal();
    left.setCursorIndex(_row(left, 'b.txt'));
    left.setCursorIndex(_row(left, 'a.txt'), update: SelectionUpdate.toggle);

    final comparison = resolvePaneComparison(workspace)!;

    expect(comparison.leftName, 'a.txt');
    expect(comparison.rightName, 'b.txt');
    final request = comparison.request;
    expect(request.left, isA<LocalSyncCompareSource>());
    expect(request.right, isA<LocalSyncCompareSource>());
    expect(request.left.side, SyncSide.left);
    expect(request.right.side, SyncSide.right);
    expect(request.left.fullPath, '/home/tester/a.txt');
    expect(request.right.fullPath, '/home/tester/b.txt');
    expect(request.left.snapshot.kind, EntryKind.file);
    expect(request.left.snapshot.size, 3);
  });

  test('one file in each pane keeps each pane on its own side', () async {
    await bindLeftLocal();
    await bindRightRemote();
    left.setCursorIndex(_row(left, 'c.txt'));
    right.setCursorIndex(_row(right, 'a.txt'));
    workspace.setActivePane(workspace.right);

    final comparison = resolvePaneComparison(workspace)!;

    expect(comparison.leftName, 'c.txt');
    expect(comparison.rightName, 'a.txt');
    final request = comparison.request;
    expect(request.left, isA<LocalSyncCompareSource>());
    expect(request.left.fullPath, '/home/tester/c.txt');
    final remote = request.right as RemoteSyncCompareSource;
    expect(remote.side, SyncSide.right);
    expect(remote.serverId, _serverId);
    expect(remote.fullPath, '/srv/a.txt');
    expect(remote.snapshot.size, 7);
    expect(remote.snapshot.mode, 0x81a4);
    // Whole seconds, truncated like the preview cache key.
    expect(
      remote.snapshot.mtimeSecs,
      _remoteModified.millisecondsSinceEpoch ~/ 1000,
    );
    expect(
      previewCacheKey(
        _serverId,
        remote.fullPath,
        DateTime.fromMillisecondsSinceEpoch(
          remote.snapshot.mtimeSecs! * 1000,
          isUtc: true,
        ),
        remote.snapshot.size,
      ),
      previewCacheKey(_serverId, '/srv/a.txt', _remoteModified, 7),
    );
  });

  test(
    'the other pane\'s cursor row stands in for an empty selection',
    () async {
      await bindLeftLocal();
      await bindRightRemote();
      right.setCursorIndex(_row(right, 'b.txt'));
      right.setCursorIndex(
        _row(right, 'b.txt'),
        update: SelectionUpdate.toggle,
      );
      expect(right.selectedEntries, isEmpty);
      left.setCursorIndex(_row(left, 'a.txt'));

      final comparison = resolvePaneComparison(workspace)!;

      expect(comparison.request.left.fullPath, '/home/tester/a.txt');
      expect(comparison.request.right.fullPath, '/srv/b.txt');
    },
  );

  test('two files in the focused pane win over the other pane', () async {
    await bindLeftLocal();
    await bindRightRemote();
    right.setCursorIndex(_row(right, 'a.txt'));
    left.setCursorIndex(_row(left, 'a.txt'));
    left.setCursorIndex(_row(left, 'c.txt'), update: SelectionUpdate.toggle);

    final comparison = resolvePaneComparison(workspace)!;

    expect(comparison.request.left.fullPath, '/home/tester/a.txt');
    expect(comparison.request.right.fullPath, '/home/tester/c.txt');
  });

  test('folders, links and other counts disable the comparison', () async {
    await bindLeftLocal();
    await bindRightRemote();

    // Nothing selected and no cursor anywhere.
    expect(resolvePaneComparison(workspace), isNull);

    // A folder or link in the focused pane's selection is not skipped.
    left.setCursorIndex(_row(left, 'a.txt'));
    left.setCursorIndex(_row(left, 'docs'), update: SelectionUpdate.toggle);
    expect(resolvePaneComparison(workspace), isNull);
    left.setCursorIndex(_row(left, 'link'));
    expect(resolvePaneComparison(workspace), isNull);

    // Three files.
    left.setCursorIndex(_row(left, 'a.txt'));
    left.setCursorIndex(_row(left, 'b.txt'), update: SelectionUpdate.toggle);
    left.setCursorIndex(_row(left, 'c.txt'), update: SelectionUpdate.toggle);
    expect(resolvePaneComparison(workspace), isNull);

    // One file here, a folder there.
    left.setCursorIndex(_row(left, 'a.txt'));
    right.setCursorIndex(_row(right, 'www'));
    expect(resolvePaneComparison(workspace), isNull);

    // One file here, two there.
    right.setCursorIndex(_row(right, 'a.txt'));
    right.setCursorIndex(_row(right, 'b.txt'), update: SelectionUpdate.toggle);
    expect(resolvePaneComparison(workspace), isNull);

    // One file in each pane, but the second pane is hidden.
    right.setCursorIndex(_row(right, 'a.txt'));
    expect(resolvePaneComparison(workspace), isNotNull);
    workspace.setSecondPaneHidden(true);
    expect(resolvePaneComparison(workspace), isNull);
  });

  test('an unbound pane resolves to nothing', () async {
    await bindRightRemote();
    right.setCursorIndex(_row(right, 'a.txt'));

    // The focused left pane has no listing.
    expect(resolvePaneComparison(workspace), isNull);

    // Focused on the right with one file; the left pane is unbound.
    workspace.setActivePane(workspace.right);
    expect(resolvePaneComparison(workspace), isNull);
  });
}
