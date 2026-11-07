import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:seance_app/services/chat_session.dart';
import 'package:seance_core/seance_core.dart';

class _EchoProvider implements LlmProvider, ClosableLlmProvider {
  int closeCalls = 0;

  @override
  void close() => closeCalls++;

  @override
  String get model => 'test';

  @override
  Future<List<String>> listModels() async => const [];

  @override
  Future<CommandSuggestion> generateCommand({
    required String prompt,
    HostContext context = HostContext.unknown,
  }) async => const CommandSuggestion(command: 'ls', explanation: '');

  @override
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  }) async => const ChatTurn(text: 'ok');

  @override
  Stream<String> streamChat({required List<LlmMessage> messages}) async* {
    yield 'ok';
  }
}

class _Search implements SearchProvider, ClosableSearchProvider {
  int closeCalls = 0;

  @override
  void close() => closeCalls++;

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async =>
      const [];
}

void main() {
  group('ChatSession survives the widget that shows it', () {
    test('holds the transcript across turns', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      expect(chat.isEmpty, isTrue);

      final turn = chat.addUserMessage('what is eating the disk?');
      expect(chat.sending, isTrue);
      expect(chat.entries.single.fromUser, isTrue);

      chat.addReply(
        turn,
        const ChatResult(
          reply: 'try du',
          stagedCommands: ['du -sh /var/*'],
          searchQueries: ['du usage'],
        ),
      );
      chat.finishSending(turn);

      expect(chat.sending, isFalse);
      expect(chat.entries.length, 2);
      expect(chat.entries.last.staged, ['du -sh /var/*']);
      expect(chat.entries.last.searches, ['du usage']);
    });

    test('a failed turn records the error and still stops sending', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final turn = chat.addUserMessage('hello');
      chat.failed(turn, StateError('provider unreachable'));
      chat.finishSending(turn);
      expect(chat.error, contains('provider unreachable'));
      expect(chat.sending, isFalse);
      // The user's message stays on screen so the retry has context.
      expect(chat.entries.single.text, 'hello');
    });

    test('a new turn clears the previous error', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final turn = chat.addUserMessage('one');
      chat.failed(turn, StateError('nope'));
      chat.finishSending(turn);
      chat.addUserMessage('two');
      expect(chat.error, isNull);
    });

    test('notifies listeners on every transition', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      var notifications = 0;
      chat.addListener(() => notifications++);
      final turn = chat.addUserMessage('hi');
      chat.addReply(turn, const ChatResult(reply: 'hello'));
      chat.finishSending(turn);
      expect(notifications, 3);
    });

    test('entries are not mutable through the getter', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      chat.addUserMessage('hi');
      expect(
        () => chat.entries.add(const ChatEntry(fromUser: false, text: 'x')),
        throwsUnsupportedError,
      );
    });

    test('bounds successful and failed transcript turns', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      for (var i = 0; i < 55; i++) {
        final turn = chat.addUserMessage('question $i');
        if (i.isEven) {
          chat.addReply(turn, const ChatResult(reply: 'answer'));
        } else {
          chat.failed(turn, StateError('failed'));
        }
        chat.finishSending(turn);
      }

      expect(chat.transcriptTurnCount, ChatSession.maxTranscriptTurns);
      expect(chat.entries.first.text, 'question 5');
      expect(
        chat.transcriptContentBytes,
        lessThanOrEqualTo(ChatSession.maxTranscriptContentBytes),
      );
    });

    test('clips each entry on a UTF-8 boundary including metadata', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final turn = chat.addUserMessage('question');
      chat.addReply(
        turn,
        ChatResult(
          reply: '😀' * 20000,
          searchQueries: const ['search that should not escape the cap'],
          stagedCommands: const ['echo bounded'],
        ),
      );
      chat.finishSending(turn);

      final reply = chat.entries.last;
      final bytes = [
        reply.text,
        ...reply.searches,
        ...reply.staged,
      ].fold<int>(0, (sum, value) => sum + utf8.encode(value).length);
      expect(bytes, lessThanOrEqualTo(ChatSession.maxEntryContentBytes));
      expect(reply.text, endsWith('…'));
      expect(utf8.decode(utf8.encode(reply.text)), reply.text);
    });

    test('reserves transcript space for staged-command safety metadata', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final turn = chat.addUserMessage('question');
      chat.addReply(
        turn,
        ChatResult(
          reply: 'x' * ChatSession.maxEntryContentBytes,
          searchQueries: const ['large reply should not erase the command'],
          stagedCommands: const ['rm -rf ./build-output'],
        ),
      );
      chat.finishSending(turn);

      final reply = chat.entries.last;
      expect(reply.staged, ['rm -rf ./build-output']);
      expect(reply.text, endsWith('…'));
      expect(
        [
          reply.text,
          ...reply.searches,
          ...reply.staged,
        ].fold<int>(0, (sum, value) => sum + utf8.encode(value).length),
        lessThanOrEqualTo(ChatSession.maxEntryContentBytes),
      );
    });

    test('keeps one bounded composer draft outside the widget', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      chat.updateDraft('😀' * 20000);
      expect(
        utf8.encode(chat.draft).length,
        lessThanOrEqualTo(ChatSession.maxEntryContentBytes),
      );
      expect(chat.draft, endsWith('…'));
    });
  });

  group('controller caching follows the provider settings', () {
    ChatController controller() =>
        ChatController(provider: _EchoProvider(), onPaste: (_) {});

    test('a controller is reused only for its own config version', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      expect(chat.controllerFor(0), isNull);

      final first = controller();
      chat.adoptController(first, 0);
      expect(chat.controllerFor(0), same(first));
      // Settings changed: the stale controller (old key/model) is not offered.
      expect(chat.controllerFor(1), isNull);

      final second = controller();
      chat.adoptController(second, 1);
      expect(chat.controllerFor(1), same(second));
    });

    test('replacing a controller closes its provider and search backend', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final firstProvider = _EchoProvider();
      final firstSearch = _Search();
      chat.adoptController(
        ChatController(
          provider: firstProvider,
          searchProvider: firstSearch,
          onPaste: (_) {},
        ),
        0,
      );

      chat.adoptController(
        ChatController(provider: _EchoProvider(), onPaste: (_) {}),
        1,
      );

      expect(firstProvider.closeCalls, 1);
      expect(firstSearch.closeCalls, 1);
    });

    test('disposing a session closes its controller exactly once', () {
      final chat = ChatSession();
      final provider = _EchoProvider();
      final search = _Search();
      chat.adoptController(
        ChatController(
          provider: provider,
          searchProvider: search,
          onPaste: (_) {},
        ),
        0,
      );

      chat.dispose();

      expect(provider.closeCalls, 1);
      expect(search.closeCalls, 1);
    });

    test('invalidation closes the controller but preserves the transcript', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final provider = _EchoProvider();
      chat.adoptController(
        ChatController(provider: provider, onPaste: (_) {}),
        0,
      );
      final turn = chat.addUserMessage('keep this');
      chat.addReply(turn, const ChatResult(reply: 'and this'));
      chat.finishSending(turn);

      chat.invalidateController();

      expect(provider.closeCalls, 1);
      expect(chat.controllerFor(0), isNull);
      expect(chat.entries.map((entry) => entry.text), [
        'keep this',
        'and this',
      ]);
    });

    test('a disposed session rejects and closes a late controller', () {
      final chat = ChatSession()..dispose();
      final provider = _EchoProvider();
      final controller = ChatController(provider: provider, onPaste: (_) {});

      expect(() => chat.adoptController(controller, 0), throwsStateError);
      expect(provider.closeCalls, 1);
    });

    test('reset clears the transcript and the error', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      chat.adoptController(controller(), 0);
      final turn = chat.addUserMessage('hi');
      chat.failed(turn, StateError('boom'));
      chat.reset();
      expect(chat.isEmpty, isTrue);
      expect(chat.error, isNull);
    });

    test('reset mid-flight clears sending and orphans the turn', () {
      final chat = ChatSession();
      addTearDown(chat.dispose);
      final turn = chat.addUserMessage('slow question');
      expect(chat.sending, isTrue);

      chat.reset();
      expect(chat.sending, isFalse, reason: 'the composer must not stay stuck');
      expect(chat.isEmpty, isTrue);

      // The in-flight turn resolves after the reset: its answer belongs to a
      // conversation the user has already ended.
      chat.addReply(turn, const ChatResult(reply: 'too late'));
      chat.failed(turn, StateError('also too late'));
      chat.finishSending(turn);
      expect(chat.isEmpty, isTrue);
      expect(chat.error, isNull);

      // A turn started after the reset still works.
      final next = chat.addUserMessage('new question');
      chat.addReply(next, const ChatResult(reply: 'answer'));
      chat.finishSending(next);
      expect(chat.entries.length, 2);
      expect(chat.sending, isFalse);
    });
  });

  group('ChatConversationStore', () {
    TerminalChatTarget target(
      String editSessionId, {
      String host = 'one.example',
      String label = 'One',
    }) => TerminalChatTarget(
      editSessionId: editSessionId,
      serverId: 'server',
      username: 'deploy',
      host: host,
      port: 22,
      isLocal: false,
      label: label,
      description: 'deploy@$host:22',
    );

    test('starts on active terminal if it opens before the assistant', () {
      final store = ChatConversationStore();
      addTearDown(store.dispose);
      store.reconcile(const []);
      final one = target('one');

      store.reconcile([one], initiallyActive: one);

      expect(store.selectedTarget.key, one.key);
    });

    test('the provisional target follows active focus until first mount', () {
      final store = ChatConversationStore();
      addTearDown(store.dispose);
      final one = target('one');
      final two = target('two', host: 'two.example', label: 'Two');
      store.reconcile([one, two], initiallyActive: one);

      store.reconcile([one, two], initiallyActive: two);
      store.initializeSelection();
      store.reconcile([one, two], initiallyActive: one);

      expect(store.selectedTarget.key, two.key);
    });

    test('a removed provisional target yields to the active open target', () {
      final store = ChatConversationStore();
      addTearDown(store.dispose);
      final one = target('one');
      final two = target('two', host: 'two.example', label: 'Two');
      store.reconcile([one, two], initiallyActive: one);

      store.reconcile([two], initiallyActive: two);
      store.initializeSelection();

      expect(store.selectedTarget.key, two.key);
    });

    test('opening the assistant with no tabs keeps General later', () {
      final store = ChatConversationStore();
      addTearDown(store.dispose);
      store.reconcile(const []);
      store.initializeSelection();
      final one = target('one');

      store.reconcile([one], initiallyActive: one);

      expect(store.selectedTarget, GeneralChatTarget.instance);
    });

    test('selection is explicit and does not follow focus', () {
      final store = ChatConversationStore();
      addTearDown(store.dispose);
      final one = target('one');
      final two = target('two', host: 'two.example', label: 'Two');
      store.reconcile([one, two], initiallyActive: one);
      store.initializeSelection();

      store.reconcile([one, two], initiallyActive: two);
      expect(store.selectedTarget.key, one.key);
      store.select(two.key);
      expect(store.selectedTarget.key, two.key);
    });

    test('reconnect preserves a key but changed fingerprint disposes it', () {
      final store = ChatConversationStore();
      addTearDown(store.dispose);
      final one = target('one');
      store.reconcile([one], initiallyActive: one);
      store.initializeSelection();
      final conversation = store.selectedSession;
      conversation.updateDraft('keep on reconnect');
      final provider = _EchoProvider();
      conversation.adoptController(
        ChatController(provider: provider, onPaste: (_) {}),
        0,
      );

      final relabeled = target('one', label: 'Renamed');
      store.reconcile([relabeled], initiallyActive: relabeled);
      expect(store.selectedSession, same(conversation));
      expect(store.selectedSession.draft, 'keep on reconnect');

      final moved = target('one', host: 'other.example');
      store.reconcile([moved], initiallyActive: moved);
      expect(store.selectedTarget, GeneralChatTarget.instance);
      expect(provider.closeCalls, 1);
    });

    test('provider invalidation covers every retained conversation', () {
      final store = ChatConversationStore();
      addTearDown(store.dispose);
      final one = target('one');
      store.reconcile([one], initiallyActive: one);
      final terminalChat = store.selectedSession;
      final terminalProvider = _EchoProvider();
      terminalChat.adoptController(
        ChatController(provider: terminalProvider, onPaste: (_) {}),
        0,
      );
      terminalChat.updateDraft('terminal draft');
      store.select(GeneralChatTarget.instance.key);
      final generalChat = store.selectedSession;
      final generalProvider = _EchoProvider();
      generalChat.adoptController(
        ChatController(provider: generalProvider, onPaste: (_) {}),
        0,
      );
      generalChat.updateDraft('general draft');

      store.invalidateControllers();

      expect(terminalProvider.closeCalls, 1);
      expect(generalProvider.closeCalls, 1);
      expect(terminalChat.draft, 'terminal draft');
      expect(generalChat.draft, 'general draft');
    });

    test('forwards only the selected conversation notifications', () {
      final store = ChatConversationStore();
      addTearDown(store.dispose);
      final one = target('one');
      store.reconcile([one], initiallyActive: one);
      final terminalChat = store.selectedSession;
      var notifications = 0;
      store.addListener(() => notifications++);
      terminalChat.updateDraft('silent');
      final turn = terminalChat.addUserMessage('selected');
      expect(notifications, 1);
      terminalChat.failed(turn, StateError('done'));
      terminalChat.finishSending(turn);
      store.select(GeneralChatTarget.instance.key);
      final afterSwitch = notifications;

      final later = terminalChat.addUserMessage('not selected');
      expect(notifications, afterSwitch);
      terminalChat.failed(later, StateError('done'));
      terminalChat.finishSending(later);
    });
  });
}
