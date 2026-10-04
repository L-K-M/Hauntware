import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:poltergeist_app/app.dart';
import 'package:poltergeist_app/services/engine_session.dart';
import 'package:poltergeist_core/poltergeist_core.dart';

import '../../../app/poltergeist_app/test/services/engine_session_test.dart' show FakeAppEngine, FakeAppBrowseChannel;
import '../../../app/poltergeist_app/test/support/fake_bookmark_store.dart';

const _out = '/home/paseo/workspace/Poltergeist/tasks/run3-task15-logs/reconnect/captures';
const _fonts = '/home/paseo/opt/flutter/bin/cache/dart-sdk/bin/resources/devtools/assets/fonts';

class _CaptureEngine extends FakeAppEngine {
  final held = Completer<void>();
  @override
  Future<AppBrowseChannel> openBrowseChannel({required String serverId,
      required String paneTabId, required ServerConfig config}) async {
    await held.future;
    return super.openBrowseChannel(serverId: serverId, paneTabId: paneTabId, config: config);
  }
}

class _RemoteChannel extends FakeAppBrowseChannel {
  _RemoteChannel() : super(homePath: '/srv/www');
  RemoteFileException? failure;
  Completer<List<RemoteFileEntry>>? nextListing;
  @override
  Future<List<RemoteFileEntry>> listDirectory(String path) async {
    final held = nextListing;
    nextListing = null;
    if (held != null) return held.future;
    final error = failure;
    if (error != null) throw error;
    return super.listDirectory(path);
  }
}

RemoteFileEntry _entry(String parent, String name, RemoteFileType type, int size) =>
    RemoteFileEntry(path: '$parent/$name', name: name, type: type, size: size,
      modifiedAt: DateTime.utc(2026, 9, 12, 10, 30));

void main() {
  testWidgets('readable production-shell widget captures, not native QA', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      for (final font in <(String, String)>[
        ('Roboto', 'Roboto/Roboto-Regular.ttf'),
        ('MaterialIcons', 'MaterialIcons-Regular.otf'),
        ('JetBrains Mono', 'Roboto_Mono/RobotoMono-Regular.ttf'),
      ]) {
        final loader = FontLoader(font.$1);
        loader.addFont(File('$_fonts/${font.$2}').readAsBytes().then((bytes) => ByteData.sublistView(bytes)));
        await loader.load();
      }
      Directory(_out).createSync(recursive: true);
    });
    final engine = _CaptureEngine();
    addTearDown(engine.close);
    for (var i = 0; i < 2; i++) {
      final local = FakeAppBrowseChannel(homePath: '/home/tester');
      local.listings[local.homePath] = [
        _entry(local.homePath, 'Documents', RemoteFileType.directory, 0),
        _entry(local.homePath, 'Photos', RemoteFileType.directory, 0),
        _entry(local.homePath, 'project-notes.txt', RemoteFileType.file, 18420),
        _entry(local.homePath, 'release-archive.zip', RemoteFileType.file, 5204000),
      ];
      engine.localChannels.add(local);
    }
    final remote = _RemoteChannel();
    remote.listings[remote.homePath] = [
      _entry(remote.homePath, 'assets', RemoteFileType.directory, 0),
      _entry(remote.homePath, 'index.html', RemoteFileType.file, 8096),
    ];
    engine.channel = remote;
    final now = DateTime.utc(2026, 9, 13);
    final store = FakeBookmarkStore([Bookmark(id: 'web', kind: BookmarkKind.remotePath,
      label: 'Web server', server: BookmarkServerRef(identity: EmbeddedHostIdentity(
        host: 'web.example.com', port: 22, username: 'deploy', authMethod: AuthMethod.password)),
      remotePath: '/', sortKey: 'web', createdAt: now, updatedAt: now)]);
    final navigatorKey = GlobalKey<NavigatorState>();
    final support = Directory.systemTemp.createTempSync('pg-readable-capture-');
    addTearDown(() => support.deleteSync(recursive: true));
    final session = await startEngineSession(supportDirectoryPath: support.path,
      bookmarks: store, navigatorKey: navigatorKey, pinStore: InMemoryHostKeyStore(),
      incidentStore: InMemoryIncidentStore(), spawn: (_) async => engine);
    expect(session, isNotNull);
    final captureKey = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(key: captureKey, child: PoltergeistApp(
      bookmarks: store, engineSession: session, navigatorKey: navigatorKey)));
    await tester.pumpAndSettle();

    Future<void> capture(String name) async {
      expect(tester.takeException(), isNull);
      final boundary = captureKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage();
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('$_out/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    expect(find.text('project-notes.txt'), findsNWidgets(2));
    await capture('local-both-panes');
    await tester.tap(find.byKey(const ValueKey('command.view.connections')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('connection.open.web')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byKey(const ValueKey('connection.open.web')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await capture('remote-connecting');
    engine.held.complete();
    await tester.pumpAndSettle();
    expect(find.text('index.html'), findsOneWidget);
    await capture('remote-connected');
    engine.statesControllers['web']!.add(const ServerStatus(ServerConnectionState.reconnecting));
    await tester.pumpAndSettle();
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('command.view.refresh'))).onPressed, isNull);
    await capture('remote-connection-lost');
    final held = Completer<List<RemoteFileEntry>>();
    remote.nextListing = held;
    engine.statesControllers['web']!.add(const ServerStatus(ServerConnectionState.connected));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(const ValueKey('pane.banner')), findsOneWidget);
    expect(tester.widget<TextButton>(find.byKey(const ValueKey('command.view.refresh'))).onPressed, isNull);
    await capture('healing-listing-pending');
    held.completeError(const RemoteFileException(kind: RemoteFileErrorKind.permissionDenied,
      operation: 'list', path: '/srv/www', message: 'Permission denied.'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('pane.banner.retry')), findsOneWidget);
    expect(find.byKey(const ValueKey('pane.error.retry')), findsNothing);
    await capture('healing-failed');
    final healed = _RemoteChannel();
    healed.listings[healed.homePath] = [_entry(healed.homePath, 'healed-index.html', RemoteFileType.file, 8096)];
    engine.channel = healed;
    await tester.tap(find.byKey(const ValueKey('pane.banner.retry')));
    await tester.pumpAndSettle();
    expect(find.text('healed-index.html'), findsOneWidget);
    expect(remote.closeCalls, 1);
    expect(find.byKey(const ValueKey('pane.banner')), findsNothing);
    await capture('healing-complete');
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    await session!.shutdown();
    expect(engine.shutdownCalls, 1);
  });
}
