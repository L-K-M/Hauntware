// The Sync sheet through the real shell (D32 §7): ⌥⌘Y shows the sheet
// over the two panes (the focused pane is the source), Simulate opens
// the review tab, and Synchronize either runs a creates-only plan
// straight away or lands on the review with the reason banner. The
// panes point at real temp folders, so the plan tab's scan and run hit
// the real filesystem — every step that reaches it runs inside
// `tester.runAsync` (AGENTS.md's fake-async gotcha).
@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/sync_plan_controller.dart';
import 'package:poltergeist_app/services/sync_queue_facade.dart';
import 'package:poltergeist_app/theme/app_theme.dart';
import 'package:poltergeist_app/ui/sync/sync_commands.dart';
import 'package:poltergeist_app/ui/sync/sync_pair_editor.dart';
import 'package:poltergeist_app/ui/sync/sync_plan_view.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';
import 'package:poltergeist_sync/poltergeist_sync.dart'
    show SyncPair, SyncSide, syncPairFromBookmark;

import '../../services/engine_session_test.dart' as session_test;
import '../../support/fake_bookmark_store.dart';
import '../../support/shell_commands.dart';
import '../../support/sync_harness.dart';

RemoteFileEntry _entry(String dir, String name) => RemoteFileEntry(
  path: '$dir/$name',
  name: name,
  type: RemoteFileType.file,
  size: 5,
);

/// Two real folders, the shell's panes bound to them.
final class _Fixture {
  _Fixture(this.scratch, {String rightName = 'right'})
    : left = Directory('${scratch.path}/left')..createSync(),
      right = Directory('${scratch.path}/$rightName')..createSync();

  final Directory scratch;
  final Directory left;
  final Directory right;
  late final FakeBookmarkStore bookmarks;
}

enum _BookmarkExposure { available, unavailable }

