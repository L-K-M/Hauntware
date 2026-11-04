import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bounded_http.dart';
import 'provider.dart';
import 'sse.dart';

/// LLM provider speaking the OpenAI Chat Completions API. A configurable
/// [baseUrl] covers Ollama, LM Studio, vLLM, OpenRouter, and Groq — anything
/// exposing `/chat/completions`. For keyless local endpoints, leave [apiKey]
/// empty and no Authorization header is sent.
class OpenAiCompatibleProvider implements LlmProvider, ClosableLlmProvider {
  @override
  final String model;
  final String baseUrl;
  final String apiKey;
  final Duration timeout;
  final Duration headerTimeout;
  final Duration idleTimeout;
  final Duration totalTimeout;
  final int maxResponseBytes;
  final int maxSseLineBytes;
  final int maxSseEventBytes;
  final int maxSseEvents;
  final http.Client _client;
  final bool _ownsClient;
  bool _closed = false;

  OpenAiCompatibleProvider({
    required this.baseUrl,
    this.apiKey = '',
    this.model = 'gpt-5.4-mini',
    Duration timeout = const Duration(seconds: 120),
    Duration? headerTimeout,
    Duration? idleTimeout,
    Duration? totalTimeout,
    this.maxResponseBytes = maxAssistantResponseBytes,
    this.maxSseLineBytes = maxAssistantSseLineBytes,
    this.maxSseEventBytes = maxAssistantSseEventBytes,
    this.maxSseEvents = maxAssistantSseEvents,
    http.Client? client,
    http.Client Function()? clientFactory,
  }) : timeout = timeout,
       headerTimeout = headerTimeout ?? timeout,
       idleTimeout = idleTimeout ?? const Duration(seconds: 30),
       totalTimeout = totalTimeout ?? timeout,
       _client = _providerClient(client, clientFactory),
       _ownsClient = client == null;

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  Uri get _endpoint => Uri.parse('$baseUrl/chat/completions');

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
      };

  Map<String, dynamic> buildBody({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
    bool stream = false,
  }) {
    return {
      'model': model,
      'messages': messages
          .map((m) => {'role': m.role.name, 'content': m.content})
          .toList(),
      if (tools.isNotEmpty)
        'tools': tools
            .map((t) => {
                  'type': 'function',
                  'function': {
                    'name': t.name,
                    'description': t.description,
                    'parameters': t.inputSchema,
                  },
                })
            .toList(),
      if (stream) 'stream': true,
    };
  }

  ChatTurn parseResponse(Map<String, dynamic> json) {
    final choices = (json['choices'] as List?) ?? const [];
    if (choices.isEmpty) return const ChatTurn(text: '');
    final message =
        (choices.first as Map<String, dynamic>)['message'] as Map<String, dynamic>;
    final text = message['content'] as String? ?? '';
    final calls = <ToolCall>[];
    for (final tc in (message['tool_calls'] as List?) ?? const []) {
      final m = tc as Map<String, dynamic>;
      final fn = m['function'] as Map<String, dynamic>;
      final rawArgs = fn['arguments'];
      Map<String, dynamic> args;
      if (rawArgs is String) {
        args = rawArgs.isEmpty
            ? {}
            : (jsonDecode(rawArgs) as Map).cast<String, dynamic>();
      } else if (rawArgs is Map) {
        args = rawArgs.cast<String, dynamic>();
      } else {
        args = {};
      }
      calls.add(ToolCall(
        id: m['id'] as String? ?? '',
        name: fn['name'] as String? ?? '',
        arguments: args,
      ));
    }
    return ChatTurn(text: text, toolCalls: calls);
  }

  @override
  Future<ChatTurn> chat({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
  }) async {
    _ensureOpen();
    final request = http.Request('POST', _endpoint)
      ..headers.addAll(_headers)
      ..body = jsonEncode(buildBody(messages: messages, tools: tools));
    final response = await _sendJson(request, 'OpenAI-compatible API');
    _ensureOpen();
    return parseResponse(response);
  }

  @override
  Future<List<String>> listModels() async {
    _ensureOpen();
    final request = http.Request('GET', Uri.parse('$baseUrl/models'))
      ..headers.addAll(_headers);
    final json = await _sendJson(request, 'OpenAI-compatible models API');
    _ensureOpen();
    final data = (json['data'] as List?) ?? const [];
    return data
        .map((m) => (m as Map<String, dynamic>)['id'] as String?)
        .whereType<String>()
        .toList();
  }

  @override
  Future<CommandSuggestion> generateCommand({
    required String prompt,
    HostContext context = HostContext.unknown,
  }) async {
    final turn = await chat(messages: [
      const LlmMessage.system(kCommandSystemPrompt),
      LlmMessage.user('${context.toPromptBlock()}\nRequest: $prompt'),
    ]);
    return parseCommandJson(turn.text);
  }

  @override
  Stream<String> streamChat({required List<LlmMessage> messages}) async* {
    _ensureOpen();
    final req = http.Request('POST', _endpoint)
      ..headers.addAll(_headers)
      ..body = jsonEncode(buildBody(messages: messages, stream: true));
    final started = await sendWithResponseDeadlines(
      _client,
      req,
      headerTimeout: headerTimeout,
      totalTimeout: totalTimeout,
      operation: 'OpenAI-compatible stream',
    );
    await requireSuccessfulResponse(
      started.response,
      operation: 'OpenAI-compatible stream',
      abort: started.abort,
    );
    await for (final event in parseSseJson(
      started.response.stream,
      maxBytes: maxResponseBytes,
      maxLineBytes: maxSseLineBytes,
      maxEventBytes: maxSseEventBytes,
      maxEvents: maxSseEvents,
      idleTimeout: idleTimeout,
      totalTimeout: started.remaining,
      operation: 'OpenAI-compatible stream',
      abort: started.abort,
    )) {
      _ensureOpen();
      final choices = event['choices'] as List?;
      if (choices == null || choices.isEmpty) continue;
      final delta =
          (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
      final text = delta?['content'] as String?;
      if (text != null && text.isNotEmpty) yield text;
    }
  }

  Future<Map<String, dynamic>> _sendJson(
    http.Request request,
    String operation,
  ) async {
    final started = await sendWithResponseDeadlines(
      _client,
      request,
      headerTimeout: headerTimeout,
      totalTimeout: totalTimeout,
      operation: operation,
    );
    await requireSuccessfulResponse(
      started.response,
      operation: operation,
      abort: started.abort,
    );
    return readBoundedJsonObject(
      started.response.stream,
      maxBytes: maxResponseBytes,
      idleTimeout: idleTimeout,
      totalTimeout: started.remaining,
      operation: operation,
      abort: started.abort,
    );
  }

  void _ensureOpen() {
    if (_closed) throw StateError('OpenAI-compatible provider is closed.');
  }
}

http.Client _providerClient(
  http.Client? client,
  http.Client Function()? clientFactory,
) {
  if (client != null && clientFactory != null) {
    throw ArgumentError('client and clientFactory cannot both be supplied.');
  }
  return client ?? clientFactory?.call() ?? http.Client();
}
