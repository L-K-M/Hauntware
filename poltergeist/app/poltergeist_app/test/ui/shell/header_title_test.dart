import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/pane_controller.dart';
import 'package:poltergeist_app/ui/compact/compact_browser.dart';
import 'package:poltergeist_app/ui/compact/compact_posture.dart';
import 'package:poltergeist_app/ui/compact/compact_workspace.dart';
import 'package:poltergeist_app/ui/panes/pane_tabs_view.dart';
import 'package:poltergeist_app/ui/server_state_indicator.dart';
import 'package:poltergeist_app/ui/shell/header_toolbar.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

const _appStorage = '/data/user/0/ch.lkmc.poltergeist/app_flutter';

RemoteFileEntry _entry(String parent, String name) => RemoteFileEntry(
  path: '$parent/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

Bookmark _server() => Bookmark(
  id: 'srv-web',
  kind: BookmarkKind.remotePath,
  label: 'web',
  server: BookmarkServerRef(
    identity: EmbeddedHostIdentity(
      host: 'web.example.com',
      port: 22,
      username: 'deploy',
      authMethod: AuthMethod.password,
    ),
  ),
  remotePath: '/srv/www',
  sortKey: 'srv-web',
  createdAt: DateTime.utc(2026, 9, 12),
  updatedAt: DateTime.utc(2026, 9, 12),
);

/// D32 §4's header title: the active location's folder name with the
/// server dot, a `user@host` subtitle for remotes only, and the full
/// path in a tooltip rather than a second line (10 §2).
void main() {
  late session_test.FakeAppEngine engine;

  setUp(() {
    engine = session_test.FakeAppEngine();
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('/home/tester', 'alpha.txt')],
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('/home/tester', 'right.txt')],
    ]);
    engine.channel = session_test.FakeAppBrowseChannel(homePath: '/srv/www')
      ..listings['/srv/www'] = [_entry('/srv/www', 'index.html')];
  });

  Future<void> pumpApp(
    WidgetTester tester, {
    String? fallbackHome,
    Size size = const Size(1400, 900),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(engine.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-title-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final bookmarks = FakeBookmarkStore();
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
      fallbackHome: fallbackHome,
      bookmarks: bookmarks,
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (config) async => engine,
    );
    addTearDown(session!.shutdown);
    await tester.pumpWidget(
      PoltergeistApp(
        bookmarks: bookmarks,
        engineSession: session,
        navigatorKey: navigatorKey,
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder inHeader(Finder matching) =>
      find.descendant(of: find.byType(HeaderToolbar), matching: matching);

  Finder tooltip(String message) => inHeader(
    find.byWidgetPredicate((w) => w is Tooltip && w.message == message),
  );

  PaneController activePane(WidgetTester tester) => tester
      .widget<PaneTabsView>(find.byType(PaneTabsView).first)
      .workspace
      .activeTabController!;

  void useAppStorage() {
    engine.localChannels
      ..clear()
      ..addAll([
        session_test.FakeAppBrowseChannel(homePath: _appStorage),
        session_test.FakeAppBrowseChannel(homePath: _appStorage),
      ]);
  }

  testWidgets('a local folder: its name, no second line, the path in a '
      'tooltip', (tester) async {
    await pumpApp(tester);
    final title = find.byKey(const ValueKey('header.title'));
    expect(tester.widget<Text>(title).data, 'tester');
    expect(inHeader(find.text('/home/tester')), findsNothing);
    expect(tooltip('/home/tester'), findsOneWidget);
    expect(inHeader(find.byType(ServerStateGlyph)), findsNothing);
  });

  testWidgets('a remote folder: its name, the server dot, and user@host '
      'under it', (tester) async {
    await pumpApp(tester);
    await activePane(tester).connectRemote(_server());
    await tester.pumpAndSettle();

    final title = find.byKey(const ValueKey('header.title'));
    expect(tester.widget<Text>(title).data, 'www');
    expect(inHeader(find.byType(ServerStateGlyph)), findsOneWidget);
    expect(inHeader(find.text('deploy@web.example.com')), findsOneWidget);
    expect(inHeader(find.textContaining('/srv/www')), findsNothing);
    expect(tooltip('deploy@web.example.com:/srv/www'), findsOneWidget);
  });

  testWidgets('Android app storage has a friendly name on every title', (
    tester,
  ) async {
    useAppStorage();
    await pumpApp(tester, fallbackHome: _appStorage);

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('header.title'))).data,
      'App storage',
    );
    expect(find.text('app_flutter'), findsNothing);
    expect(find.text('App storage'), findsNWidgets(5));
    expect(tooltip(_appStorage), findsOneWidget);
    final pane = activePane(tester);
    expect(pane.location?.path, _appStorage);

    pane.navigate('$_appStorage/Downloads');
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('header.title'))).data,
      'Downloads',
    );
    await tester.tap(find.byKey(ValueKey('${pane.paneTabId}.path.ancestors')));
    await tester.pumpAndSettle();
    expect(find.text('app_flutter'), findsNothing);
    expect(find.text('App storage'), findsNWidgets(3));
  });

  testWidgets('compact app storage titles and breadcrumbs use its label', (
    tester,
  ) async {
    useAppStorage();
    await pumpApp(
      tester,
      fallbackHome: _appStorage,
      size: const Size(390, 844),
    );
    tester
        .state<CompactWorkspaceState>(find.byType(CompactWorkspace))
        .showBrowser();
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey(CompactKey.browserTitle)))
          .data,
      'App storage',
    );
    expect(find.text('app_flutter'), findsNothing);
    final crumb = find.byKey(
      const ValueKey((CompactKey.breadcrumb, _appStorage)),
    );
    expect(
      find.descendant(of: crumb, matching: find.text('App storage')),
      findsOneWidget,
    );

    final pane = tester
        .widget<CompactBrowser>(find.byType(CompactBrowser))
        .workspace
        .activeTabController!;
    pane.navigate('$_appStorage/Downloads');
    await tester.pumpAndSettle();
    await tester.tap(crumb);
    await tester.pumpAndSettle();
    expect(pane.location?.path, _appStorage);
  });
}
