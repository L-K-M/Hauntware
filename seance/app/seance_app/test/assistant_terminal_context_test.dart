import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/command_generator.dart';
import 'package:seance_app/ui/terminal_pane.dart';
import 'package:seance_core/seance_core.dart';

/// Output on the screen that the user may not want to leave the machine.
const _marker = 'customer-ledger-4711';

/// Records what each assistant surface hands the provider.
class _Provider implements LlmProvider {
  final List<List<LlmMessage>> chats = [];
  final List<String> prompts = [];
  Completer<CommandSuggestion>? pendingCommand;

  @override
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  }) async {
    chats.add(List.of(messages));
    return const ChatTurn(text: 'Done.');
  }

  @override
  Future<CommandSuggestion> generateCommand({
    required String prompt,
    HostContext context = HostContext.unknown,
  }) async {
    prompts.add(prompt);
    if (pendingCommand case final pending?) return pending.future;
    return const CommandSuggestion(command: 'true', explanation: 'Noop.');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ClosableProvider extends _Provider implements ClosableLlmProvider {
  int closeCalls = 0;

  @override
  void close() => closeCalls++;
}

class _Services implements AppServices {
  final _Provider provider = _Provider();
  LlmProvider? nextProvider;
  Completer<LlmProvider>? pendingProvider;
  int saves = 0;

  @override
  final AppSettings settings = AppSettings();
  @override
  final ProbeService probe = ProbeService();
  @override
  Future<void> saveSettings() async => saves++;
  @override
  Future<LlmProvider> buildLlmProvider() async {
    if (pendingProvider case final pending?) return pending.future;
    return nextProvider ?? provider;
  }
  @override
  Future<SearchProvider?> buildSearchProvider() async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _OpenShell implements SshSession {
  _OpenShell(this.engine);
  @override
  final TerminalEngine engine;
  bool closed = false;
  @override
  bool get isClosed => closed;
  @override
  Future<void> close() async {
    closed = true;
    await engine.dispose();
  }
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Services services;
  late AppState state;

  const server = ServerConfig(
    id: 'box',
    label: 'box',
    host: 'box.example.com',
    username: 'deploy',
    createdAt: 1,
    updatedAt: 1,
  );

  setUp(() {
    services = _Services();
    state = AppState(services);
    final tab = TerminalSession(
      id: 'tab',
      serverId: server.id,
      config: server,
      engine: XtermTerminalEngine(),
    );
    tab
      ..session = _OpenShell(tab.engine)
      ..connecting = false;
    tab.engine.feed(Uint8List.fromList(utf8.encode('$_marker\r\n')));
    state.tabs.add(tab);
    state.activeTabId = tab.id;
    state.llmConfigured = true;
  });

  tearDown(() => state.dispose());

  bool mentionsMarker(List<LlmMessage> request) =>
      request.any((message) => message.content.contains(_marker));

  group('Include terminal output', () {
    final chip = find.widgetWithText(FilterChip, 'Include terminal output');

    /// The phone layout: the assistant lives in an end drawer, whose child
    /// is unmounted every time the drawer closes.
    Future<void> pumpPhone(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => AppScope(state: state, child: child!),
          home: TerminalPane(showAssistantAffordance: true, onBack: () {}),
        ),
      );
      await tester.pump();
    }

    Future<void> openDrawer(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Assistant & snippets'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    Future<void> closeDrawer(WidgetTester tester) async {
      await tester.tapAt(const Offset(10, 400));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(chip, findsNothing, reason: 'the drawer unmounts the assistant');
    }

    Future<void> send(WidgetTester tester, String text) async {
      await tester.enterText(
        find.widgetWithText(TextField, 'Describe a task, or ask a question…'),
        text,
      );
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      await tester.pump();
    }

    testWidgets('an opt-out survives the drawer closing and reopening', (
      tester,
    ) async {
      await pumpPhone(tester);
      await openDrawer(tester);
      expect(tester.widget<FilterChip>(chip).selected, isTrue);
      await send(tester, 'first');
      expect(
        mentionsMarker(services.provider.chats.last),
        isTrue,
        reason: 'on by default, the request carries the screen',
      );

      await tester.tap(chip);
      await tester.pump();
      expect(tester.widget<FilterChip>(chip).selected, isFalse);
      await closeDrawer(tester);
      await openDrawer(tester);

      expect(tester.widget<FilterChip>(chip).selected, isFalse);
      await send(tester, 'second');
      expect(services.provider.chats, hasLength(2));
      expect(mentionsMarker(services.provider.chats.last), isFalse);
      expect(services.settings.includeTerminalContext, isFalse);
      expect(services.saves, 1, reason: 'the opt-out outlives a relaunch');
    });
  });

  group('the command generator', () {
    final checkbox = find.widgetWithText(
      CheckboxListTile,
      'Use recent terminal output as context',
    );

    Future<BuildContext> pumpHost(WidgetTester tester) async {
      late BuildContext host;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              host = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return host;
    }

    Future<void> open(WidgetTester tester, BuildContext host) async {
      showCommandGenerator(host, state);
      await tester.pumpAndSettle();
    }

    Future<void> generate(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField), 'list files');
      await tester.tap(find.text('Generate & insert'));
      await tester.pumpAndSettle();
      // Outlast the "inserted" toast's timer.
      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
    }

    testWidgets('shares the opt-out and keeps it across openings', (
      tester,
    ) async {
      final host = await pumpHost(tester);
      await open(tester, host);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      await generate(tester);
      expect(services.provider.prompts.last, contains(_marker));

      await open(tester, host);
      await tester.tap(checkbox);
      await tester.pump();
      expect(state.includeTerminalContext, isFalse, reason: 'one choice');
      await generate(tester);
      expect(services.provider.prompts, hasLength(2));
      expect(services.provider.prompts.last, isNot(contains(_marker)));

      await open(tester, host);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    });

    testWidgets('honours an opt-out made in the chat', (tester) async {
      await state.setIncludeTerminalContext(false);
      final host = await pumpHost(tester);
      await open(tester, host);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      await generate(tester);
      expect(services.provider.prompts.single, isNot(contains(_marker)));
    });

    testWidgets('a barrier dismissal ignores a late command response', (
      tester,
    ) async {
      final pending = Completer<CommandSuggestion>();
      services.provider.pendingCommand = pending;
      final host = await pumpHost(tester);
      await open(tester, host);

      await tester.enterText(find.byType(TextField), 'list files');
      await tester.tap(find.text('Generate & insert'));
      await tester.pump();
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(find.text('Generate a command'), findsNothing);

      pending.complete(
        const CommandSuggestion(command: 'echo late', explanation: 'Late.'),
      );
      await tester.pump();
      await tester.pump();

      expect(state.activeSession!.engine.pendingInput, isEmpty);
    });

    testWidgets('Escape dismissal ignores a late command response', (
      tester,
    ) async {
      final pending = Completer<CommandSuggestion>();
      services.provider.pendingCommand = pending;
      final host = await pumpHost(tester);
      await open(tester, host);

      await tester.enterText(find.byType(TextField), 'list files');
      await tester.tap(find.text('Generate & insert'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Generate a command'), findsNothing);

      pending.complete(
        const CommandSuggestion(command: 'echo late', explanation: 'Late.'),
      );
      await tester.pump();
      await tester.pump();

      expect(state.activeSession!.engine.pendingInput, isEmpty);
    });

    testWidgets('a provider built after cancellation closes without a request', (
      tester,
    ) async {
      final providerBuild = Completer<LlmProvider>();
      final owned = _ClosableProvider();
      services.pendingProvider = providerBuild;
      final host = await pumpHost(tester);
      await open(tester, host);

      await tester.enterText(find.byType(TextField), 'list files');
      await tester.tap(find.text('Generate & insert'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      providerBuild.complete(owned);
      await tester.pump();
      await tester.pump();

      expect(owned.prompts, isEmpty);
      expect(owned.closeCalls, 1);
    });

    testWidgets('cancellation closes an active provider exactly once', (
      tester,
    ) async {
      final pending = Completer<CommandSuggestion>();
      final owned = _ClosableProvider()..pendingCommand = pending;
      services.nextProvider = owned;
      final host = await pumpHost(tester);
      await open(tester, host);

      await tester.enterText(find.byType(TextField), 'list files');
      await tester.tap(find.text('Generate & insert'));
      await tester.pump();
      await tester.tapAt(const Offset(4, 4));
      await tester.pumpAndSettle();
      expect(owned.closeCalls, 1);

      pending.complete(
        const CommandSuggestion(command: 'echo late', explanation: 'Late.'),
      );
      await tester.pump();
      await tester.pump();
      expect(owned.closeCalls, 1);
    });

    testWidgets('success and failure each close their provider exactly once', (
      tester,
    ) async {
      final host = await pumpHost(tester);
      final successful = _ClosableProvider();
      services.nextProvider = successful;
      await open(tester, host);
      await generate(tester);
      expect(successful.closeCalls, 1);

      final failed = _ClosableProvider();
      final failure = Completer<CommandSuggestion>();
      failed.pendingCommand = failure;
      services.nextProvider = failed;
      await open(tester, host);
      await tester.enterText(find.byType(TextField), 'list files');
      await tester.tap(find.text('Generate & insert'));
      await tester.pump();
      failure.completeError(StateError('offline'));
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('offline'), findsOneWidget);
      expect(failed.closeCalls, 1);
    });

    testWidgets('a disconnected target cannot receive a late command', (
      tester,
    ) async {
      final pending = Completer<CommandSuggestion>();
      services.provider.pendingCommand = pending;
      final host = await pumpHost(tester);
      await open(tester, host);

      await tester.enterText(find.byType(TextField), 'list files');
      await tester.tap(find.text('Generate & insert'));
      await tester.pump();
      (state.activeSession!.session! as _OpenShell).closed = true;
      pending.complete(
        const CommandSuggestion(command: 'echo late', explanation: 'Late.'),
      );
      await tester.pump();
      await tester.pump();

      expect(state.activeSession!.engine.pendingInput, isEmpty);
      expect(find.textContaining('no longer connected'), findsOneWidget);
    });
  });
}