Future<_Fixture> _pumpShell(
  WidgetTester tester, {
  required void Function(_Fixture fixture) seed,
  String rightName = 'right',
  _BookmarkExposure bookmarkExposure = _BookmarkExposure.available,
}) async {
  final scratch = Directory.systemTemp.createTempSync('pg-sheet-shell-');
  addTearDown(() => scratch.deleteSync(recursive: true));
  final fixture = _Fixture(scratch, rightName: rightName);
  seed(fixture);

  final engine = session_test.FakeAppEngine();
  for (final dir in [fixture.left, fixture.right]) {
    engine.localChannels.add(
      session_test.FakeAppBrowseChannel(homePath: dir.path)
        ..listings[dir.path] = [
          for (final file in dir.listSync().whereType<File>())
            _entry(dir.path, file.uri.pathSegments.last),
        ],
    );
  }
  addTearDown(engine.close);
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final navigatorKey = GlobalKey<NavigatorState>();
  final supportDir = Directory('${scratch.path}/support')..createSync();
  final bookmarks = FakeBookmarkStore();
  fixture.bookmarks = bookmarks;
  addTearDown(bookmarks.close);
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
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildPoltergeistTheme(Brightness.dark),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorKey: navigatorKey,
      home: WorkspaceShell(
        bookmarks: bookmarkExposure == _BookmarkExposure.available
            ? bookmarks
            : null,
        engineSession: session,
        syncEnvironment: testSyncEnvironment(scratch),
        syncTasks: SyncQueueTasks(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return fixture;
}

/// Taps [key] and pumps real time until [done] holds — the plan tab's
/// scan/run completes on the real event loop.
Future<void> _tapAndWait(
  WidgetTester tester,
  String key,
  bool Function() done,
) async {
  await tester.runAsync(() async {
    await tester.tap(find.byKey(ValueKey(key)));
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  // Let the sheet's exit transition finish.
  await tester.pump(const Duration(milliseconds: 400));
}

SyncPlanController? _session(WidgetTester tester) {
  final view = find.byType(SyncPlanView);
  if (view.evaluate().isEmpty) return null;
  return tester.widget<SyncPlanView>(view).controller;
}

String _plan(WidgetTester tester) => tester
    .widget<Text>(find.byKey(const ValueKey('sync.sheet.plan')))
    .textSpan!
    .toPlainText();

void main() {
  testWidgets('⌥⌘Y shows the sheet; Simulate opens the review tab', (
    tester,
  ) async {
    final fixture = await _pumpShell(
      tester,
      seed: (f) => File('${f.left.path}/a.txt').writeAsStringSync('alpha'),
    );
    expect(shellCommandEnabled(tester, kSyncSynchronizePanesCommandId), isTrue);
    await runShellCommand(tester, kSyncSynchronizePanesCommandId);

    expect(find.byKey(const ValueKey('sync.sheet')), findsOneWidget);
    // The left pane is focused, so it is the source.
    expect(
      _plan(tester),
      startsWith(
        'Your local folder “right” will be updated from your local folder '
        '“left”.',
      ),
    );

    await _tapAndWait(
      tester,
      'sync.sheet.simulate',
      () => _session(tester)?.phase == SyncPlanPhase.ready,
    );
    expect(find.byKey(const ValueKey('sync.sheet')), findsNothing);
    final session = _session(tester)!;
    expect(session.phase, SyncPlanPhase.ready);
    expect(session.stats!.newFilesTo(SyncSide.right), 1);
    // Simulate never runs: the review waits for Run.
    expect(session.lastRun, isNull);
    expect(File('${fixture.right.path}/a.txt').existsSync(), isFalse);
    expect(find.byKey(const ValueKey('sync.plan.holdBanner')), findsNothing);
  });

  testWidgets('Synchronize runs a creates-only plan straight away', (
    tester,
  ) async {
    final fixture = await _pumpShell(
      tester,
      seed: (f) => File('${f.left.path}/a.txt').writeAsStringSync('alpha'),
    );
    await runShellCommand(tester, kSyncSynchronizePanesCommandId);
    await _tapAndWait(
      tester,
      'sync.sheet.synchronize',
      () => _session(tester)?.phase == SyncPlanPhase.completed,
    );
    expect(_session(tester)!.phase, SyncPlanPhase.completed);
    expect(File('${fixture.right.path}/a.txt').readAsStringSync(), 'alpha');
  });

  testWidgets('Synchronize holds a replacing plan on the review', (
    tester,
  ) async {
    final fixture = await _pumpShell(
      tester,
      seed: (f) {
        File('${f.left.path}/a.txt').writeAsStringSync('new contents');
        File('${f.right.path}/a.txt').writeAsStringSync('old');
      },
    );
    await runShellCommand(tester, kSyncSynchronizePanesCommandId);
    await _tapAndWait(
      tester,
      'sync.sheet.synchronize',
      () => _session(tester)?.reviewHold != null,
    );
    final session = _session(tester)!;
    expect(session.phase, SyncPlanPhase.ready);
    expect(session.lastRun, isNull);
    expect(
      find.text('This plan replaces 1 file — review before running.'),
      findsOneWidget,
    );
    expect(File('${fixture.right.path}/a.txt').readAsStringSync(), 'old');
  });

  testWidgets('docroot action saves, focuses, and persists the safer path', (
    tester,
  ) async {
    final fixture = await _pumpShell(
      tester,
      rightName: 'public_html',
      seed: (f) => File('${f.left.path}/a.txt').writeAsStringSync('alpha'),
    );
    await runShellCommand(tester, kSyncSynchronizePanesCommandId);
    await _tapAndWait(
      tester,
      'sync.sheet.simulate',
      () => _session(tester)?.phase == SyncPlanPhase.ready,
    );
    final session = _session(tester)!;
    expect(
      find.byKey(const ValueKey('sync.docrootWarning.right')),
      findsOneWidget,
    );
    expect(
      shellCommandEnabled(tester, kSyncAdjustDocrootTrashCommandId),
      isTrue,
    );

    await tester.runAsync(() async {
      await tester.tap(
        find.byKey(const ValueKey('sync.docrootWarningAction.right')),
      );
      for (
        var i = 0;
        i < 100 && find.byType(SyncPairEditorDialog).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    final savedBeforeEdit = await fixture.bookmarks.byId(session.pair.id);
    expect(savedBeforeEdit?.kind, BookmarkKind.savedSync);
    final trashField = tester.widget<TextField>(
      find.byKey(const ValueKey('sync.trashPath.right')),
    );
    expect(trashField.controller!.text, startsWith('~/.poltergeist-trash/'));
    expect(trashField.focusNode!.hasFocus, isTrue);

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save & Rescan'));
      for (
        var i = 0;
        i < 200 &&
            (find.byType(SyncPairEditorDialog).evaluate().isNotEmpty ||
                session.phase == SyncPlanPhase.scanning);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      session.pair.rules.trashPathRight,
      startsWith('~/.poltergeist-trash/'),
    );
    SyncPair? stored;
    await tester.runAsync(() async {
      for (var i = 0; i < 200; i++) {
        final bookmark = await fixture.bookmarks.byId(session.pair.id);
        stored = bookmark == null ? null : syncPairFromBookmark(bookmark);
        if (stored?.rules.trashPathRight == session.pair.rules.trashPathRight) {
          return;
        }

        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    expect(stored?.rules.trashPathRight, session.pair.rules.trashPathRight);
    expect(
      find.byKey(const ValueKey('sync.docrootWarning.right')),
      findsNothing,
    );
  });

  testWidgets('docroot action ignores a second invocation while opening', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      rightName: 'public_html',
      seed: (f) => File('${f.left.path}/a.txt').writeAsStringSync('alpha'),
    );
    await runShellCommand(tester, kSyncSynchronizePanesCommandId);
    await _tapAndWait(
      tester,
      'sync.sheet.simulate',
      () => _session(tester)?.phase == SyncPlanPhase.ready,
    );

    final action = tester.widget<TextButton>(
      find.byKey(const ValueKey('sync.docrootWarningAction.right')),
    );
    await tester.runAsync(() async {
      action.onPressed!();
      action.onPressed!();
      for (
        var i = 0;
        i < 100 && find.byType(SyncPairEditorDialog).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 20));
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    expect(find.byType(SyncPairEditorDialog), findsOneWidget);
  });

  testWidgets('docroot command requires bookmark persistence', (tester) async {
    await _pumpShell(
      tester,
      rightName: 'public_html',
      bookmarkExposure: _BookmarkExposure.unavailable,
      seed: (f) => File('${f.left.path}/a.txt').writeAsStringSync('alpha'),
    );
    await runShellCommand(tester, kSyncSynchronizePanesCommandId);
    await _tapAndWait(
      tester,
      'sync.sheet.simulate',
      () => _session(tester)?.phase == SyncPlanPhase.ready,
    );

    expect(
      shellCommandEnabled(tester, kSyncAdjustDocrootTrashCommandId),
      isFalse,
    );
    expect(
      find.byKey(const ValueKey('sync.docrootWarningAction.right')),
      findsNothing,
    );
  });

  testWidgets('docroot command disables while the plan is owned', (
    tester,
  ) async {
    await _pumpShell(
      tester,
      rightName: 'public_html',
      seed: (f) => File('${f.left.path}/a.txt').writeAsStringSync('alpha'),
    );
    await runShellCommand(tester, kSyncSynchronizePanesCommandId);
    await _tapAndWait(
      tester,
      'sync.sheet.simulate',
      () => _session(tester)?.phase == SyncPlanPhase.ready,
    );
    final session = _session(tester)!;

    final run = session.run();
    expect(session.planMutationsBlocked, isTrue);
    expect(
      shellCommandEnabled(tester, kSyncAdjustDocrootTrashCommandId),
      isFalse,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(() => run);
  });
}
