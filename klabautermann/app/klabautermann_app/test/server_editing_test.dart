import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/fleet_controller.dart';
import 'package:klabautermann_app/controllers/server_editor_controller.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

import 'support/fake_engine.dart';
import 'support/harness.dart';
import 'support/sync_sign_in.dart';

const _desktop = Size(1280, 800);
const _phone = Size(400, 800);

const _servers = [
  FleetServer(id: 'srv-1', displayName: 'web-1', address: 'web-1.example'),
  FleetServer(
    id: 'imp-1',
    displayName: 'lab',
    address: 'lab.local',
    origin: FleetEntryOrigin.sshConfig,
  ),
];

/// The synced server srv-1 as the engine reads it back, with fields the
/// editor does not show.
const _stored = ServerDraft(
  id: 'srv-1',
  label: 'web-1',
  host: 'web-1.example',
  port: 22,
  username: 'deploy',
  auth: ServerDraftAuth.agent,
  loginScript: 'cd /srv',
  startDirectory: '/var/www',
  group: 'Prod',
);

/// In-app server editing (FL-03, M5 plan M09a): the entry points, shown
/// only while an account is enrolled (P16), and the requests they send.
void main() {
  Finder field(String label) => find.widgetWithText(TextFormField, label);
  final saveButton = find.widgetWithText(FilledButton, 'Save');

  Future<void> openRowMenu(WidgetTester tester, String title) async {
    await tester.tap(
      find.text(title),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
  }

  /// Scrolls the editor's own scrollable, not the rail's or a field's,
  /// until Save shows, and taps it.
  Future<void> tapSave(WidgetTester tester) async {
    await tester.scrollUntilVisible(
      saveButton,
      100,
      scrollable: find
          .descendant(
            of: find.descendant(
              of: find.byType(Dialog),
              matching: find.byType(SingleChildScrollView),
            ),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(saveButton);
    await tester.pumpAndSettle();
  }

  /// Lets a toast's dismissal timer run out, so no timer outlives the test.
  Future<void> outlastToasts(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  }

  String requestIdOf(EngineRequest request) => switch (request) {
    ReadServerDraft(:final requestId) ||
    SaveServer(:final requestId) ||
    TestServerConnection(:final requestId) ||
    DuplicateServer(:final requestId) ||
    DeleteServer(:final requestId) => requestId,
    _ => throw StateError('$request carries no edit id'),
  };

  group('desktop', () {
    testWidgets('without an account, adding is off and rows offer no edits', (
      tester,
    ) async {
      await pumpApp(tester, size: _desktop, servers: _servers);

      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      final add = tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, 'Add server'),
      );
      expect(add.onPressed, isNull);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      await openRowMenu(tester, 'web-1');
      expect(find.text('Edit…'), findsNothing);
      expect(find.text('Delete…'), findsNothing);
    });

    testWidgets('adding saves the typed server through the engine', (
      tester,
    ) async {
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Add server'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      // No start folder here.
      expect(field('Start folder (optional)'), findsNothing);

      await tester.enterText(field('Label'), 'box');
      await tester.enterText(field('Host'), 'box.example.com');
      await tester.enterText(field('Username'), 'ops');
      await tapSave(tester);

      final save = harness.engine.sentOfType<SaveServer>().single as SaveServer;
      expect(save.draft.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect(save.draft.label, 'box');
      expect(save.draft.host, 'box.example.com');
      expect(save.draft.username, 'ops');
      expect(save.draft.port, 22);
      expect(save.draft.auth, ServerDraftAuth.agent);
      // Still open until the engine answers.
      expect(find.byType(Dialog), findsOneWidget);

      harness.engine.emit(
        CatalogWritten(requestId: save.requestId, serverId: save.draft.id),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('Test connection tries the typed draft through the engine, '
        'saves nothing and reports its answer (M09b)', (tester) async {
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Add server'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Label'), 'box');
      await tester.enterText(field('Host'), 'box.example.com');
      await tester.enterText(field('Username'), 'ops');
      await tester.tap(find.text('ssh-agent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Password').last);
      await tester.pumpAndSettle();
      await tester.enterText(field('Password'), 'typed');

      final testButton = find.widgetWithText(OutlinedButton, 'Test connection');
      await tester.ensureVisible(testButton);
      await tester.tap(testButton);
      await tester.pump();
      final sent =
          harness.engine.sentOfType<TestServerConnection>().single
              as TestServerConnection;
      expect(sent.draft.host, 'box.example.com');
      expect(sent.draft.auth, ServerDraftAuth.password);
      expect(sent.credential.password, 'typed');

      harness.engine.emit(
        ServerConnectionTested(
          requestId: sent.requestId,
          ok: true,
          summary: 'Authenticated as ops@box.example.com:22 (password).',
          log: 'auth ok',
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.bySemanticsLabel('Connection test succeeded'),
        findsOneWidget,
      );
      expect(
        find.text('Authenticated as ops@box.example.com:22 (password).'),
        findsOneWidget,
      );
      expect(harness.engine.sentOfType<SaveServer>(), isEmpty);
      expect(find.byType(Dialog), findsOneWidget);
    });

    testWidgets('a pasted key can be imported from a file (M09b)', (
      tester,
    ) async {
      await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Add server'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ssh-agent'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Private key').last);
      await tester.pumpAndSettle();

      expect(find.text('Import from file…'), findsOneWidget);
    });

    testWidgets('a test the engine cannot run is a failed report, not a '
        'crash (M09b)', (tester) async {
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );
      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Add server'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Label'), 'box');
      await tester.enterText(field('Host'), 'box.example.com');
      await tester.enterText(field('Username'), 'ops');

      final testButton = find.widgetWithText(OutlinedButton, 'Test connection');
      await tester.ensureVisible(testButton);
      await tester.tap(testButton);
      await tester.pump();
      harness.engine.emit(
        const RequestRejected(
          'TestServerConnection',
          'links are off in this engine',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Connection test failed'), findsOneWidget);
      expect(find.text('Could not test the connection.'), findsOneWidget);
    });

    testWidgets('editing starts from the stored server and keeps what the '
        'form does not show', (tester) async {
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await openRowMenu(tester, 'web-1');
      await tester.tap(find.text('Edit…'));
      await tester.pumpAndSettle();
      final read =
          harness.engine.sentOfType<ReadServerDraft>().single
              as ReadServerDraft;
      expect(read.serverId, 'srv-1');
      harness.engine.emit(
        ServerDraftRead(requestId: read.requestId, draft: _stored),
      );
      await tester.pumpAndSettle();

      expect(find.text('Edit server'), findsOneWidget);
      expect(
        tester.widget<TextFormField>(field('Host')).controller!.text,
        'web-1.example',
      );
      await tester.enterText(field('Label'), 'web-1 (renamed)');
      await tapSave(tester);

      final save = harness.engine.sentOfType<SaveServer>().single as SaveServer;
      expect(save.draft.id, 'srv-1');
      expect(save.draft.label, 'web-1 (renamed)');
      expect(save.draft.group, 'Prod');
      expect(save.draft.loginScript, 'cd /srv');
      // Hidden here, and kept as it was opened.
      expect(save.draft.startDirectory, '/var/www');

      harness.engine.emit(
        CatalogWritten(requestId: save.requestId, serverId: 'srv-1'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsNothing);
    });

    testWidgets('a server a sync removed meanwhile says so instead', (
      tester,
    ) async {
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await openRowMenu(tester, 'web-1');
      await tester.tap(find.text('Edit…'));
      await tester.pumpAndSettle();
      final read = harness.engine.sentOfType<ReadServerDraft>().single;
      harness.engine.emit(
        ServerDraftRead(requestId: requestIdOf(read), draft: null),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(
        find.text('This server is no longer in your account.'),
        findsOneWidget,
      );
      await outlastToasts(tester);
    });

    testWidgets('a refused save says why and keeps the editor open', (
      tester,
    ) async {
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await tester.tap(find.byTooltip('Add'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(MenuItemButton, 'Add server'));
      await tester.pumpAndSettle();
      await tester.enterText(field('Label'), 'box');
      await tester.enterText(field('Host'), 'box.example.com');
      await tester.enterText(field('Username'), 'ops');
      await tapSave(tester);

      final save = harness.engine.sentOfType<SaveServer>().single;
      harness.engine.emit(
        CatalogWriteRefused(
          requestId: requestIdOf(save),
          failure: CatalogWriteFailure.notEnrolled,
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Could not save: Sign in to your sync account to edit servers.',
        ),
        findsOneWidget,
      );
      expect(find.byType(Dialog), findsOneWidget);
      await outlastToasts(tester);
    });

    testWidgets('Duplicate copies the server through the engine and says '
        'so (M09b)', (tester) async {
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await openRowMenu(tester, 'web-1');
      await tester.tap(find.text('Duplicate'));
      await tester.pumpAndSettle();
      final duplicate =
          harness.engine.sentOfType<DuplicateServer>().single
              as DuplicateServer;
      expect(duplicate.serverId, 'srv-1');

      harness.engine.emit(
        CatalogWritten(requestId: requestIdOf(duplicate), serverId: 'srv-2'),
      );
      await tester.pumpAndSettle();
      expect(find.text('Copied web-1'), findsOneWidget);
      await outlastToasts(tester);
    });

    testWidgets('an ssh_config import offers no Duplicate', (tester) async {
      await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await openRowMenu(tester, 'lab');
      expect(find.text('Duplicate'), findsNothing);
    });

    testWidgets('deleting asks first, naming the server', (tester) async {
      final harness = await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await openRowMenu(tester, 'web-1');
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      expect(find.text('Delete web-1?'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(harness.engine.sentOfType<DeleteServer>(), isEmpty);

      await openRowMenu(tester, 'web-1');
      await tester.tap(find.text('Delete…'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      final delete =
          harness.engine.sentOfType<DeleteServer>().single as DeleteServer;
      expect(delete.serverId, 'srv-1');

      harness.engine.emit(
        CatalogWriteRefused(
          requestId: delete.requestId,
          failure: CatalogWriteFailure.other,
          detail: 'disk full',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Nothing was saved: disk full'), findsOneWidget);
      await outlastToasts(tester);
    });

    testWidgets('an ssh_config import stays read-only', (tester) async {
      await pumpApp(
        tester,
        size: _desktop,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await openRowMenu(tester, 'lab');
      expect(find.text('Edit…'), findsNothing);
      expect(find.text('Delete…'), findsNothing);
    });
  });

  group('phone', () {
    testWidgets('the add button follows the enrollment', (tester) async {
      await pumpApp(tester, size: _phone, servers: _servers);

      final add = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.add),
      );
      expect(add.onPressed, isNull);
    });

    testWidgets('adding opens the editor once enrolled', (tester) async {
      await pumpApp(
        tester,
        size: _phone,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await tester.tap(find.byTooltip('Add server'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      expect(field('Host'), findsOneWidget);
    });

    testWidgets('Settings > Servers adds a server while enrolled', (
      tester,
    ) async {
      await pumpApp(
        tester,
        size: _phone,
        servers: _servers,
        syncAccount: testSyncAccount,
      );

      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      // The tab bar scrolls at phone width.
      await tester.ensureVisible(find.text('Servers'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Servers'));
      await tester.pumpAndSettle();
      expect(find.text('Servers in your account'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Add server'));
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
    });
  });

  group('controller', () {
    test(
      'a stopped engine fails what is pending and what comes after',
      () async {
        final engine = FakeEngineClient();
        final editor = ServerEditorController(engine);
        addTearDown(editor.dispose);

        final read = editor.read('srv-1');
        await engine.close();
        await expectLater(read, throwsA(isA<ServerEditEngineStopped>()));
        await expectLater(
          editor.delete('srv-1'),
          throwsA(isA<ServerEditEngineStopped>()),
        );
      },
    );

    test('a connection test completes with its answer, and a rejection '
        'fails it', () async {
      final engine = FakeEngineClient();
      final editor = ServerEditorController(engine);
      addTearDown(() async {
        editor.dispose();
        await engine.close();
      });

      final answered = editor.test(_stored, const ServerCredentialEntry());
      final rejected = editor.test(_stored, const ServerCredentialEntry());
      final first = engine.sent[0] as TestServerConnection;
      expect(first.draft, _stored);
      final tested = ServerConnectionTested(
        requestId: first.requestId,
        ok: false,
        summary: 'Authentication failed.',
        log: 'denied',
      );
      engine.emit(tested);
      expect(await answered, same(tested));

      engine.emit(const RequestRejected('TestServerConnection', 'links off'));
      await expectLater(rejected, throwsA(isA<ServerEditRefused>()));
    });

    test('answers find their requests by id', () async {
      final engine = FakeEngineClient();
      final editor = ServerEditorController(engine);
      addTearDown(() async {
        editor.dispose();
        await engine.close();
      });

      final first = editor.save(_stored, null);
      final second = editor.delete('srv-1');
      final sent = engine.sent;
      final saveId = (sent[0] as SaveServer).requestId;
      final deleteId = (sent[1] as DeleteServer).requestId;
      expect(saveId, isNot(deleteId));

      // Answered out of order.
      engine.emit(
        CatalogWriteRefused(
          requestId: deleteId,
          failure: CatalogWriteFailure.unknownTarget,
        ),
      );
      engine.emit(
        CatalogWritten(
          requestId: saveId,
          serverId: 'srv-1',
          credentialWritten: true,
        ),
      );
      final refused = expectLater(
        second,
        throwsA(
          isA<ServerEditRefused>().having(
            (e) => e.failure,
            'failure',
            CatalogWriteFailure.unknownTarget,
          ),
        ),
      );
      expect(await first, isTrue);
      await refused;
    });
  });
}
