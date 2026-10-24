import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/container_terminals.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/docker/container_details.dart';
import 'package:klabautermann_app/ui/docker/container_terminal.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:seance_terminal/seance_terminal.dart' show TerminalKeyboardBar;

import 'support/docker.dart';
import 'support/fake_engine.dart';

const _serverId = 'srv-1';
const _id = 'b7e9d0c1a2f3';

final _row = dockerContainer(_id, name: 'web-db', image: 'postgres:16');

const _allowed = SafetyPolicy(
  servers: {_serverId: ServerSafety(management: true)},
);

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

String _typed(FakeEngineClient engine) => [
  for (final input in engine.sentOfType<TerminalInput>().cast<TerminalInput>())
    utf8.decode(input.bytes),
].join();

/// Emits [event] and draws what it changed: the event arrives after the
/// next frame has begun, so a second frame shows it.
Future<void> _emit(
  WidgetTester tester,
  FakeEngineClient engine,
  EngineEvent event,
) async {
  engine.emit(event);
  await tester.pump();
  await tester.pump();
}

void main() {
  group('ContainerTerminals', () {
    late FakeEngineClient engine;
    late ContainerTerminals terminals;

    setUp(() {
      engine = FakeEngineClient();
      terminals = ContainerTerminals(engine);
    });

    tearDown(() async {
      terminals.dispose();
      await engine.close();
    });

    test('opens with fresh ids, a clamped size and blank fields left to '
        'the engine', () {
      final first = terminals.open(
        serverId: _serverId,
        containerId: _id,
        shell: '  ',
        user: '',
        columns: 0,
        rows: kTerminalDimensionMax + 5,
      );
      final second = terminals.open(
        serverId: _serverId,
        containerId: _id,
        shell: ' /bin/sh ',
        user: 'postgres',
        columns: 120,
        rows: 40,
      );

      expect(first.id, isNot(second.id));
      final [a, b] = engine.sentOfType<OpenTerminal>().cast<OpenTerminal>();
      expect(a.terminalId, first.id);
      expect((a.shell, a.user), (null, null));
      expect((a.columns, a.rows), (1, kTerminalDimensionMax));
      expect((b.shell, b.user), ('/bin/sh', 'postgres'));
      expect((b.columns, b.rows), (120, 40));
      expect(first.state.value, isA<ContainerShellOpening>());
    });

    test('follows the shell from opened to closed, with its output in '
        'order', () async {
      final shell = terminals.open(
        serverId: _serverId,
        containerId: _id,
        columns: 80,
        rows: 24,
      );
      final output = <String>[];
      final done = Completer<void>();
      shell.output.listen(
        (bytes) => output.add(utf8.decode(bytes)),
        onDone: done.complete,
      );

      engine
        ..emit(TerminalOpened(shell.id, ['/bin/bash']))
        ..emit(TerminalBytes(shell.id, _bytes('one ')))
        ..emit(TerminalBytes('another', _bytes('not ours')))
        ..emit(TerminalBytes(shell.id, _bytes('two')));
      await pumpEventQueue();
      expect((shell.state.value as ContainerShellRunning).command, [
        '/bin/bash',
      ]);

      shell
        ..write(_bytes('ls\r'))
        ..resize(columns: 2000, rows: 0);
      engine.emit(
        TerminalClosed(shell.id, TerminalCloseReason.exited, exitCode: 3),
      );
      await done.future;

      expect(output, ['one ', 'two']);
      final ended = shell.state.value as ContainerShellEnded;
      expect((ended.reason, ended.exitCode), (TerminalCloseReason.exited, 3));
      expect(_typed(engine), 'ls\r');
      final resize = engine.sentOfType<TerminalResize>().single;
      expect(
        ((resize as TerminalResize).columns, resize.rows),
        (kTerminalDimensionMax, 1),
      );

      // Nothing goes out for a shell that ended.
      final count = engine.sent.length;
      shell
        ..write(_bytes('x'))
        ..resize(columns: 10, rows: 10)
        ..close();
      expect(engine.sent, hasLength(count));
    });

    test('close sends CloseTerminal, and the engine answers it', () async {
      final shell = terminals.open(
        serverId: _serverId,
        containerId: _id,
        columns: 80,
        rows: 24,
      );
      shell.close();
      expect((engine.sent.last as CloseTerminal).terminalId, shell.id);

      engine.emit(TerminalClosed(shell.id, TerminalCloseReason.closed));
      await pumpEventQueue();
      expect(
        (shell.state.value as ContainerShellEnded).reason,
        TerminalCloseReason.closed,
      );
    });

    test('a rejected open ends the shells that heard nothing, not a '
        'running one', () async {
      final running = terminals.open(
        serverId: _serverId,
        containerId: _id,
        columns: 80,
        rows: 24,
      );
      engine.emit(TerminalOpened(running.id, ['/bin/sh']));
      await pumpEventQueue();
      final opening = terminals.open(
        serverId: _serverId,
        containerId: _id,
        columns: 80,
        rows: 24,
      );

      engine
        ..emit(const RequestRejected('Connect', 'unrelated'))
        ..emit(
          const RequestRejected('OpenTerminal', 'links are off in this engine'),
        );
      await pumpEventQueue();

      final ended = opening.state.value as ContainerShellEnded;
      expect(ended.reason, TerminalCloseReason.failed);
      expect(ended.detail, 'links are off in this engine');
      expect(running.state.value, isA<ContainerShellRunning>());
    });

    test('a stopped engine ends every shell, and later opens end at '
        'once', () async {
      final shell = terminals.open(
        serverId: _serverId,
        containerId: _id,
        columns: 80,
        rows: 24,
      );
      await engine.close();
      await pumpEventQueue();
      expect((shell.state.value as ContainerShellEnded).reason, isNull);

      final late = terminals.open(
        serverId: _serverId,
        containerId: _id,
        columns: 80,
        rows: 24,
      );
      expect((late.state.value as ContainerShellEnded).reason, isNull);
    });
  });

  group('ContainerShellPane', () {
    late FakeEngineClient engine;
    late MonitoringController monitoring;
    String? clipboard;

    setUp(() {
      engine = FakeEngineClient();
      monitoring = MonitoringController(engine);
      clipboard = null;
    });

    tearDown(() async {
      monitoring.dispose();
      await engine.close();
    });

    Future<void> pumpPane(
      WidgetTester tester, {
      TargetPlatform platform = TargetPlatform.linux,
    }) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async => switch (call.method) {
          'Clipboard.getData' => {'text': clipboard},
          _ => null,
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
          theme: ThemeData(platform: platform),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ContainerShellPane(
              monitoring: monitoring,
              serverId: _serverId,
              container: _row,
            ),
          ),
        ),
      );
    }

    /// Opens the shell from the user field's Done, which the shell
    /// field's open menu cannot cover.
    Future<OpenTerminal> start(WidgetTester tester) async {
      await tester.showKeyboard(find.byType(TextField).last);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      final open = engine.sentOfType<OpenTerminal>().last as OpenTerminal;
      await _emit(
        tester,
        engine,
        TerminalOpened(open.terminalId, ['/bin/bash']),
      );
      return open;
    }

    testWidgets('opens with the shell and user given, and forwards the '
        "view's size", (tester) async {
      await pumpPane(tester);
      await tester.enterText(find.byType(TextField).first, '/bin/sh');
      await tester.enterText(find.byType(TextField).last, 'postgres');
      final open = await start(tester);

      expect(open.containerId, _id);
      expect((open.shell, open.user), ('/bin/sh', 'postgres'));
      expect(find.text('Running /bin/bash'), findsOneWidget);
      // The view laid the terminal out at its own size, which reached the
      // far end.
      final resize = engine.sentOfType<TerminalResize>().last as TerminalResize;
      expect(resize.terminalId, open.terminalId);
      expect(resize.columns, greaterThan(24));
      expect(resize.rows, greaterThan(10));
    });

    testWidgets('a desktop pane has no keyboard bar', (tester) async {
      await pumpPane(tester);
      await start(tester);
      expect(find.byType(TerminalKeyboardBar), findsNothing);
    });

    testWidgets('a phone pane has the keyboard bar while the shell runs', (
      tester,
    ) async {
      await pumpPane(tester, platform: TargetPlatform.android);
      final open = await start(tester);
      expect(find.byType(TerminalKeyboardBar), findsOneWidget);

      await _emit(
        tester,
        engine,
        TerminalClosed(open.terminalId, TerminalCloseReason.exited),
      );
      expect(find.byType(TerminalKeyboardBar), findsNothing);
    });

    testWidgets('a one-line paste goes straight in', (tester) async {
      await pumpPane(tester);
      await start(tester);
      clipboard = 'echo hi';

      await tester.tap(find.byTooltip('Paste'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(_typed(engine), contains('echo hi'));
    });

    testWidgets('a flagged multi-line paste asks first, and the first line '
        'only pastes it without its break', (tester) async {
      await pumpPane(tester);
      await start(tester);
      clipboard = 'cd /tmp\nrm -rf /';

      await tester.tap(find.byTooltip('Paste'));
      await tester.pumpAndSettle();

      expect(find.text('Paste 2 lines?'), findsOneWidget);
      expect(find.textContaining('Line 2: '), findsOneWidget);
      expect(_typed(engine), isEmpty);

      await tester.tap(find.text('First line only'));
      await tester.pumpAndSettle();
      expect(_typed(engine), contains('cd /tmp'));
      expect(_typed(engine), isNot(contains('rm')));
      expect(_typed(engine), isNot(contains('\r')));
      expect(_typed(engine), isNot(contains('\n')));
    });

    testWidgets('a clean multi-line paste goes in line by line, and Cancel '
        'on a flagged one pastes nothing', (tester) async {
      await pumpPane(tester);
      await start(tester);

      clipboard = 'cd /tmp\nls';
      await tester.tap(find.byTooltip('Paste'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(_typed(engine), contains('cd /tmp\nls'));

      final before = _typed(engine);
      clipboard = 'ls\nrm -rf /';
      await tester.tap(find.byTooltip('Paste'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(_typed(engine), before);
    });

    testWidgets('an ended shell says why and opens again with the same '
        'settings', (tester) async {
      await pumpPane(tester);
      await tester.enterText(find.byType(TextField).last, 'root');
      final open = await start(tester);

      await _emit(
        tester,
        engine,
        TerminalClosed(
          open.terminalId,
          TerminalCloseReason.exited,
          exitCode: 0,
        ),
      );
      expect(find.text('The shell exited.'), findsOneWidget);
      expect(find.text('Exit code 0.'), findsOneWidget);
      expect(find.byTooltip('Paste'), findsNothing);

      await tester.tap(find.text('Open again'));
      await tester.pump();
      final again = engine.sentOfType<OpenTerminal>().last as OpenTerminal;
      expect(again.terminalId, isNot(open.terminalId));
      expect(again.user, 'root');
    });

    testWidgets('a refusal shows its reason and the daemon detail', (
      tester,
    ) async {
      await pumpPane(tester);
      await tester.tap(find.text('Open shell'));
      await tester.pump();
      final open = engine.sentOfType<OpenTerminal>().last as OpenTerminal;
      await _emit(
        tester,
        engine,
        TerminalClosed(
          open.terminalId,
          TerminalCloseReason.refused,
          detail: 'No such container: b7e9d0c1a2f3',
        ),
      );

      expect(
        find.text('The container is gone, or Docker refused the shell.'),
        findsOneWidget,
      );
      expect(find.text('No such container: b7e9d0c1a2f3'), findsOneWidget);
      await tester.tap(find.text('Change shell'));
      await tester.pump();
      expect(find.text('Open shell'), findsOneWidget);
    });

    testWidgets('closing the pane closes the shell', (tester) async {
      await pumpPane(tester);
      final open = await start(tester);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(
        engine.sentOfType<CloseTerminal>().cast<CloseTerminal>().map(
          (close) => close.terminalId,
        ),
        [open.terminalId],
      );
    });
  });

  group('entries (CTX-07)', () {
    late FakeEngineClient engine;
    late MonitoringController monitoring;
    late OperationsController operations;

    setUp(() {
      engine = FakeEngineClient();
      monitoring = MonitoringController(engine);
      operations = OperationsController(engine);
    });

    tearDown(() async {
      operations.dispose();
      monitoring.dispose();
      await engine.close();
    });

    Future<SafetyController> pumpScoped(
      WidgetTester tester,
      SafetyPolicy policy,
      Widget home,
    ) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final safety = SafetyController(initial: policy, apply: (_) {});
      addTearDown(safety.dispose);
      // The scopes sit over the Navigator, as in the app, so a pushed
      // route sees them. A phone platform, which the phone case needs.
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.android),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: (context, child) => SafetyScope(
            safety: safety,
            child: OperationsScope(operations: operations, child: child!),
          ),
          home: home,
        ),
      );
      return safety;
    }

    Widget inspector() => Scaffold(
      body: ContainerInspectorBody(
        monitoring: monitoring,
        inspected: InspectedContainer(serverId: _serverId, container: _row),
        onClose: () {},
      ),
    );

    testWidgets('the inspector swaps its details for a shell pane and '
        'back, which closes the shell', (tester) async {
      await pumpScoped(tester, _allowed, inspector());
      await tester.tap(find.byTooltip('Open a shell'));
      await tester.pump();
      expect(find.byType(ContainerShellPane), findsOneWidget);

      await tester.tap(find.text('Open shell'));
      await tester.pump();
      final open = engine.sentOfType<OpenTerminal>().last as OpenTerminal;

      await tester.tap(find.byTooltip('Show details'));
      await tester.pump();
      expect(find.byType(ContainerShellPane), findsNothing);
      expect(
        (engine.sentOfType<CloseTerminal>().single as CloseTerminal).terminalId,
        open.terminalId,
      );
    });

    testWidgets('read-only hides the entry and takes an open pane away', (
      tester,
    ) async {
      final safety = await pumpScoped(tester, _allowed, inspector());
      await tester.tap(find.byTooltip('Open a shell'));
      await tester.pump();
      await tester.tap(find.text('Open shell'));
      await tester.pump();

      await safety.setGlobalReadOnly(true);
      await tester.pump();
      expect(find.byTooltip('Open a shell'), findsNothing);
      expect(find.byType(ContainerShellPane), findsNothing);
      expect(engine.sentOfType<CloseTerminal>(), hasLength(1));
    });

    testWidgets('an observe-only server shows no shell entry', (tester) async {
      await pumpScoped(tester, const SafetyPolicy(), inspector());
      expect(find.byTooltip('Open a shell'), findsNothing);
    });

    testWidgets('a phone pushes the shell full screen', (tester) async {
      await pumpScoped(
        tester,
        _allowed,
        ContainerDetailsPage(
          monitoring: monitoring,
          serverId: _serverId,
          container: _row,
        ),
      );
      await tester.tap(find.byTooltip('Open a shell'));
      await tester.pumpAndSettle();

      expect(find.text('Shell in web-db'), findsOneWidget);
      expect(find.byType(ContainerShellPane), findsOneWidget);
    });

    testWidgets('read-only takes the pushed shell away too', (tester) async {
      final safety = await pumpScoped(
        tester,
        _allowed,
        ContainerDetailsPage(
          monitoring: monitoring,
          serverId: _serverId,
          container: _row,
        ),
      );
      await tester.tap(find.byTooltip('Open a shell'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open shell'));
      await tester.pump();

      await safety.setGlobalReadOnly(true);
      await tester.pump();
      expect(find.byType(ContainerShellPane), findsNothing);
      expect(engine.sentOfType<CloseTerminal>(), hasLength(1));
    });
  });
}
