import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/app_state.dart';
import 'package:seance_app/main.dart';
import 'package:seance_app/services/app_services.dart';
import 'package:seance_app/services/app_settings.dart';
import 'package:seance_app/services/chat_session.dart';
import 'package:seance_app/services/xterm_engine.dart';
import 'package:seance_app/ui/chat_sidebar.dart';
import 'package:seance_core/seance_core.dart';

class _Provider implements LlmProvider, ClosableLlmProvider {
  int requests = 0;
  int closeCalls = 0;
  Completer<ChatTurn>? pending;

  @override
  void close() => closeCalls++;

  @override
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  }) async {
    requests++;
    if (pending case final pending?) return pending.future;
    if (requests.isEven) return const ChatTurn(text: 'Ready.');
    return const ChatTurn(
      text: '',
      toolCalls: [
        ToolCall(
          id: 'paste',
          name: 'paste_to_prompt',
          arguments: {'command': 'pwd'},
        ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Services implements AppServices {
  final _Provider provider = _Provider();
  Completer<SearchProvider?>? pendingSearch;
  int builds = 0;
  @override
  final AppSettings settings = AppSettings();
  @override
  Future<LlmProvider> buildLlmProvider() async {
    builds++;
    return provider;
  }

  @override
  Future<SearchProvider?> buildSearchProvider() async => pendingSearch?.future;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Search implements SearchProvider, ClosableSearchProvider {
  int closeCalls = 0;

  @override
  void close() => closeCalls++;

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async =>
      const [];
}

class _Session implements TerminalSession {
  @override
  final String id;
  @override
  final String editSessionId;
  @override
  final String serverId;
  final String endpoint;
  bool connected = true;
  @override
  final XtermTerminalEngine engine = XtermTerminalEngine();
  _Session(this.id, {String? editSessionId, String? serverId, String? endpoint})
    : editSessionId = editSessionId ?? id,
      serverId = serverId ?? id,
      endpoint = endpoint ?? id;
  @override
  bool get isConnected => connected;
  @override
  bool get isLocal => false;
  @override
  String get displayTarget => endpoint;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _State extends ChangeNotifier implements AppState {
  @override
  final _Services services = _Services();
  @override
  final ChatConversationStore chats = ChatConversationStore();
  @override
  ChatSession get chat => chats.selectedSession;
  @override
  int get llmConfigVersion => 0;
  @override
  bool get includeTerminalContext => true;
  @override
  _Session? activeSession;
  final List<_Session> terminals = [];
  TerminalChatTarget targetFor(_Session session) => TerminalChatTarget(
    editSessionId: session.editSessionId,
    serverId: session.serverId,
    username: 'user',
    host: '${session.endpoint}.example',
    port: 22,
    isLocal: false,
    label: session.endpoint,
    description: session.endpoint,
  );
  @override
  TerminalChatTarget chatTargetFor(TerminalSession session) =>
      targetFor(session as _Session);
  @override
  TerminalSession? sessionForChatTarget(TerminalChatTarget target) => terminals
      .where((session) => targetFor(session).key == target.key)
      .firstOrNull;
  @override
  TerminalSession? tabById(String? id) =>
      terminals.where((session) => session.id == id).firstOrNull;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _State state;
  late _Session first;
  late _Session second;
  late List<String> firstInput;
  late List<String> secondInput;

  setUp(() {
    state = _State();
    first = _Session('first');
    second = _Session('second');
    state.terminals.addAll([first, second]);
    state.activeSession = first;
    state.chats.reconcile([
      state.targetFor(first),
      state.targetFor(second),
    ], initiallyActive: state.targetFor(first));
    firstInput = [];
    secondInput = [];
    first.engine.userInput.listen(
      (bytes) => firstInput.add(utf8.decode(bytes)),
    );
    second.engine.userInput.listen(
      (bytes) => secondInput.add(utf8.decode(bytes)),
    );
  });

  tearDown(() async {
    state.chats.dispose();
    state.dispose();
    await first.engine.dispose();
    await second.engine.dispose();
  });

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AppScope(
          state: state,
          child: const Scaffold(body: ChatSidebar()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.tap(find.byIcon(Icons.send));
    await tester.pump();
  }

  Future<void> select(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.textContaining(label).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('a remounted sidebar stages into the current turn target', (
    tester,
  ) async {
    await mount(tester);
    await send(tester, 'first turn');
    await tester.pumpAndSettle();
    expect(firstInput, ['pwd']);

    await tester.pumpWidget(const SizedBox());
    state.activeSession = second;
    await mount(tester);
    expect(state.chats.selectedTarget.key, state.targetFor(first).key);
    await select(tester, 'second');
    await send(tester, 'second turn');
    await tester.pumpAndSettle();

    expect(state.services.builds, 2, reason: 'each target owns a controller');
    expect(firstInput, ['pwd']);
    expect(secondInput, ['pwd']);
    expect(state.chat.entries, hasLength(2));
    state.chats.select(state.targetFor(first).key);
    expect(state.chat.entries, hasLength(2));
  });

  testWidgets('reset prevents a late tool from targeting the next turn', (
    tester,
  ) async {
    final oldReply = Completer<ChatTurn>();
    state.services.provider.pending = oldReply;
    await mount(tester);
    await send(tester, 'old turn');
    expect(state.services.provider.requests, 1);

    await tester.tap(find.byTooltip('New chat'));
    await tester.pump();
    final newReply = Completer<ChatTurn>();
    state.services.provider.pending = newReply;
    state.activeSession = second;
    await select(tester, 'second');
    await send(tester, 'new turn');
    expect(state.services.provider.requests, 2);

    oldReply.complete(
      const ChatTurn(
        text: '',
        toolCalls: [
          ToolCall(
            id: 'late',
            name: 'paste_to_prompt',
            arguments: {'command': 'old'},
          ),
        ],
      ),
    );
    await tester.pump();
    expect(firstInput, isEmpty);
    expect(secondInput, isEmpty);
    expect(state.services.provider.requests, 2);
    newReply.complete(const ChatTurn(text: 'New answer.'));
    await tester.pumpAndSettle();
    expect(state.chat.entries.map((entry) => entry.text), [
      'new turn',
      'New answer.',
    ]);
  });

  testWidgets('drafts survive target switches and sidebar remounts', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'first draft');
    await select(tester, 'second');
    await tester.enterText(find.byType(TextField), 'second draft');
    await select(tester, 'first');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'first draft',
    );

    await tester.pumpWidget(const SizedBox());
    await mount(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'first draft',
    );
    await select(tester, 'second');
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'second draft',
    );
    await select(tester, 'first');
    await tester.tap(find.byTooltip('New chat'));
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
  });

  testWidgets('General disables terminal context and cannot paste', (
    tester,
  ) async {
    await mount(tester);
    await select(tester, 'General');
    final chip = tester.widget<FilterChip>(
      find.widgetWithText(FilterChip, 'Include terminal output'),
    );
    expect(chip.onSelected, isNull);
    expect(find.textContaining('no terminal is selected'), findsOneWidget);

    await send(tester, 'general question');
    await tester.pumpAndSettle();

    expect(firstInput, isEmpty);
    expect(secondInput, isEmpty);
    expect(state.chat.entries.last.text, 'Ready.');
  });

  testWidgets('a reply remains in the conversation that sent it', (
    tester,
  ) async {
    final reply = Completer<ChatTurn>();
    state.services.provider.pending = reply;
    await mount(tester);
    await send(tester, 'question for first');
    await select(tester, 'second');

    reply.complete(const ChatTurn(text: 'answer for first'));
    await tester.pumpAndSettle();
    expect(state.chat.entries, isEmpty);

    await select(tester, 'first');
    expect(state.chat.entries.map((entry) => entry.text), [
      'question for first',
      'answer for first',
    ]);
  });

  testWidgets('switching away and back revokes a late paste', (tester) async {
    final reply = Completer<ChatTurn>();
    state.services.provider.pending = reply;
    await mount(tester);
    await send(tester, 'late command');
    await select(tester, 'second');
    await select(tester, 'first');

    reply.complete(
      const ChatTurn(
        text: '',
        toolCalls: [
          ToolCall(
            id: 'late',
            name: 'paste_to_prompt',
            arguments: {'command': 'echo late'},
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(firstInput, isEmpty);
    expect(find.textContaining('Nothing was pasted'), findsOneWidget);
  });

  testWidgets('disconnecting the captured terminal revokes a late paste', (
    tester,
  ) async {
    final reply = Completer<ChatTurn>();
    state.services.provider.pending = reply;
    await mount(tester);
    await send(tester, 'late command');
    first.connected = false;

    reply.complete(
      const ChatTurn(
        text: '',
        toolCalls: [
          ToolCall(
            id: 'late',
            name: 'paste_to_prompt',
            arguments: {'command': 'echo late'},
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(firstInput, isEmpty);
    expect(find.textContaining('disconnected'), findsOneWidget);
  });

  testWidgets('reconnecting the same logical target revokes a late paste', (
    tester,
  ) async {
    final reply = Completer<ChatTurn>();
    state.services.provider.pending = reply;
    await mount(tester);
    await send(tester, 'late command');
    final replacement = _Session(
      'replacement',
      editSessionId: first.editSessionId,
      serverId: first.serverId,
      endpoint: first.endpoint,
    );
    addTearDown(replacement.engine.dispose);
    final replacementInput = <String>[];
    replacement.engine.userInput.listen(
      (bytes) => replacementInput.add(utf8.decode(bytes)),
    );
    state.terminals[0] = replacement;
    state.activeSession = replacement;
    state.chats.reconcile([
      state.targetFor(replacement),
      state.targetFor(second),
    ], initiallyActive: state.targetFor(replacement));

    reply.complete(
      const ChatTurn(
        text: '',
        toolCalls: [
          ToolCall(
            id: 'late',
            name: 'paste_to_prompt',
            arguments: {'command': 'echo late'},
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(firstInput, isEmpty);
    expect(replacementInput, isEmpty);
    expect(find.textContaining('Nothing was pasted'), findsOneWidget);
  });

  testWidgets('stale controller construction closes both providers', (
    tester,
  ) async {
    final searchBuild = Completer<SearchProvider?>();
    final search = _Search();
    state.services.pendingSearch = searchBuild;
    await mount(tester);
    await send(tester, 'old turn');

    await tester.tap(find.byTooltip('New chat'));
    await tester.pump();
    searchBuild.complete(search);
    await tester.pump();
    await tester.pump();

    expect(state.services.provider.requests, 0);
    expect(state.services.provider.closeCalls, 1);
    expect(search.closeCalls, 1);
  });
}
