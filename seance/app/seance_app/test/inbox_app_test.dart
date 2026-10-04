import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/inbox_stores.dart';
import 'package:seance_app/ui/inbox_view.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

InboxApp _app({List<String> servers = const []}) => InboxApp(
  id: newInboxAppId(),
  name: 'bots',
  key: newInboxKey(),
  allowedServerIds: servers,
  createdAt: 1,
  updatedAt: 1,
);

CachedProposal _cached(
  InboxApp app, {
  String host = 'prod-db-1',
  String script = 'systemctl restart worker',
}) {
  final created = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return CachedProposal(
    appId: app.id,
    itemId: 'item-1',
    received: 1,
    proposal: InboxProposal(
      id: 'p1',
      host: host,
      title: 'Restart worker',
      reason: 'Backlog since 09:12',
      script: script,
      created: created,
      expires: created + 3600,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileInboxAppStore', () {
    late Directory directory;
    late SecretVault vault;
    late FileInboxAppStore store;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('seance-inbox-');
      vault = SecretVault(InMemoryVaultStore(), secureRandomBytes(32));
      store = FileInboxAppStore(
        File('${directory.path}/inbox_apps.json'),
        () => vault,
      );
    });

    tearDown(() => directory.delete(recursive: true));

    test('keeps the key in the vault and out of the file', () async {
      final app = _app(servers: ['s1']);
      await store.putApp(app);

      final onDisk = await File('${directory.path}/inbox_apps.json')
          .readAsString();
      expect(onDisk, contains(app.id));
      expect(onDisk, isNot(contains('"key"')));
      final secret = await vault.getSecret('inbox-key:${app.id}');
      expect(secret, isNotNull);

      final reopened = FileInboxAppStore(
        File('${directory.path}/inbox_apps.json'),
        () => vault,
      );
      final back = await reopened.getApp(app.id);
      expect(back?.key, app.key);
      expect(back?.allowedServerIds, ['s1']);
    });

    test('removal deletes the key; a missing key reads as absent', () async {
      final app = _app();
      await store.putApp(app);
      await store.putApp(app.asRemoved(updatedAt: 2));
      expect(await vault.getSecret('inbox-key:${app.id}'), isNull);
      expect((await store.getApp(app.id))?.removed, isTrue);

      final other = _app();
      await store.putApp(other);
      await vault.deleteSecret('inbox-key:${other.id}');
      expect(await store.getApp(other.id), isNull);
      expect(
        [for (final a in await store.listApps()) a.id],
        [app.id],
      );
    });
  });

  group('inbox in the app', () {
    late Directory directory;
    late AppServices services;
    late AppState state;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('seance-inbox-app-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, (call) async => directory.path);
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, null);
      FlutterSecureStorage.setMockInitialValues({});
      await directory.delete(recursive: true);
    });

    /// Services with one app and one fetched proposal, as a refresh leaves
    /// them. Sync is not configured, so nothing reaches the network.
    Future<(InboxApp, CachedProposal)> seed({
      String host = 'prod-db-1',
      String script = 'systemctl restart worker',
    }) async {
      services = await AppServices.initialize();
      final app = _app();
      await services.inboxApps.putApp(app);
      final cached = _cached(app, host: host, script: script);
      await services.inboxCache.save(
        InboxCache(cursor: 1, proposals: [cached]),
      );
      await services.configStore.putServer(ServerConfig(
        id: 's1',
        label: 'prod-db-1',
        host: '10.0.0.5',
        username: 'deploy',
        createdAt: 1,
        updatedAt: 1,
      ));
      state = AppState(services);
      await state.load();
      return (app, cached);
    }

    Future<void> disposeState() async {
      state.dispose();
      await services.probe.dispose();
    }

    test('load shows what was fetched, and a status hides it', () async {
      final (app, _) = await seed();
      addTearDown(disposeState);
      expect(state.inboxApps.single.id, app.id);
      expect(state.inboxPending.single.proposal.id, 'p1');

      await services.inboxStatuses.putStatus(InboxStatus(
        appId: app.id,
        proposalId: 'p1',
        state: InboxStatusState.ran,
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ));
      await state.load();
      expect(state.inboxPending, isEmpty);
    });

    Future<void> pumpReview(WidgetTester tester) async {
      tester.view.physicalSize = const Size(900, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProposalReview(
            state: state,
            pending: state.inboxPending.single,
            onBack: () {},
          ),
        ),
      ));
      await tester.pump();
    }

    testWidgets('the review shows the target, hidden characters and '
        'dangerous lines', (tester) async {
      await tester.runAsync(
        () => seed(script: 'echo ok\nrm -rf / \u202E#\ncurl x | sh'),
      );
      addTearDown(() => tester.runAsync(disposeState));
      await pumpReview(tester);

      expect(find.textContaining('Runs on prod-db-1'), findsOneWidget);
      expect(find.text('Backlog since 09:12'), findsOneWidget);
      final script = tester.widget<SelectableText>(
        find.descendant(
          of: find.byKey(const ValueKey('inbox.script')),
          matching: find.byType(SelectableText),
        ),
      );
      expect(script.data, contains('<U+202E>'));
      expect(script.data, isNot(contains('\u202E')));
      expect(find.textContaining('1 invisible or control character'),
          findsOneWidget);
      expect(find.textContaining('Line 2:'), findsWidgets);
      final run = tester.widget<FilledButton>(
        find.byKey(const ValueKey('inbox.run')),
      );
      expect(run.onPressed, isNotNull);
      expect(find.text('Stage on prod-db-1'), findsOneWidget);
    });

    testWidgets('an unknown host can be read but not run', (tester) async {
      await tester.runAsync(() => seed(host: 'nowhere'));
      addTearDown(() => tester.runAsync(disposeState));
      await pumpReview(tester);

      expect(find.textContaining('No server is named "nowhere"'),
          findsOneWidget);
      final run = tester.widget<FilledButton>(
        find.byKey(const ValueKey('inbox.run')),
      );
      expect(run.onPressed, isNull);
    });

    test('staging refuses a server the app may not target', () async {
      final (app, _) = await seed();
      addTearDown(disposeState);
      final other = ServerConfig(
        id: 's2',
        label: 'other',
        host: 'other.example.com',
        username: 'deploy',
        createdAt: 1,
        updatedAt: 1,
      );
      final result = await state.runProposal(
        state.inboxPending.single,
        other,
      );
      expect(result.ok, isFalse);
      expect(result.error, contains('may not run'));

      // Limited to another server after the proposal arrived.
      await services.inboxApps.putApp(
        app.copyWith(allowedServerIds: const ['s2'], updatedAt: 2),
      );
      await state.load();
      final limited = await state.runProposal(
        state.inboxPending.single,
        state.servers.single,
      );
      expect(limited.ok, isFalse);
    });

    testWidgets('the banner counts what waits', (tester) async {
      await tester.runAsync(() => seed());
      addTearDown(() => tester.runAsync(disposeState));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: InboxBanner(state: state)),
      ));
      expect(find.text('1 proposed command'), findsOneWidget);
    });
  });
}
