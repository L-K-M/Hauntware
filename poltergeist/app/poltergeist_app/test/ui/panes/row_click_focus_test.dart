import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/ui/panes/pane_view.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';

RemoteFileEntry _entry(String dir, String name) => RemoteFileEntry(
  path: '$dir/$name',
  name: name,
  type: RemoteFileType.file,
  size: 10,
);

/// D32 §6: a row selects on pointer-down and times its own double-click,
/// so nothing fires after a click. A report had the delayed single-tap
/// of a double-tap recognizer pull focus back to the listing when ⌘F /
/// Ctrl+F followed a click inside the 300 ms window; this pins that the
/// filter field keeps it.
void main() {
  late session_test.FakeAppEngine engine;

  setUp(() {
    engine = session_test.FakeAppEngine();
    engine.localChannels.addAll([
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [
          _entry('/home/tester', 'left.txt'),
          _entry('/home/tester', 'other.txt'),
        ],
      session_test.FakeAppBrowseChannel(homePath: '/home/tester')
        ..listings['/home/tester'] = [_entry('/home/tester', 'right.txt')],
    ]);
  });

  Future<void> pumpApp(WidgetTester tester, {FakeBookmarkStore? store}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(engine.close);
    final navigatorKey = GlobalKey<NavigatorState>();
    final supportDir = Directory.systemTemp.createTempSync('pg-row-focus-');
    addTearDown(() => supportDir.deleteSync(recursive: true));
    final bookmarks = store ?? FakeBookmarkStore();
    final session = await startEngineSession(
      supportDirectoryPath: supportDir.path,
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

  bool filterFocused(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(const ValueKey('header.filter')),
          matching: find.byType(EditableText),
        ),
      )
      .focusNode
      .hasFocus;

  testWidgets('opening a sidebar favorite hands arrow keys to its file list', (
    tester,
  ) async {
    final now = DateTime.utc(2026, 11, 8);
    final bookmark = Bookmark(
      id: 'remote',
      kind: BookmarkKind.remotePath,
      label: 'Storage',
      preferredPane: PreferredPane.right,
      server: BookmarkServerRef(
        identity: EmbeddedHostIdentity(
          host: 'storage.example.com',
          port: 22,
          username: 'tester',
          authMethod: AuthMethod.password,
        ),
      ),
      remotePath: '/srv/home',
      sortKey: 'k',
      createdAt: now,
      updatedAt: now,
    );
    engine.channel = session_test.FakeAppBrowseChannel(homePath: '/srv/home')
      ..listings['/srv/home'] = [
        _entry('/srv/home', 'first.txt'),
        _entry('/srv/home', 'second.txt'),
      ];
    await pumpApp(tester, store: FakeBookmarkStore([bookmark]));
    await tester.tap(find.byKey(const ValueKey('sidebar.favorite.remote')));
    await tester.pumpAndSettle();
    final pane = tester.widget<PaneView>(find.byType(PaneView).last);
    expect(pane.controller.location?.path, '/srv/home');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(pane.controller.cursorIndex, 0);
    expect(pane.controller.selectedCount, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(pane.controller.cursorIndex, 1);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets(
    'the initial listing responds to arrows without a pointer click',
    (tester) async {
      await pumpApp(tester);
      final pane = tester.widget<PaneView>(find.byType(PaneView).first);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(pane.controller.cursorIndex, 0);
      expect(pane.controller.selectedCount, 1);
    },
    variant: TargetPlatformVariant.desktop(),
  );

  testWidgets('clicking a file keeps arrows on the listing', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('left.txt'));
    await tester.pumpAndSettle();
    final pane = tester.widget<PaneView>(find.byType(PaneView).first);
    expect(pane.controller.cursorIndex, 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(pane.controller.cursorIndex, 1);
  }, variant: TargetPlatformVariant.desktop());

  testWidgets(
    'a click then the filter chord inside the double-click window leaves '
    'focus in the filter',
    (tester) async {
      await pumpApp(tester);
      final modifier = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;

      await tester.tap(find.text('left.txt'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      expect(filterFocused(tester), isTrue);

      // Past the window nothing fires late to take it back.
      await tester.pump(const Duration(milliseconds: 400));
      expect(filterFocused(tester), isTrue);
      await tester.pumpAndSettle();
      expect(filterFocused(tester), isTrue);
    },
    variant: TargetPlatformVariant.desktop(),
  );
}
