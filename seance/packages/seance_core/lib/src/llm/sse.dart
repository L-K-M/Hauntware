import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'bounded_http.dart';

/// Parse bounded Server-Sent Events into their JSON `data` objects.
///
/// Lines and events are assembled incrementally across arbitrary network
/// chunks. Non-JSON events, comments and the OpenAI `[DONE]` marker are
/// ignored. Every buffer has its own bound in addition to the response-wide
/// byte and time limits.
Stream<Map<String, dynamic>> parseSseJson(
  Stream<List<int>> bytes, {
  int maxBytes = maxAssistantResponseBytes,
  int maxLineBytes = maxAssistantSseLineBytes,
  int maxEventBytes = maxAssistantSseEventBytes,
  int maxEvents = maxAssistantSseEvents,
  Duration idleTimeout = const Duration(seconds: 30),
  Duration totalTimeout = const Duration(minutes: 2),
  String operation = 'Assistant stream',
  void Function()? abort,
}) async* {
  if (maxLineBytes <= 0) {
    throw ArgumentError.value(maxLineBytes, 'maxLineBytes', 'must be positive');
  }
  if (maxEventBytes <= 0) {
    throw ArgumentError.value(
      maxEventBytes,
      'maxEventBytes',
      'must be positive',
    );
  }
  if (maxEvents <= 0) {
    throw ArgumentError.value(maxEvents, 'maxEvents', 'must be positive');
  }

  final decoder = _SseJsonDecoder(
    maxEventBytes: maxEventBytes,
    maxEvents: maxEvents,
    operation: operation,
  );
  final line = BytesBuilder(copy: false);
  var afterCarriageReturn = false;
  await for (final chunk in boundedHttpBytes(
    bytes,
    maxBytes: maxBytes,
    idleTimeout: idleTimeout,
    totalTimeout: totalTimeout,
    operation: operation,
    abort: abort,
  )) {
    for (final byte in chunk) {
      if (afterCarriageReturn) {
        afterCarriageReturn = false;
        if (byte == 0x0A) continue;
      }
      if (byte == 0x0D || byte == 0x0A) {
        final event = decoder.addLine(line.takeBytes());
        if (event != null) yield event;
        afterCarriageReturn = byte == 0x0D;
        continue;
      }
      if (line.length >= maxLineBytes) {
        throw http.ClientException('$operation contained an oversized line.');
      }
      line.addByte(byte);
    }
  }
  if (line.isNotEmpty) {
    final event = decoder.addLine(line.takeBytes());
    if (event != null) yield event;
  }
  final finalEvent = decoder.finish();
  if (finalEvent != null) yield finalEvent;
}

class _SseJsonDecoder {
  final int maxEventBytes;
  final int maxEvents;
  final String operation;
  final List<String> _data = [];
  int _eventBytes = 0;
  int _events = 0;

  _SseJsonDecoder({
    required this.maxEventBytes,
    required this.maxEvents,
    required this.operation,
  });

  Map<String, dynamic>? addLine(Uint8List rawLine) {
    final length = rawLine.length;
    if (length == 0) return finish();
    final line = utf8.decode(
      Uint8List.sublistView(rawLine, 0, length),
      allowMalformed: true,
    );
    if (line.startsWith(':') || !line.startsWith('data:')) return null;
    var payload = line.substring(5);
    var payloadBytes = length - 5;
    if (payload.startsWith(' ')) {
      payload = payload.substring(1);
      payloadBytes--;
    }
    _eventBytes += payloadBytes + (_data.isEmpty ? 0 : 1);
    if (_eventBytes > maxEventBytes) {
      throw http.ClientException('$operation contained an oversized event.');
    }
    _data.add(payload);
    return null;
  }

  Map<String, dynamic>? finish() {
    if (_data.isEmpty) return null;
    _events++;
    if (_events > maxEvents) {
      throw http.ClientException('$operation sent too many events.');
    }
    final payload = _data.join('\n');
    _data.clear();
    _eventBytes = 0;
    if (payload.isEmpty || payload == '[DONE]') return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      return null;
    }
    return decoded is Map<String, dynamic> ? decoded : null;
  }
}
