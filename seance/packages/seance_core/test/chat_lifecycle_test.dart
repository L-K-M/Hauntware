import 'dart:async';

import 'package:seance_core/seance_core.dart';
import 'package:test/test.dart';

class _Provider implements LlmProvider, ClosableLlmProvider {
  final List<List<LlmMessage>> requests = [];
  final List<List<ToolSpec>> requestTools = [];
  Future<ChatTurn> Function() answer;
  int closeCalls = 0;
  _Provider(this.answer);

  @override
  void close() => closeCalls++;

  @override
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  }) {
    requests.add(messages);
    requestTools.add(tools);
    return answer();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Search implements SearchProvider, ClosableSearchProvider {
  final started = Completer<void>();
  final result = Completer<List<SearchResult>>();
  int closeCalls = 0;
  @override
  void close() => closeCalls++;
  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) {
    started.complete();
    return result.future;
  }
}

void main() {
  test('close releases providers once and refuses later sends', () async {
    final provider = _Provider(() async => const ChatTurn(text: 'answer'));
    final search = _Search();
    final controller = ChatController(
      provider: provider,
      searchProvider: search,
      onPaste: (_) {},
    );

    controller.close();
    controller.close();

    expect(provider.closeCalls, 1);
    expect(search.closeCalls, 1);
    await expectLater(controller.send('too late'), throwsStateError);
    expect(provider.requests, isEmpty);
  });

  test(
    'terminal context stays within the turn that opted into sharing it',
    () async {
      var requests = 0;
      final provider = _Provider(() async {
        requests++;
        if (requests == 1) {
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
        return const ChatTurn(text: 'answer');
      });
      final controller = ChatController(provider: provider, onPaste: (_) {});
      await controller.send(
        'first question',
        terminalContext: 'private terminal output',
      );
      await controller.send('second question');

      for (final request in provider.requests.take(2)) {
        expect(
          request.map((message) => message.content).join('\n'),
          contains('private terminal output'),
        );
      }
      final nextRequest = provider.requests.last
          .map((message) => message.content)
          .join('\n');
      expect(nextRequest, contains('first question'));
      expect(nextRequest, isNot(contains('private terminal output')));
    },
  );

  test(
    'reset discards a late reply without contaminating new history',
    () async {
      final lateReply = Completer<ChatTurn>();
      final provider = _Provider(() => lateReply.future);
      final controller = ChatController(provider: provider, onPaste: (_) {});
      final oldTurn = controller.send('old question');
      final cancelled = expectLater(oldTurn, throwsStateError);
      controller.reset();
      provider.answer = () async => const ChatTurn(text: 'new answer');
      await controller.send('new question');

      lateReply.complete(const ChatTurn(text: 'old answer'));
      await cancelled;
      await controller.send('follow-up');
      expect(provider.requests.last.map((message) => message.content), [
        kChatSystemPrompt,
        'new question',
        'new answer',
        'follow-up',
      ]);
    },
  );

  test(
    'reset during search prevents later tools and continuation requests',
    () async {
      final provider = _Provider(
        () async => const ChatTurn(
          text: '',
          toolCalls: [
            ToolCall(
              id: 'search',
              name: 'web_search',
              arguments: {'query': 'help'},
            ),
            ToolCall(
              id: 'paste',
              name: 'paste_to_prompt',
              arguments: {'command': 'pwd'},
            ),
          ],
        ),
      );
      final search = _Search();
      final pasted = <String>[];
      final controller = ChatController(
        provider: provider,
        searchProvider: search,
        onPaste: pasted.add,
      );
      final turn = controller.send('old question');
      final cancelled = expectLater(turn, throwsStateError);
      await search.started.future;
      controller.reset();
      search.result.complete(const []);
      await cancelled;

      expect(pasted, isEmpty);
      expect(provider.requests, hasLength(1));
      expect(controller.historyLength, 0);
    },
  );

  test(
    'general scope omits terminal data and refuses an unsolicited paste',
    () async {
      var requests = 0;
      final provider = _Provider(() async {
        requests++;
        if (requests == 1) {
          return const ChatTurn(
            text: '',
            toolCalls: [
              ToolCall(
                id: 'paste',
                name: 'paste_to_prompt',
                arguments: {'command': 'uname -a'},
              ),
            ],
          );
        }
        return const ChatTurn(text: 'No terminal was changed.');
      });
      final pasted = <String>[];
      final controller = ChatController(
        provider: provider,
        onPaste: pasted.add,
      );

      await controller.send(
        'help',
        terminalContext: 'secret terminal output',
        sessionTarget: 'root@production',
        onPaste: pasted.add,
        toolScope: ChatToolScope.general,
      );

      expect(provider.requestTools.first, ChatTools.general);
      expect(pasted, isEmpty);
      final allContent = provider.requests
          .expand((request) => request)
          .map((message) => message.content);
      expect(allContent, isNot(contains('secret terminal output')));
      expect(allContent, isNot(contains('root@production')));
      expect(
        provider.requests.last.last.content,
        contains('rejected: no terminal is selected'),
      );
    },
  );

  test('keeps at most twenty complete successful turns', () async {
    final provider = _Provider(() async => const ChatTurn(text: 'answer'));
    final controller = ChatController(provider: provider, onPaste: (_) {});

    for (var i = 0; i < 21; i++) {
      await controller.send('question $i');
    }
    expect(controller.historyTurnCount, ChatController.maxHistoryTurns);

    await controller.send('latest');
    final contents = provider.requests.last.map((message) => message.content);
    expect(contents, isNot(contains('question 0')));
    expect(contents, contains('question 1'));
    expect(contents, contains('question 20'));
  });

  test('returns but does not retain an oversized successful turn', () async {
    final oversized = 'x' * (ChatController.maxHistoryContentBytes + 1);
    var reply = oversized;
    final provider = _Provider(() async => ChatTurn(text: reply));
    final controller = ChatController(provider: provider, onPaste: (_) {});

    final result = await controller.send('large answer');
    expect(result.reply, oversized);
    expect(controller.historyTurnCount, 0);

    reply = 'small answer';
    await controller.send('next');
    expect(provider.requests.last.map((message) => message.content), [
      kChatSystemPrompt,
      'next',
    ]);
  });

  test('does not retain a turn whose continuation fails', () async {
    var call = 0;
    final provider = _Provider(() async {
      call++;
      if (call == 1) {
        return const ChatTurn(
          text: '',
          toolCalls: [
            ToolCall(
              id: 'search',
              name: 'web_search',
              arguments: {'query': 'first query'},
            ),
          ],
        );
      }
      if (call == 2) throw StateError('provider failed');
      return const ChatTurn(text: 'recovered');
    });
    final controller = ChatController(provider: provider, onPaste: (_) {});

    await expectLater(controller.send('failed question'), throwsStateError);
    expect(controller.historyTurnCount, 0);
    await controller.send('fresh question');
    final contents = provider.requests.last.map((message) => message.content);
    expect(contents, [kChatSystemPrompt, 'fresh question']);
  });

  test('rejects parallel turns but reset can start a new generation', () async {
    final old = Completer<ChatTurn>();
    final provider = _Provider(() => old.future);
    final controller = ChatController(provider: provider, onPaste: (_) {});

    final first = controller.send('old');
    await expectLater(controller.send('parallel'), throwsStateError);
    controller.reset();
    provider.answer = () async => const ChatTurn(text: 'new');
    await controller.send('after reset');
    old.complete(const ChatTurn(text: 'late'));
    await expectLater(first, throwsStateError);
    await controller.send('still available');
    expect(controller.historyTurnCount, 2);
  });
}
