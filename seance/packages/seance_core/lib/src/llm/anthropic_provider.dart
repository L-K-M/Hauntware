import 'dart:convert';

import 'package:http/http.dart' as http;

import 'bounded_http.dart';
import 'provider.dart';
import 'sse.dart';

/// LLM provider speaking the Anthropic Messages API.
class AnthropicProvider implements LlmProvider, ClosableLlmProvider {
  @override
  final String model;
  final String baseUrl;
  final String apiKey;
  final int maxTokens;
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

  AnthropicProvider({
    required this.apiKey,
    this.model = 'claude-haiku-4-5-20251001',
    this.baseUrl = 'https://api.anthropic.com',
    this.maxTokens = 1024,
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

  Uri get _endpoint => Uri.parse('$baseUrl/v1/messages');

  Map<String, String> get _headers => {
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': '2023-06-01',
      };

  /// Split out for testing: build the request body for a set of messages.
  Map<String, dynamic> buildBody({
    required List<LlmMessage> messages,
    List<ToolSpec> tools = const [],
    bool stream = false,
  }) {
    final system = messages
        .where((m) => m.role == LlmRole.system)
        .map((m) => m.content)
        .join('\n\n');
    final turns = messages
        .where((m) => m.role != LlmRole.system)
        .map((m) => {
              'role': m.role == LlmRole.assistant ? 'assistant' : 'user',
              'content': m.content,
            })
        .toList();
    return {
      'model': model,
      'max_tokens': maxTokens,
      if (system.isNotEmpty) 'system': system,
      'messages': turns,
      if (tools.isNotEmpty)
        'tools': tools
            .map((t) => {
                  'name': t.name,
                  'description': t.description,
                  'input_schema': t.inputSchema,
                })
            .toList(),
      if (stream) 'stream': true,
    };
  }

  /// Split out for testing: parse a Messages API response body.
  ChatTurn parseResponse(Map<String, dynamic> json) {
    final content = (json['content'] as List?) ?? const [];
    final textBuf = StringBuffer();
    final calls = <ToolCall>[];
    for (final block in content.cast<Map<String, dynamic>>()) {
      switch (block['type']) {
        case 'text':
          textBuf.write(block['text'] as String? ?? '');
        case 'tool_use':
          calls.add(ToolCall(
            id: block['id'] as String? ?? '',
            name: block['name'] as String? ?? '',
            arguments:
                ((block['input'] as Map?)?.cast<String, dynamic>()) ?? {},
          ));
      }
    }
    return ChatTurn(text: textBuf.toString(), toolCalls: calls);
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
    final response = await _sendJson(request, 'Anthropic API');
    _ensureOpen();
    return parseResponse(response);
  }

  @override
  Future<List<String>> listModels() async {
    _ensureOpen();
    final request = http.Request('GET', Uri.parse('$baseUrl/v1/models'))
      ..headers.addAll(_headers);
    final json = await _sendJson(request, 'Anthropic models API');
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
      operation: 'Anthropic stream',
    );
    await requireSuccessfulResponse(
      started.response,
      operation: 'Anthropic stream',
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
      operation: 'Anthropic stream',
      abort: started.abort,
    )) {
      _ensureOpen();
      if (event['type'] == 'content_block_delta') {
        final delta = event['delta'] as Map<String, dynamic>?;
        final text = delta?['text'] as String?;
        if (text != null) yield text;
      }
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
    if (_closed) throw StateError('Anthropic provider is closed.');
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
