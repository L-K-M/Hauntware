import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/inbox_stores.dart';
import 'package:seance_app/ui/inbox_view.dart';
import 'package:seance_core/catalog.dart' show SyncAccountScope;
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

final class _ProposalFileSystem implements RemoteFileSystem {
  final Map<String, List<int>> files = {};
  final Set<String> directories = {'/home/deploy'};
  final List<String> deleted = [];

  RemoteFileEntry _entry(String path, RemoteFileType type, [List<int>? data]) =>
      RemoteFileEntry(
        path: path,
        name: remoteBasename(path),
        type: type,
        size: data?.length,
        contentSha256: data == null ? null : sha256.convert(data).toString(),
      );

  @override
  Future<String> canonicalize(String path) async => '/home/deploy';

  @override
  Future<void> createDirectory(String path) async => directories.add(path);

  @override
  Future<void> delete(RemoteFileEntry entry) async {
    deleted.add(entry.path);
    files.remove(entry.path);
  }

  @override
  Future<void> setMode(String path, int permissions) async {}

  @override
  Future<RemoteFileEntry> stat(String path, {bool followLinks = true}) async {
    if (directories.contains(path)) {
      return _entry(path, RemoteFileType.directory);
    }
    final data = files[path];
    if (data != null) return _entry(path, RemoteFileType.file, data);
    throw RemoteFileException(
      kind: RemoteFileErrorKind.notFound,
      operation: 'stat',
      message: 'not found',
      path: path,
    );
  }

