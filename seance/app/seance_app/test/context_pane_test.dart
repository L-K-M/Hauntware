import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/local_reveal.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/context_pane.dart';
import 'package:seance_core/seance_core.dart';

const _pathChannel = MethodChannel('plugins.flutter.io/path_provider');

/// The Context tab lists what the session printed, newest first, and offers
/// what fits where the session runs: Files for a server's paths, the file
/// manager for a local shell's.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Directory? directory;
  AppServices? services;
  AppState? state;

  tearDown(() async {
    state?.dispose();
    state = null;
    await services?.probe.dispose();
    services = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathChannel, null);
    FlutterSecureStorage.setMockInitialValues({});
    try {
      await directory?.delete(recursive: true);
    } on FileSystemException {
      // Deliberately ignored: the OS reaps system temp dirs.
    }
    directory = null;
  });

  const server = ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  /// The pane over a connected session that has printed [output]. Returns
  /// the session and what it was sent.
  Future<(TerminalSession, List<String>)> pumpPane(
    WidgetTester tester, {
    required String output,
    ServerConfig? config,
  }) async {
    final session = TerminalSession(
      id: 'tab',
      serverId: config?.id ?? kLocalShellServerId,
      config: config,
      engine: XtermTerminalEngine(),
    );
    final sent = <String>[];
    session.engine.userInput.listen((bytes) => sent.add(utf8.decode(bytes)));
    await tester.runAsync(() async {
      directory = await Directory.systemTemp.createTemp('seance-context-');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_pathChannel, (_) async => directory!.path);
      FlutterSecureStorage.setMockInitialValues({});
      services = await AppServices.initialize();
      state = AppState(services!);
    });
    session
      ..session = _OpenSession(session.engine)
      ..connecting = false;
    state!
      ..tabs.add(session)
      ..activeTabId = session.id;

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AppScope(state: state!, child: child!),
        home: Scaffold(body: ContextPane(showFiles: () {})),
      ),
    );
    session.engine.feed(Uint8List.fromList(utf8.encode(output)));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    return (session, sent);
  }

  Future<List<String>> menuFor(WidgetTester tester, String label) async {
    final row = find.ancestor(
      of: find.text(label),
      matching: find.byType(ListTile),
    );
    await tester.tap(
      find.descendant(of: row, matching: find.byTooltip('Actions')),
    );
    await tester.pumpAndSettle();
    // The menu's value type is the pane's own, so match any item.
    return tester
        .widgetList(find.byWidgetPredicate((w) => w is PopupMenuItem))
        .map((item) => ((item as PopupMenuItem).child! as Text).data!)
        .toList();
  }

  testWidgets('a server session lists links and paths, newest first, and '
      'offers Files for its paths', (tester) async {
    await pumpPane(
      tester,
      config: server,
      output:
          'see https://example.com/a?b=1&c=2\r\nlog: /var/log/syslog\r\n\$ ',
    );

    final rows = tester
        .widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => tile.title)
        .toList();
    expect(rows, hasLength(2));
    expect(
      tester.getTopLeft(find.text('/var/log/syslog')).dy,
      lessThan(
        tester.getTopLeft(find.text('https://example.com/a?b=1&c=2')).dy,
      ),
    );

    expect(await menuFor(tester, '/var/log/syslog'), [
      'Show in Files',
      'Copy',
      'Insert at Prompt',
      'Remove',
    ]);
  });

  testWidgets('Insert at Prompt types a link as one shell word, without '
      'Enter', (tester) async {
    final (_, sent) = await pumpPane(
      tester,
      config: server,
      output: 'https://example.com/a?b=1&c=2\r\n\$ ',
    );

    expect(await menuFor(tester, 'https://example.com/a?b=1&c=2'), [
      'Open in Browser',
      'Copy',
      'Insert at Prompt',
      'Remove',
    ]);
    await tester.tap(find.text('Insert at Prompt').last);
    await tester.pumpAndSettle();
    expect(sent.join(), "'https://example.com/a?b=1&c=2'");
  });

  testWidgets('a local shell offers the file manager for its paths', (
    tester,
  ) async {
    await pumpPane(tester, output: '/etc/hosts\r\n\$ ');

    expect(await menuFor(tester, '/etc/hosts'), [
      LocalFileReveal.actionLabel,
      'Open',
      'Copy',
      'Insert at Prompt',
      'Remove',
    ]);
  });

  testWidgets('Open refuses a local program that has no extension', (
    tester,
  ) async {
    late final String program;
    await tester.runAsync(() async {
      final folder = await Directory.systemTemp.createTemp('seance-program-');
      addTearDown(() => folder.delete(recursive: true));
      program = '${folder.path}/runme';
      await File(program).writeAsString('#!/bin/sh\necho hi\n');
      await Process.run('chmod', ['755', program]);
    });
    await pumpPane(tester, output: '$program\r\n\$ ');

    await menuFor(tester, program);
    await tester.tap(find.text('Open').last);
    await tester.pumpAndSettle();
    // The file's mode is read on the real event loop.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    // The toast slides in.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.textContaining('could run as a program'), findsOneWidget);
    // Let the toast time out.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('Clear and Remove take items off the stack', (tester) async {
    final (session, _) = await pumpPane(
      tester,
      config: server,
      output: '/a.txt\r\n/b.txt\r\n\$ ',
    );
    expect(session.contextStack.items, hasLength(2));

    await menuFor(tester, '/a.txt');
    await tester.tap(find.text('Remove').last);
    await tester.pumpAndSettle();
    expect(find.text('/a.txt'), findsNothing);
    expect(find.text('/b.txt'), findsOneWidget);

    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.text('Nothing recognised yet'), findsOneWidget);
  });
}

class _OpenSession implements SshSession {
  _OpenSession(this.engine);

  @override
  final TerminalEngine engine;

  @override
  bool get isClosed => false;

  @override
  Future<void> close() => engine.dispose();

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
