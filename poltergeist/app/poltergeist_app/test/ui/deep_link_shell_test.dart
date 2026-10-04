import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/l10n/app_localizations.dart';
import 'package:poltergeist_app/services/bookmark_backup_service.dart';
import 'package:poltergeist_app/services/deep_links.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_app/services/workspace_windows/workspace_window_scope.dart';
import 'package:poltergeist_app/services/workspace_windows/workspace_windows.dart';
import 'package:poltergeist_app/ui/workspace_shell.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../services/engine_session_test.dart' as session_test;
import '../services/workspace_windows_test.dart' show FakeWindowHost;
import '../support/fake_bookmark_store.dart';
import '../support/fake_sync_backup.dart';

const _serverId = '123e4567-e89b-42d3-a456-426614174000';

void main() {
  testWidgets('the active workspace owns queued link dialogs', (tester) async {
    final coordinator = DeepLinkCoordinator();
    coordinator.add(
      Uri(
        scheme: poltergeistDeepLinkScheme,
        host: poltergeistBrowseRoute,
        queryParameters: const {
          'host': 'files.example.com',
          'port': '22',
          'username': 'deploy',
          'path': '/srv/site',
        },
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(deepLinks: coordinator),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('deepLink.review')), findsOneWidget);
    expect(find.text('files.example.com'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.byKey(const ValueKey('deepLink.cancel')));
    await tester.pumpAndSettle();
    await coordinator.idle;
  });

  testWidgets('raises the owning workspace before link review', (tester) async {
    final host = FakeWindowHost();
    final windows = WorkspaceWindows(
      host: host,
      quitApplication: () async {},
      afterFrame: () async {},
    );
    addTearDown(windows.dispose);
    await windows.start();
    final coordinator = DeepLinkCoordinator();

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(
          deepLinks: coordinator,
          window: windows.windows.single,
        ),
      ),
    );
    await tester.pumpAndSettle();

    coordinator.add(
      Uri.parse(
        'poltergeist://browse?host=files.example.com&port=22&'
        'username=deploy&path=%2Fsrv',
      ),
    );
    await tester.pumpAndSettle();

    expect(host.calls, ['activate 0']);
    expect(find.byKey(const ValueKey('deepLink.review')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.byKey(const ValueKey('deepLink.cancel')));
    await tester.pumpAndSettle();
    await coordinator.idle;
  });

  testWidgets('moves an open review to the newly active workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = FakeWindowHost();
    final windows = WorkspaceWindows(
      host: host,
      quitApplication: () async {},
      afterFrame: () async {},
    );
    addTearDown(windows.dispose);
    await windows.start();
    await windows.openWindow();
    final main = windows.windows.first;
    final extra = windows.windows.last;
    final coordinator = DeepLinkCoordinator();

    await tester.pumpWidget(
      _MultiWorkspaceHarness(windows: windows, coordinator: coordinator),
    );
    await tester.pumpAndSettle();
    coordinator.add(
      Uri.parse(
        'poltergeist://browse?host=files.example.com&port=22&'
        'username=deploy&path=%2Fsrv',
      ),
    );
    await tester.pumpAndSettle();

    Finder reviewIn(WorkspaceWindow window) => find.descendant(
      of: find.byKey(ValueKey('deepLink.window.${window.viewId}')),
      matching: find.byKey(const ValueKey('deepLink.review')),
    );

    expect(reviewIn(extra), findsOneWidget);
    expect(reviewIn(main), findsNothing);

    await main.activate();
    await tester.pumpAndSettle();

    expect(reviewIn(extra), findsNothing);
    expect(reviewIn(main), findsOneWidget);
    expect(find.byKey(const ValueKey('deepLink.review')), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(
      find.descendant(
        of: find.byKey(ValueKey('deepLink.window.${main.viewId}')),
        matching: find.byKey(const ValueKey('deepLink.connect')),
      ),
    );
    await tester.pumpAndSettle();
    await coordinator.idle;

    expect(find.byKey(const ValueKey('deepLink.review')), findsNothing);
  });

  testWidgets('a stale handler cannot reclaim a newly active workspace', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1600, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final host = FakeWindowHost();
    final windows = WorkspaceWindows(
      host: host,
      quitApplication: () async {},
      afterFrame: () async {},
    );
    addTearDown(windows.dispose);
    await windows.start();
    await windows.openWindow();
    final main = windows.windows.first;
    final extra = windows.windows.last;
    final coordinator = DeepLinkCoordinator();
    await tester.pumpWidget(
      _MultiWorkspaceHarness(windows: windows, coordinator: coordinator),
    );
    await tester.pumpAndSettle();
    host.calls.clear();

    await main.activate();
    coordinator.add(
      Uri.parse(
        'poltergeist://browse?host=files.example.com&port=22&'
        'username=deploy&path=%2Fsrv',
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(ValueKey('deepLink.window.${extra.viewId}')),
        matching: find.byKey(const ValueKey('deepLink.review')),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.byKey(ValueKey('deepLink.window.${main.viewId}')),
        matching: find.byKey(const ValueKey('deepLink.review')),
      ),
      findsOneWidget,
    );
    expect(host.calls, isNot(contains('activate ${extra.viewId}')));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.tap(find.byKey(const ValueKey('deepLink.cancel')));
    await tester.pumpAndSettle();
    await coordinator.idle;
  });

  testWidgets('an unresolved catalog link stops at an error', (tester) async {
    final coordinator = DeepLinkCoordinator();
    coordinator.add(
      Uri.parse(
        'poltergeist://browse?'
        'serverId=123e4567-e89b-42d3-a456-426614174000&path=%2Fsrv',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(deepLinks: coordinator),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('deepLink.failure')), findsOneWidget);
    expect(
      find.text(
        'The linked server is not in your synchronized server catalog.',
      ),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('deepLink.review')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('deepLink.failure.close')));
    await tester.pumpAndSettle();
    await coordinator.idle;
  });

  testWidgets('a catalog link opens its decoded path without review', (
    tester,
  ) async {
    final scratch = Directory.systemTemp.createTempSync('pg-deep-link-');
    addTearDown(() => scratch.deleteSync(recursive: true));
    final navigatorKey = GlobalKey<NavigatorState>();
    final engine = session_test.FakeAppEngine()
      ..localChannels.addAll([
        session_test.FakeAppBrowseChannel(),
        session_test.FakeAppBrowseChannel(),
      ])
      ..channel = session_test.FakeAppBrowseChannel(homePath: '/srv');
    addTearDown(engine.close);
    final bookmarks = FakeBookmarkStore();
    final session = await startEngineSession(
      supportDirectoryPath: scratch.path,
      bookmarks: bookmarks,
      navigatorKey: navigatorKey,
      pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(),
      spawn: (_) async => engine,
    );
    addTearDown(session!.shutdown);

    const server = ServerConfig(
      id: _serverId,
      label: 'Files',
      host: 'files.example',
      port: 22,
      username: 'deploy',
      authMethod: AuthMethod.agent,
      createdAt: 1,
      updatedAt: 1,
    );
    final credentials = FakeSyncCredentialStore()
      ..token = 'token'
      ..vaultKey = List.filled(32, 7);
    final enrollment = FakeSyncEnrollmentState()
      ..enrolled = const SyncAccount(
        baseUrl: 'https://sync.example',
        username: 'deploy',
        mode: SyncAccountMode.shared,
      );
    var records = InMemorySyncRecordStore();
    final backup = BookmarkBackupService(
      credentials: credentials,
      retainedTokens: FakeRetainedSyncTokenStore(),
      enrollmentState: enrollment,
      records: records,
      resetRecords: () async => records = InMemorySyncRecordStore(),
      bookmarks: FakeSyncTrackingBookmarkStore(),
      hostKeys: InMemoryConflictAwareHostKeyStore(),
      pinVerdicts: InMemoryPinVerdictStore(),
      tripwires: InMemorySyncTripwireStore(),
      transportFactory: fakeTransportFactory(FakeSyncServer(), []),
      vaultKey: () async => credentials.vaultKey,
      servers: FakeSyncTrackingServerStore([server]),
      vaultStore: InMemoryVaultStore(),
      serverCatalogPublisher: session.publishServerCatalog,
    );
    addTearDown(backup.dispose);
    await backup.load();

    final coordinator = DeepLinkCoordinator();
    coordinator.add(
      Uri.parse(
        'poltergeist://browse?serverId=$_serverId&'
        'path=%2Fsrv%2Freports%20%26%20plans',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: WorkspaceShell(
          bookmarks: bookmarks,
          engineSession: session,
          bookmarkBackup: backup,
          deepLinks: coordinator,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await coordinator.idle;

    expect(find.byKey(const ValueKey('deepLink.review')), findsNothing);
    expect(find.byKey(const ValueKey('deepLink.failure')), findsNothing);
    expect(engine.openCalls.single.serverId, _serverId);
    expect(engine.channel!.listCalls, contains('/srv/reports & plans'));
  });
}

final class _MultiWorkspaceHarness extends StatelessWidget {
  const _MultiWorkspaceHarness({
    required this.windows,
    required this.coordinator,
  });

  final WorkspaceWindows windows;
  final DeepLinkCoordinator coordinator;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: windows,
    builder: (context, _) => Row(
      textDirection: TextDirection.ltr,
      children: [
        for (final window in windows.windows)
          Expanded(
            child: KeyedSubtree(
              key: ValueKey('deepLink.window.${window.viewId}'),
              child: MaterialApp(
                navigatorKey: window.navigatorKey,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: WorkspaceWindowScope(
                  window: window,
                  active: window.isActive,
                  child: WorkspaceShell(window: window, deepLinks: coordinator),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
