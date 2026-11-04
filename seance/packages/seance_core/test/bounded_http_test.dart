import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:seance_core/src/llm/bounded_http.dart';
import 'package:seance_core/src/llm/search.dart';
import 'package:seance_core/src/llm/sse.dart';
import 'package:seance_core/src/llm/zai_search.dart';
import 'package:test/test.dart';

void main() {
  group('bounded HTTP bodies', () {
    test('normal JSON survives arbitrary chunk boundaries', () async {
      final json = await readBoundedJsonObject(
        Stream.fromIterable([
          utf8.encode('{"answer"'),
          utf8.encode(':"yes"}'),
        ]),
        maxBytes: 100,
        idleTimeout: const Duration(seconds: 1),
        totalTimeout: const Duration(seconds: 1),
        operation: 'Test response',
      );
      expect(json, {'answer': 'yes'});
    });

    test('an idle body fails and cancels its subscription', () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      addTearDown(stream.close);

      await expectLater(
        boundedHttpBytes(
          stream.stream,
          maxBytes: 100,
          idleTimeout: const Duration(milliseconds: 10),
          totalTimeout: const Duration(seconds: 1),
          operation: 'Idle response',
        ).drain<void>(),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            contains('stopped sending'),
          ),
        ),
      );
      expect(cancelled, isTrue);
    });

    test('a trickling body still reaches its total deadline', () async {
      final stream = Stream<List<int>>.periodic(
        const Duration(milliseconds: 2),
        (_) => const [0],
      );
      await expectLater(
        boundedHttpBytes(
          stream,
          maxBytes: 100000,
          idleTimeout: const Duration(milliseconds: 50),
          totalTimeout: const Duration(milliseconds: 20),
          operation: 'Trickling response',
        ).drain<void>(),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            contains('total deadline'),
          ),
        ),
      );
    });

    test('a body total deadline aborts the underlying request', () async {
      final aborted = Completer<void>();
      final body = StreamController<List<int>>();
      addTearDown(body.close);
      final client = _StreamClient((request) async {
        final abortable = request as http.AbortableRequest;
        unawaited(abortable.abortTrigger!.then((_) => aborted.complete()));
        return http.StreamedResponse(body.stream, 200);
      });
      addTearDown(client.close);
      final started = await sendWithResponseDeadlines(
        client,
        http.Request('GET', Uri.parse('https://example.invalid')),
        headerTimeout: const Duration(seconds: 1),
        totalTimeout: const Duration(milliseconds: 20),
        operation: 'Total response',
      );

      await expectLater(
        readBoundedJsonObject(
          started.response.stream,
          maxBytes: 100,
          idleTimeout: const Duration(seconds: 1),
          totalTimeout: started.remaining,
          operation: 'Total response',
          abort: started.abort,
        ),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            contains('total deadline'),
          ),
        ),
      );
      await aborted.future;
    });

    test('response headers have their own deadline', () async {
      final aborted = Completer<void>();
      final pending = Completer<http.StreamedResponse>();
      final client = _StreamClient((request) {
        final abortable = request as http.AbortableRequest;
        abortable.abortTrigger!.then((_) {
          aborted.complete();
          pending.completeError(http.RequestAbortedException(request.url));
        });
        return pending.future;
      });
      addTearDown(client.close);
      await expectLater(
        sendWithResponseDeadlines(
          client,
          http.Request('GET', Uri.parse('https://example.invalid')),
          headerTimeout: const Duration(milliseconds: 10),
          totalTimeout: const Duration(seconds: 1),
          operation: 'Header response',
        ),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            contains('headers'),
          ),
        ),
      );
      await aborted.future;
    });
  });

  group('bounded SSE', () {
    test('parses multi-line events split one byte at a time', () async {
      final raw = utf8.encode(
        'data: {"text":\n'
        'data: "hello"}\n\n'
        ': keepalive\n\n'
        'data: [DONE]\n\n',
      );
      final events = await parseSseJson(
        Stream.fromIterable([
          for (final byte in raw) [byte],
        ]),
        maxBytes: 1000,
        maxLineBytes: 100,
        maxEventBytes: 100,
        maxEvents: 10,
        idleTimeout: const Duration(seconds: 1),
        totalTimeout: const Duration(seconds: 1),
      ).toList();
      expect(events, [
        {'text': 'hello'},
      ]);
    });

    test('accepts bare CR and a CRLF split across chunks', () async {
      final events = await parseSseJson(
        Stream.fromIterable([
          utf8.encode('data: {"n":1}\r\rdata: {"n":2}\r'),
          utf8.encode('\n\r\n'),
        ]),
        maxBytes: 100,
        maxLineBytes: 100,
        maxEventBytes: 100,
        maxEvents: 10,
        idleTimeout: const Duration(seconds: 1),
        totalTimeout: const Duration(seconds: 1),
      ).toList();
      expect(events, [
        {'n': 1},
        {'n': 2},
      ]);
    });

    test('rejects an oversized line split across chunks', () async {
      await expectLater(
        parseSseJson(
          Stream.fromIterable([
            utf8.encode('data: 123'),
            utf8.encode('456789\n\n'),
          ]),
          maxBytes: 100,
          maxLineBytes: 12,
          maxEventBytes: 100,
          maxEvents: 10,
          idleTimeout: const Duration(seconds: 1),
          totalTimeout: const Duration(seconds: 1),
        ).drain<void>(),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            contains('oversized line'),
          ),
        ),
      );
    });

    test('rejects a multi-line event over its own cap', () async {
      await expectLater(
        parseSseJson(
          Stream.value(utf8.encode('data: 12345\ndata: 67890\n\n')),
          maxBytes: 100,
          maxLineBytes: 100,
          maxEventBytes: 8,
          maxEvents: 10,
          idleTimeout: const Duration(seconds: 1),
          totalTimeout: const Duration(seconds: 1),
        ).drain<void>(),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            contains('oversized event'),
          ),
        ),
      );
    });

    test('rejects an endless sequence of small events', () async {
      await expectLater(
        parseSseJson(
          Stream.value(utf8.encode(
            'data: {"n":1}\n\n'
            'data: {"n":2}\n\n'
            'data: {"n":3}\n\n',
          )),
          maxBytes: 1000,
          maxLineBytes: 100,
          maxEventBytes: 100,
          maxEvents: 2,
          idleTimeout: const Duration(seconds: 1),
          totalTimeout: const Duration(seconds: 1),
        ).drain<void>(),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            contains('too many events'),
          ),
        ),
      );
    });
  });

  group('search response bounds and ownership', () {
    test('SearXNG reads a normally chunked bounded response', () async {
      final client = _StreamClient((_) async => http.StreamedResponse(
            Stream.fromIterable([
              utf8.encode('{"results":['),
              utf8.encode(
                '{"title":"Dart","url":"https://dart.dev",'
                '"content":"Docs"}]}',
              ),
            ]),
            200,
          ));
      final provider = SearxngSearch(
        baseUrl: 'https://search.example',
        client: client,
      );
      final results = await provider.search('dart');
      expect(results.single.title, 'Dart');
    });

    test('SearXNG enforces the configured response cap', () async {
      final client = _StreamClient((_) async => http.StreamedResponse(
            Stream.value(utf8.encode('{"results":[]}')),
            200,
          ));
      final provider = SearxngSearch(
        baseUrl: 'https://search.example',
        client: client,
        maxResponseBytes: 5,
      );
      await expectLater(provider.search('dart'), throwsA(isA<http.ClientException>()));
    });

    test('search error bodies are never echoed', () async {
      const secret = 'server-echoed-secret';
      final client = _StreamClient((_) async => http.StreamedResponse(
            Stream.value(utf8.encode(secret)),
            500,
          ));
      final provider = BraveSearch(apiKey: 'k', client: client);
      await expectLater(
        provider.search('dart'),
        throwsA(
          isA<http.ClientException>().having(
            (error) => error.message,
            'message',
            isNot(contains(secret)),
          ),
        ),
      );
    });

    test('borrowed clients stay open and owned clients close once', () {
      final borrowed = _StreamClient((_) async =>
          http.StreamedResponse(const Stream.empty(), 200));
      SearxngSearch(
        baseUrl: 'https://search.example',
        client: borrowed,
      ).close();
      expect(borrowed.closeCalls, 0);

      final owned = _StreamClient((_) async =>
          http.StreamedResponse(const Stream.empty(), 200));
      final provider = BraveSearch(
        apiKey: 'k',
        clientFactory: () => owned,
      );
      provider.close();
      provider.close();
      expect(owned.closeCalls, 1);
    });

    test('Z.AI gains lifecycle ownership without changing its transport', () async {
      final client = _StreamClient((_) async =>
          http.StreamedResponse(const Stream.empty(), 200));
      final provider = ZaiSearch(
        apiKey: 'k',
        clientFactory: () => client,
      );
      provider.close();
      provider.close();
      expect(client.closeCalls, 1);
      await expectLater(provider.search('dart'), throwsStateError);
      expect(client.sends, 0);
    });

    test('CompositeSearch closes each child exactly once', () {
      final first = _ClosableSearch();
      final second = _ClosableSearch();
      final provider = CompositeSearch([first, second]);
      provider.close();
      provider.close();
      expect(first.closeCalls, 1);
      expect(second.closeCalls, 1);
    });

    test('CompositeSearch keeps its const constructor', () {
      const provider = CompositeSearch([]);
      expect(provider.providers, isEmpty);
    });
  });
}

class _StreamClient extends http.BaseClient {
  final Future<http.StreamedResponse> Function(http.BaseRequest) handler;
  int sends = 0;
  int closeCalls = 0;

  _StreamClient(this.handler);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sends++;
    return handler(request);
  }

  @override
  void close() => closeCalls++;
}

class _ClosableSearch implements SearchProvider, ClosableSearchProvider {
  int closeCalls = 0;

  @override
  void close() => closeCalls++;

  @override
  Future<List<SearchResult>> search(String query, {int limit = 5}) async =>
      const [];
}
