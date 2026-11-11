import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:klabautermann_app/controllers/container_terminals.dart';
import 'package:klabautermann_app/controllers/monitoring_controller.dart';
import 'package:klabautermann_app/controllers/operations_controller.dart';
import 'package:klabautermann_app/controllers/safety_controller.dart';
import 'package:klabautermann_app/l10n/app_localizations.dart';
import 'package:klabautermann_app/l10n/app_localizations_en.dart';
import 'package:klabautermann_app/ui/actions/action_entry.dart';
import 'package:klabautermann_app/ui/docker/container_details.dart';
import 'package:klabautermann_app/ui/docker/container_terminal.dart';
import 'package:klabautermann_app/ui/server_safety.dart';
import 'package:klabautermann_app/ui/workspace_dock.dart';
import 'package:klabautermann_core/klabautermann_core.dart';
import 'package:seance_terminal/seance_terminal.dart'
    show TerminalKeyboardBar, TerminalKeyboardBarStrings, TerminalView;

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
          // What the shell copies must read back as a paste.
          'Clipboard.setData' => clipboard = call.arguments['text'] as String?,
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
      final open = await start(tester);
      // Bash turns bracketed paste on at its prompt; without it every line
      // would run as it arrives, so even a clean paste would ask.
      await _emit(
        tester,
        engine,
        TerminalBytes(open.terminalId, _bytes('\x1b[?2004h')),
      );

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

    testWidgets('a link tap opens http and https links in the browser '
        'and only says of others that they cannot be opened', (tester) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        calls.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await pumpPane(tester);
      await start(tester);
      final view = tester.widget<TerminalView>(find.byType(TerminalView));

      for (final link in [
        'http://example.com/',
        'https://example.com/docs?q=1',
      ]) {
        view.onLinkTap!(Uri.parse(link));
        await tester.pump();
        expect(calls.map((call) => call.arguments['url']), [link]);
        calls.clear();
      }

      // Anything else a container prints never reaches the platform.
      for (final link in [
        'file:///etc/passwd',
        'ssh://example.com',
        'https://user:password@example.com',
      ]) {
        view.onLinkTap!(Uri.parse(link));
        await tester.pump();
        expect(calls, isEmpty, reason: link);
      }
      expect(
        find.text('The link could not be opened in a browser.'),
        findsWidgets,
      );
    });

    testWidgets('a link the system refuses says it cannot be opened', (
      tester,
    ) async {
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await pumpPane(tester);
      await start(tester);
      tester.widget<TerminalView>(find.byType(TerminalView)).onLinkTap!(
        Uri.parse('https://example.com'),
      );
      // The launch's answer lands after this frame's build, so the
      // toast takes a second one to draw.
      await tester.pump();
      await tester.pump();
      expect(
        find.text('The link could not be opened in a browser.'),
        findsOneWidget,
      );
    });

    testWidgets('the context menu selects the whole buffer and clears '
        'the scrollback', (tester) async {
      await pumpPane(tester);
      await start(tester);
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      // Straight into the view's terminal: what the shell printed, enough
      // to scroll its first lines off the screen.
      view.terminal.write(
        [for (var i = 0; i < 80; i++) 'scrollback marker $i\r\n'].join(),
      );
      await tester.pump();
      expect(
        view.terminal.buffer.height,
        greaterThan(view.terminal.viewHeight),
      );

      await tester.tap(find.byType(TerminalView), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Select all'));
      await tester.pump();

      final selection = view.controller!.selection!;
      expect((selection.begin.x, selection.begin.y), (0, 0));
      expect(selection.end.y, view.terminal.buffer.height - 1);
      expect(
        view.terminal.buffer.getText(selection),
        contains('scrollback marker 0'),
      );

      await tester.tap(find.byType(TerminalView), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Clear scrollback'));
      await tester.pump();
      expect(view.terminal.buffer.height, view.terminal.viewHeight);
    });

    testWidgets('a long-press selection shows Copy, Paste and Select '
        'all above it, and Paste keeps the paste policy', (tester) async {
      await pumpPane(tester, platform: TargetPlatform.android);
      await start(tester);
      final view = tester.widget<TerminalView>(find.byType(TerminalView));
      view.terminal.write('echo hello world\r\n');
      await tester.pump();

      await tester.longPressAt(
        tester.getTopLeft(find.byType(TerminalView)) + const Offset(30, 14),
      );
      await tester.pump();
      expect(view.controller!.selection, isNotNull);
      await tester.pump();
      final toolbar = find.byType(AdaptiveTextSelectionToolbar);
      expect(toolbar, findsOneWidget);
      for (final label in ['Copy', 'Paste', 'Select all']) {
        expect(
          find.descendant(of: toolbar, matching: find.text(label)),
          findsOneWidget,
        );
      }

      // Copy fills the clipboard and ends the selection, as on the
      // platforms' own text.
      await tester.tap(
        find.descendant(of: toolbar, matching: find.text('Copy')),
      );
      await tester.pump();
      expect(clipboard, isNotNull);
      expect(clipboard, isNot(''));
      expect(view.controller!.selection, isNull);
      expect(toolbar, findsNothing);

      // Paste goes through the shell's own _paste, so the danger check
      // still asks before a flagged multi-line paste.
      clipboard = 'cd /tmp\nrm -rf /';
      view.controller!.setSelection(
        view.terminal.buffer.createAnchor(0, 0),
        view.terminal.buffer.createAnchor(4, 0),
      );
      view.onTouchSelectionEnd!();
      await tester.pump();
      await tester.tap(
        find.descendant(of: toolbar, matching: find.text('Paste')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Paste 2 lines?'), findsOneWidget);
      await tester.tap(find.text('Paste all'));
      await tester.pumpAndSettle();
      expect(_typed(engine), contains('cd /tmp\nrm -rf /'));

      // Select all grows the selection to the whole buffer and keeps
      // the toolbar above it.
      view.controller!.setSelection(
        view.terminal.buffer.createAnchor(0, 0),
        view.terminal.buffer.createAnchor(4, 0),
      );
      view.onTouchSelectionEnd!();
      await tester.pump();
      await tester.tap(
        find.descendant(of: toolbar, matching: find.text('Select all')),
      );
      await tester.pump();
      expect(
        view.controller!.selection!.end.y,
        view.terminal.buffer.height - 1,
      );
      expect(toolbar, findsOneWidget);
    });

    testWidgets('the keyboard bar takes its labels from the ARB', (
      tester,
    ) async {
      await pumpPane(tester, platform: TargetPlatform.android);
      await start(tester);
      final bar = tester.widget<TerminalKeyboardBar>(
        find.byType(TerminalKeyboardBar),
      );
      final en = AppLocalizationsEn();
      // The package's const English defaults are the unlocalized
      // instance; a constructed one binds every label to the ARB.
      expect(
        identical(bar.strings, const TerminalKeyboardBarStrings()),
        isFalse,
      );
      final expected = TerminalKeyboardBarStrings(
        escape: en.dockerShellKeyEscape,
        tab: en.dockerShellKeyTab,
        controlModifier: en.dockerShellKeyControlModifier,
        controlC: en.dockerShellKeyControlC,
        leftArrow: en.dockerShellKeyLeftArrow,
        upArrow: en.dockerShellKeyUpArrow,
        downArrow: en.dockerShellKeyDownArrow,
        rightArrow: en.dockerShellKeyRightArrow,
        home: en.dockerShellKeyHome,
        end: en.dockerShellKeyEnd,
        pageUp: en.dockerShellKeyPageUp,
        pageDown: en.dockerShellKeyPageDown,
        pipe: en.dockerShellKeyPipe,
        slash: en.dockerShellKeySlash,
        hyphen: en.dockerShellKeyHyphen,
        tilde: en.dockerShellKeyTilde,
        hideKeyboard: en.dockerShellKeyHideKeyboard,
      );
      expect(
        (
          bar.strings.escape,
          bar.strings.tab,
          bar.strings.controlModifier,
          bar.strings.controlC,
          bar.strings.leftArrow,
          bar.strings.upArrow,
          bar.strings.downArrow,
          bar.strings.rightArrow,
          bar.strings.home,
          bar.strings.end,
          bar.strings.pageUp,
          bar.strings.pageDown,
          bar.strings.pipe,
          bar.strings.slash,
          bar.strings.hyphen,
          bar.strings.tilde,
          bar.strings.hideKeyboard,
        ),
        (
          expected.escape,
          expected.tab,
          expected.controlModifier,
          expected.controlC,
          expected.leftArrow,
          expected.upArrow,
          expected.downArrow,
          expected.rightArrow,
          expected.home,
          expected.end,
          expected.pageUp,
          expected.pageDown,
          expected.pipe,
          expected.slash,
          expected.hyphen,
          expected.tilde,
          expected.hideKeyboard,
        ),
      );
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

    testWidgets('on the desktop the inspector opens the shell in the '
        'workspace dock instead (OV-10)', (tester) async {
      final dock = WorkspaceDock();
      addTearDown(dock.dispose);
      await pumpScoped(
        tester,
        _allowed,
        WorkspaceDockScope(dock: dock, child: inspector()),
      );
      await tester.tap(find.byTooltip('Open a shell'));
      await tester.pump();

      expect(dock.items, [DockedShell(_serverId, _row)]);
      expect(find.byType(ContainerShellPane), findsNothing);
      expect(find.byTooltip('Open a shell'), findsOneWidget);
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