  @override
  Future<RemoteFileEntry> upload(
    String path,
    Stream<List<int>> content, {
    int? length,
    bool overwrite = false,
    int? preserveMode,
    RemoteFileEntry? expectedTarget,
    RemoteTransferProgress? onProgress,
    RemoteTransferCancellation? cancellation,
    bool computeHash = true,
  }) async {
    final data = [for (final chunk in await content.toList()) ...chunk];
    files[path] = data;
    return _entry(path, RemoteFileType.file, data);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _ProposalSshSession implements SshSession {
  @override
  final TerminalEngine engine;
  final _ProposalFileSystem fs;
  final BytesBuilder input = BytesBuilder();
  late final StreamSubscription<List<int>> _inputSubscription;
  bool _closed = false;

  _ProposalSshSession(this.engine, this.fs) {
    _inputSubscription = engine.userInput.listen(input.add);
  }

  String get inputText => utf8.decode(input.toBytes());

  @override
  bool get isClosed => _closed;

  @override
  void Function()? onClosed;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await engine.dispose();
    await _inputSubscription.cancel();
    onClosed?.call();
  }

  @override
  Future<RemoteFileSystem> openRemoteFileSystem({
    Duration timeout = const Duration(seconds: 15),
  }) async => fs;

  @override
  void resize(TerminalSize size) {}

  @override
  Future<RemoteCommandResult> runCommand(
    String command, {
    Duration? timeout,
    int maxOutputBytes = 256 * 1024,
  }) async => const RemoteCommandResult(exitCode: 1);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

enum _ClaimSessionChange { unchanged, closed, disconnected, reconnected }

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

  group('FileInboxCacheStore', () {
    late Directory directory;
    late File file;
    final account = SyncAccountScope(
      baseUrl: 'https://sync.example',
      username: 'alice',
    );

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('seance-inbox-cache-');
      file = File('${directory.path}/inbox_cache.json');
    });

    tearDown(() => directory.delete(recursive: true));

    test('discards a legacy cache whose account cannot be proven',
        () async {
      await file.writeAsString(jsonEncode(const InboxCache(
        cursor: 7,
        failures: {'app': 2},
      ).toJson()));
      final store = FileInboxCacheStore(
        file,
        scope: account,
      );

      final loaded = await store.load();
      final document = jsonDecode(await file.readAsString()) as Map;

      expect(loaded.cursor, 0);
      expect(loaded.failures, isEmpty);
      expect(document['version'], 1);
      expect(document['account'], account.toJson());
      expect((document['cache'] as Map)['cursor'], 0);
    });

    test('a different account clears cursor, proposals, and failures',
        () async {
      final first = FileInboxCacheStore(file, scope: account);
      await first.initialize();
      final app = _app();
      await first.save(InboxCache(
        cursor: 9,
        proposals: [_cached(app)],
        failures: const {'app': 3},
      ));

      final switched = FileInboxCacheStore(
        file,
        scope: SyncAccountScope(
          baseUrl: 'https://sync.example',
          username: 'bob',
        ),
      );
      final loaded = await switched.load();

      expect(loaded.cursor, 0);
      expect(loaded.proposals, isEmpty);
      expect(loaded.failures, isEmpty);
      expect(
        (jsonDecode(await file.readAsString()) as Map)['account'],
        {'baseUrl': 'https://sync.example', 'username': 'bob'},
      );
    });

    test('does not assign a disconnected legacy cache during enrollment',
        () async {
      await file.writeAsString(jsonEncode(const InboxCache(
        cursor: 11,
        failures: {'old': 4},
      ).toJson()));

      final enrolled = FileInboxCacheStore(
        file,
        scope: account,
        resetExisting: true,
      );
      final loaded = await enrolled.load();

      expect(loaded.cursor, 0);
      expect(loaded.failures, isEmpty);
    });

    test('a future cache version fails closed without rewriting it', () async {
      const original = '{"version":2,"account":{'
          '"baseUrl":"https://sync.example","username":"alice"},'
          '"cache":{"cursor":9,"proposals":[]}}';
      await file.writeAsString(original);
      final store = FileInboxCacheStore(
        file,
        scope: account,
        resetExisting: true,
      );

      await expectLater(store.load(), throwsFormatException);

      expect(await file.readAsString(), original);
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
      AppState Function(AppServices services)? buildState,
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
      state = buildState?.call(services) ?? AppState(services);
      await state.load();
      return (app, cached);
    }

    Future<void> disposeState() async {
      state.dispose();
      await services.probe.dispose();
    }

    Future<(ProposalRunResult, _ProposalFileSystem, _ProposalSshSession)>
    runWithSessionChange(_ClaimSessionChange change) async {
      final sessions = <_ProposalSshSession>[];
      late AppState built;
      await seed(
        buildState: (services) {
          built = AppState(
            services,
            openSshSession:
                (
                  manager, {
                  required config,
                  required credentials,
                  required engine,
                  log,
                }) async {
                  final session = _ProposalSshSession(
                    engine,
                    _ProposalFileSystem(),
                  );
                  sessions.add(session);
                  return session;
                },
            claimInboxProposal: (_) async {
              final tab = built.activeSession!;
              switch (change) {
                case _ClaimSessionChange.unchanged:
                  break;
                case _ClaimSessionChange.closed:
                  await built.closeTab(tab.id);
                case _ClaimSessionChange.disconnected:
                  await built.disconnect(tab.id);
                case _ClaimSessionChange.reconnected:
                  await built.reconnect(tab.id);
              }
              return InboxClaim.claimed;
            },
          );
          return built;
        },
      );
      await state.newTab(state.servers.single);
      final original = sessions.single;
      final result = await state.runProposal(
        state.inboxPending.single,
        state.servers.single,
      );
      await Future<void>.delayed(Duration.zero);
      return (result, original.fs, original);
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

    testWidgets('a command continued over lines is checked as one',
        (tester) async {
      await tester.runAsync(
        () => seed(script: 'echo ok\nuserdel \\\n  -r deploy'),
      );
      addTearDown(() => tester.runAsync(disposeState));
      await pumpReview(tester);

      // One critical finding, on the line where the command starts.
      expect(find.textContaining('Line 2:'), findsOneWidget);
      expect(find.textContaining('home directory'), findsOneWidget);
      expect(find.text('Line 2: Removes a user account.'), findsNothing);
      expect(find.textContaining('Line 3:'), findsNothing);
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
      expect(result, isA<ProposalRunFailed>());
      expect((result as ProposalRunFailed).error, contains('may not run'));

      // Limited to another server after the proposal arrived.
      await services.inboxApps.putApp(
        app.copyWith(allowedServerIds: const ['s2'], updatedAt: 2),
      );
      await state.load();
      final limited = await state.runProposal(
        state.inboxPending.single,
        state.servers.single,
      );
      expect(limited, isA<ProposalRunFailed>());
    });

    for (final change in _ClaimSessionChange.values) {
      test(
        'a ${change.name} session after claim returns the right placement',
        () async {
          final (result, fs, original) = await runWithSessionChange(change);
          addTearDown(disposeState);
          final path = fs.files.keys.single;
          final commandLine = "sh '$path'";

          if (change == _ClaimSessionChange.unchanged) {
            expect(result, isA<ProposalPlaced>());
            expect((result as ProposalPlaced).commandLine, commandLine);
            expect(original.inputText, commandLine);
          } else {
            expect(result, isA<ProposalNeedsRecovery>());
            expect((result as ProposalNeedsRecovery).commandLine, commandLine);
            expect(original.inputText, isEmpty);
            expect(fs.deleted, isEmpty);
            expect(fs.files, hasLength(1));
          }
        },
      );
    }

    test('a handled-elsewhere retry preserves the shared staged script',
        () async {
      final sessions = <_ProposalSshSession>[];
      var claims = 0;
      await seed(
        buildState: (services) => AppState(
          services,
          openSshSession:
              (
                manager, {
                required config,
                required credentials,
                required engine,
                log,
              }) async {
                final session = _ProposalSshSession(
                  engine,
                  _ProposalFileSystem(),
                );
                sessions.add(session);
                return session;
              },
          claimInboxProposal: (_) async => switch (claims++) {
            0 => InboxClaim.claimed,
            1 => InboxClaim.handledElsewhere,
            _ => throw StateError('Unexpected extra claim'),
          },
        ),
      );
      addTearDown(disposeState);
      await state.newTab(state.servers.single);
      final pending = state.inboxPending.single;
      final original = sessions.single;

      final first = await state.runProposal(pending, state.servers.single);
      await Future<void>.delayed(Duration.zero);
      expect(first, isA<ProposalPlaced>());
      expect(state.inboxPending, isEmpty);
      final path = original.fs.files.keys.single;
      final bytes = List<int>.of(original.fs.files[path]!);
      final commandLine = "sh '$path'";
      expect((first as ProposalPlaced).commandLine, commandLine);
      expect(original.inputText, commandLine);

      final retry = await state.runProposal(pending, state.servers.single);
      expect(retry, isA<ProposalRunFailed>());
      expect(
        (retry as ProposalRunFailed).error,
        contains('Another device already ran or dismissed'),
      );
      expect(original.inputText, commandLine);
      expect(original.fs.deleted, isEmpty);
      expect(original.fs.files[path], orderedEquals(bytes));
    });

    testWidgets(
      'recovery survives review close and clipboard failure',
      (tester) async {
        await tester.runAsync(() => seed());
        addTearDown(() => tester.runAsync(disposeState));
        const commandLine =
            "sh '/home/deploy/.seance/inbox/proposal-item-1.sh'";
        final result = Completer<ProposalRunResult>();
        final navigatorKey = GlobalKey<NavigatorState>();

        String? copied;
        var failCopy = true;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              if (failCopy) {
                throw PlatformException(code: 'clipboard-unavailable');
              }
              copied = (call.arguments as Map)['text'] as String?;
            }
            return null;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            SystemChannels.platform,
            null,
          ),
        );

        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigatorKey,
            home: Scaffold(
              body: Builder(
                builder: (context) => FilledButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) => Dialog(
                      child: ProposalReview(
                        state: state,
                        pending: state.inboxPending.single,
                        onBack: () => Navigator.pop(dialogContext),
                        runProposal: (_, __) => result.future,
                      ),
                    ),
                  ),
                  child: const Text('Review proposal'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Review proposal'));
        await tester.pumpAndSettle();
        expect(find.byType(ProposalReview), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('inbox.run')));
        await tester.pump();
        navigatorKey.currentState!.pop();
        await tester.pumpAndSettle();
        expect(find.byType(ProposalReview), findsNothing);
        expect(
          find.byKey(const ValueKey('inbox.recovery.dialog')),
          findsNothing,
        );

        result.complete(
          const ProposalRunResult.needsRecovery(commandLine),
        );
        await tester.pumpAndSettle();

        expect(find.byType(ProposalReview), findsNothing);
        expect(
          find.byKey(const ValueKey('inbox.recovery.dialog')),
          findsOneWidget,
        );
        expect(find.textContaining('Reconnect to prod-db-1'), findsOneWidget);
        expect(find.textContaining('paste this command'), findsOneWidget);
        expect(find.textContaining('press Enter'), findsOneWidget);
        final command = tester.widget<SelectableText>(
          find.byKey(const ValueKey('inbox.recovery.command')),
        );
        expect(command.data, commandLine);
        expect(find.textContaining('Placed in the prompt'), findsNothing);
        expect(find.text('Copy command'), findsOneWidget);

        await tester.tap(find.text('Copy command'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Could not copy the command'),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('inbox.recovery.dialog')),
          findsOneWidget,
        );
        expect(command.data, commandLine);
        expect(copied, isNull);

        failCopy = false;
        await tester.tap(find.text('Copy command'));
        await tester.pumpAndSettle();
        expect(copied, commandLine);
        expect(find.text('Copied.'), findsOneWidget);
        await tester.pump(const Duration(minutes: 1));
        expect(
          find.byKey(const ValueKey('inbox.recovery.dialog')),
          findsOneWidget,
        );

        await tester.tap(find.text('Close'));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('inbox.recovery.dialog')),
          findsNothing,
        );
      },
    );

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
