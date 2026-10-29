import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/workspace_controller.dart';
import 'package:poltergeist_app/services/workspace_windows/workspace_windows.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../support/test_panes.dart';
import 'pane_controller_test.dart' show FakePaneLanes;
import 'workspace_windows_test.dart' show FakeWindowHost;

final class _Content implements WorkspaceWindowContent {
  _Content(this.workspace);

  @override
  final WorkspaceController workspace;

  @override
  void claimDefaultFocus() {}
}

void main() {
  test(
    'catalog binding sees a live referencing favorite across windows',
    () async {
      const serverId = 'catalog-copy';
      const server = ServerConfig(
        id: serverId,
        label: 'Copy',
        host: 'remote.example',
        username: 'user',
        createdAt: 0,
        updatedAt: 0,
      );
      final now = DateTime.utc(2026, 10, 29);
      final favorite = Bookmark(
        id: 'favorite-id',
        kind: BookmarkKind.remotePath,
        label: 'Favorite',
        server: const BookmarkServerRef(serverConfigId: serverId),
        remotePath: '/',
        sortKey: 'm',
        createdAt: now,
        updatedAt: now,
      );
      final lanes = FakePaneLanes();
      final left = PaneController(paneTabId: 'left', lanes: lanes);
      final right = PaneController(paneTabId: 'right', lanes: lanes);
      final workspace = WorkspaceController(
        left: testPaneStrip(left, lanes: lanes),
        right: testPaneStrip(right, lanes: lanes),
      );
      addTearDown(workspace.dispose);
      await left.connectRemote(favorite, resolvedConfig: server);
      expect(left.hasLiveRemoteBinding, isTrue);
      expect(workspace.bindsServer(favorite.id), isTrue);
      expect(workspace.bindsServer(server.id), isFalse);
      expect(workspace.bindsCatalogServer(server.id), isTrue);

      final windows = WorkspaceWindows(
        host: FakeWindowHost(),
        quitApplication: () async {},
        afterFrame: () async {},
        platform: TargetPlatform.linux,
      );
      addTearDown(windows.dispose);
      await windows.start();
      final first = windows.windows.single;
      await windows.openWindow();
      windows.windows.last.attachContent(_Content(workspace));
      expect(first.serverBoundElsewhere(server.id), isFalse);
      expect(first.catalogServerBoundElsewhere(server.id), isTrue);
    },
  );
}
