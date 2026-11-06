import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/managed_remote_file.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory directory;
  late AppServices services;
  late AppState state;
  late int dialAttempts;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('seance-tab-cleanup-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, (_) async => directory.path);
    FlutterSecureStorage.setMockInitialValues({});
    services = await AppServices.initialize();
    dialAttempts = 0;
    state = AppState(
      services,
      openSshSession:
          (
            manager, {
            required config,
            required credentials,
            required engine,
            log,
          }) async {
            dialAttempts++;
            throw SshConnectException(
              'SSH error connecting',
              const SocketException('refused'),
              log!,
            );
          },
    );
  });

  tearDown(() async {
    final serverIds = state.tabs.map((tab) => tab.serverId).toSet();
    for (final serverId in serverIds) {
      await state.closeAllTabsForServer(serverId);
    }
    state.dispose();
    await services.probe.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory.delete(recursive: true);
    } on FileSystemException {
      // The operating system eventually reaps test temp directories.
    }
  });

  ServerConfig server(String id) => ServerConfig(
    id: id,
    label: id,
    host: '$id.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  TerminalSession terminal(
    String id, {
    required _RecordingTransport transport,
  }) {
    final tab = TerminalSession(
      id: id,
      serverId: 'server',
      config: server('server'),
      engine: transport.engine,
      connecting: false,
    );
    tab.session = transport;
    return tab;
  }

  ManagedRemoteFile copy(String editSessionId) => ManagedRemoteFile(
    id: 'managed-copy',
    serverId: 'server',
    editSessionId: editSessionId,
    remotePath: '/etc/motd',
    localPath: 'unsafe-checkout',
    remoteSnapshot: const RemoteFileEntry(
      path: '/etc/motd',
      name: 'motd',
      type: RemoteFileType.file,
      size: 3,
    ),
    baselineSha256: 'a' * 64,
  );

  test('a failed checkout delete cannot stop terminal teardown', () async {
    final engine = XtermTerminalEngine();
    final transport = _RecordingTransport(engine, failClose: true);
    final tab = terminal('first', transport: transport);
    final managed = copy(tab.editSessionId);
    await services.managedRemoteFiles.put(managed);
    // A directory where the checkout file belongs makes the guarded store
    // refuse deletion. This reproduces the old early exit before transport,
    // engine, notifier, and tab disposal.
    await Directory(
      services.managedRemoteFiles.checkoutFile(managed.localPath).path,
    ).create(recursive: true);
    tab.retainedLocalCopies[managed.remotePath] = managed;
    state.tabs.add(tab);
    state.focusTab(tab.id);
    final shown = <TabCloseReport>[];
    state.tabCleanupFailureReporter = shown.add;

    final report = await state.closeTab(tab.id);

    expect(report.failures.map((failure) => failure.operation), {
      'delete managed local copy',
      'close session transport',
    });
    expect(shown, [same(report)]);
    expect(state.tabs, isEmpty);
    expect(state.activeTabId, isNull);
    expect(tab.session, isNull);
    expect(tab.retainedLocalCopies, isEmpty);
    expect(transport.closeCalls, 1);
    expect(
      () => engine.activeCommand.addListener(() {}),
      throwsFlutterError,
      reason: 'engine disposal is the transport failure fallback',
    );
    expect(
      () => tab.metadata.addListener(() {}),
      throwsFlutterError,
      reason: 'terminal-owned notifiers are still disposed',
    );
    expect(
      await services.managedRemoteFiles.get(managed.id),
      managed,
      reason: 'a failed delete stays indexed for recovery',
    );
  });

  test('close all continues after an earlier session fails', () async {
    final firstTransport = _RecordingTransport(
      XtermTerminalEngine(),
      failClose: true,
    );
    final secondTransport = _RecordingTransport(XtermTerminalEngine());
    state.tabs.addAll([
      terminal('first', transport: firstTransport),
      terminal('second', transport: secondTransport),
    ]);

    final report = await state.closeAllTabsForServer('server');

    expect(report.failures, hasLength(1));
    expect(firstTransport.closeCalls, 1);
    expect(secondTransport.closeCalls, 1);
    expect(state.tabs, isEmpty);
  });

  test(
    'closing an inactive tab revokes chat before transport cleanup',
    () async {
      final closeGate = Completer<void>();
      final old = terminal(
        'old',
        transport: _RecordingTransport(
          XtermTerminalEngine(),
          closeGate: closeGate,
        ),
      );
      final other = terminal(
        'other',
        transport: _RecordingTransport(XtermTerminalEngine()),
      );
      state.tabs.addAll([old, other]);
      state.focusTab(other.id);
      final target = state.chatTargetFor(old);
      final conversation = state.chats.conversationFor(target);
      state.chats.select(target.key);
      final turn = conversation.addUserMessage('pending');

      final closing = state.closeTab(old.id);
      try {
        await pumpEventQueue();
        expect(state.activeTabId, other.id);
        expect(
          state.chats.targets.any((chat) => chat.key == target.key),
          isFalse,
        );
        expect(conversation.isCurrentTurn(turn), isFalse);
      } finally {
        closeGate.complete();
        await closing;
      }
    },
  );

  test(
    'inactive reconnect revokes changed chat before transport cleanup',
    () async {
      final closeGate = Completer<void>();
      final old = terminal(
        'old',
        transport: _RecordingTransport(
          XtermTerminalEngine(),
          closeGate: closeGate,
        ),
      );
      final other = terminal(
        'other',
        transport: _RecordingTransport(XtermTerminalEngine()),
      );
      state.tabs.addAll([old, other]);
      state.focusTab(other.id);
      final target = state.chatTargetFor(old);
      final conversation = state.chats.conversationFor(target);
      state.chats.select(target.key);
      final turn = conversation.addUserMessage('pending');
      state.servers.add(server('server').copyWith(host: 'changed.example.com'));

      final reconnecting = state.reconnect(old.id);
      try {
        await pumpEventQueue();
        expect(state.activeTabId, other.id);
        expect(
          state.chats.targets.any((chat) => chat.key == target.key),
          isFalse,
        );
        expect(conversation.isCurrentTurn(turn), isFalse);
      } finally {
        closeGate.complete();
        await reconnecting;
      }
    },
  );

  test(
    'reconnect transfers retained copies before old teardown fails',
    () async {
      final oldTransport = _RecordingTransport(
        XtermTerminalEngine(),
        failClose: true,
      );
      final old = terminal('old', transport: oldTransport);
      final managed = copy(old.editSessionId);
      old.retainedLocalCopies[managed.remotePath] = managed;
      state.tabs.add(old);
      state.focusTab(old.id);

      await state.reconnect(old.id);

      final replacement = state.tabs.single as TerminalSession;
      expect(replacement, isNot(same(old)));
      expect(replacement.editSessionId, old.editSessionId);
      expect(replacement.retainedLocalCopies, {managed.remotePath: managed});
      expect(old.retainedLocalCopies, isEmpty);
      expect(oldTransport.closeCalls, 1);
      expect(replacement.error, isNotNull, reason: 'the test dial is offline');
      expect(dialAttempts, 1);
    },
  );

  test(
    'closing a replacement while old teardown waits prevents a late dial',
    () async {
      final closeGate = Completer<void>();
      final oldTransport = _RecordingTransport(
        XtermTerminalEngine(),
        closeGate: closeGate,
      );
      final old = terminal('old', transport: oldTransport);
      state.tabs.add(old);
      state.focusTab(old.id);

      final reconnecting = state.reconnect(old.id);
      await pumpEventQueue();
      final replacement = state.tabs.single as TerminalSession;
      expect(replacement, isNot(same(old)));

      await state.closeTab(replacement.id);
      closeGate.complete();
      await reconnecting;

      expect(state.tabs, isEmpty);
      expect(dialAttempts, 0);
    },
  );
}

class _RecordingTransport implements SessionTransport {
  _RecordingTransport(this.engine, {this.failClose = false, this.closeGate});

  final XtermTerminalEngine engine;
  final bool failClose;
  final Completer<void>? closeGate;
  int closeCalls = 0;

  @override
  bool get isClosed => closeCalls > 0;

  @override
  void Function()? onClosed;

  @override
  Future<void> close() async {
    closeCalls++;
    await closeGate?.future;
    if (failClose) throw StateError('transport close failed');
    await engine.dispose();
  }

  @override
  void resize(TerminalSize size) {}
}
