import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/services/pane_location.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../../app/poltergeist_app/test/services/pane_cancel_regressions_test.dart' show FakePaneLanes, FakePaneChannel;

void main() {
  test('superseded held open closes once without releasing replacement', () async {
    final now = DateTime.utc(2026, 9, 13);
    final bookmark = Bookmark(id: 'srv-1', kind: BookmarkKind.remotePath,
      label: 'web', server: BookmarkServerRef(identity: EmbeddedHostIdentity(
        host: 'web.example.com', port: 22, username: 'tester',
        authMethod: AuthMethod.password)), remotePath: '/', sortKey: 'k',
      createdAt: now, updatedAt: now);
    final held = Completer<void>();
    final lanes = FakePaneLanes()..holdRemoteOpen = held;
    final controller = PaneController(paneTabId: 'pane.right', lanes: lanes);
    addTearDown(controller.dispose);
    addTearDown(() { if (!held.isCompleted) held.complete(); });
    final oldBind = controller.connectRemote(bookmark);
    await Future<void>.delayed(Duration.zero);
    expect(controller.phase, PanePhase.connectingRemote);
    final cancelling = controller.cancelRecovery();
    final replacement = FakePaneChannel('/replacement');
    lanes.nextRemoteChannel = replacement;
    await Future.wait([cancelling, controller.connectRemote(bookmark)]);
    await Future<void>.delayed(Duration.zero);
    expect(replacement.listCalls, ['/replacement']);

    // The fake consumes nextRemoteChannel AFTER its held await. Seed now,
    // after the replacement consumed its own channel, not before oldBind.
    final old = FakePaneChannel('/old');
    lanes.nextRemoteChannel = old;
    held.complete();
    await oldBind;
    expect(old.closeCalls, 1);
    expect(old.listCalls, isEmpty);
    expect(replacement.closeCalls, 0);
    expect(lanes.disconnects, isEmpty);
    expect(controller.location, const RemotePaneLocation('srv-1', '/replacement'));
    controller.refresh();
    await Future<void>.delayed(Duration.zero);
    expect(replacement.listCalls, ['/replacement', '/replacement']);
    expect(old.closeCalls, 1);
  });
}
