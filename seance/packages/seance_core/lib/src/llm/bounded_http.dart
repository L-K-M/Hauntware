import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Generous ceiling for one assistant or search response.
///
/// Normal replies are measured in kilobytes. A larger response is usually a
/// proxy error page or a broken endpoint and must not be buffered indefinitely.
const int maxAssistantResponseBytes = 2 * 1024 * 1024;

/// Maximum bytes in one Server-Sent Events line.
const int maxAssistantSseLineBytes = 256 * 1024;

/// Maximum combined `data:` bytes in one Server-Sent Events event.
const int maxAssistantSseEventBytes = 512 * 1024;

/// Maximum events accepted from one streamed assistant response.
const int maxAssistantSseEvents = 50000;

/// A response whose headers arrived, plus the part of its total deadline left
/// for reading the body.
class StartedHttpResponse {
  final http.StreamedResponse response;
  final Duration remaining;
  final void Function() abort;

  const StartedHttpResponse(this.response, this.remaining, this.abort);
}

/// Send [request] with separate response-header and total deadlines.
///
Future<StartedHttpResponse> sendWithResponseDeadlines(
  http.Client client,
  http.Request request, {
  required Duration headerTimeout,
  required Duration totalTimeout,
  required String operation,
}) async {
  _requirePositiveDuration(headerTimeout, 'headerTimeout');
  _requirePositiveDuration(totalTimeout, 'totalTimeout');
  final clock = Stopwatch()..start();
  final wait = headerTimeout.compareTo(totalTimeout) <= 0
      ? headerTimeout
      : totalTimeout;
  final abortCompleter = Completer<void>();
  void abort() {
    if (!abortCompleter.isCompleted) abortCompleter.complete();
  }

  final abortable = http.AbortableRequest(
    request.method,
    request.url,
    abortTrigger: abortCompleter.future,
  )
    ..followRedirects = request.followRedirects
    ..maxRedirects = request.maxRedirects
    ..persistentConnection = request.persistentConnection
    ..headers.addAll(request.headers)
    ..bodyBytes = request.bodyBytes;
  final sent = client.send(abortable);
  final http.StreamedResponse response;
  try {
    response = await sent.timeout(wait);
  } on TimeoutException {
    abort();
    unawaited(
      sent.then<void>(
        cancelHttpResponse,
        onError: (Object _, StackTrace __) {},
      ),
    );
    throw http.ClientException(
      wait == totalTimeout
          ? '$operation exceeded its total deadline.'
          : '$operation did not return response headers in time.',
      request.url,
    );
  }
  final remaining = totalTimeout - clock.elapsed;
  if (remaining <= Duration.zero) {
    abort();
    await cancelHttpResponse(response);
    throw http.ClientException(
      '$operation exceeded its total deadline.',
      request.url,
    );
  }
  return StartedHttpResponse(response, remaining, abort);
}

/// Cancel a response without reading or exposing its body.
Future<void> cancelHttpResponse(http.StreamedResponse response) async {
  try {
    await response.stream.listen(null).cancel();
  } catch (_) {
    // The response is already being abandoned. A cancellation failure must
    // not replace the bounded/status error which explains why.
  }
}

/// Reject an HTTP error without copying its untrusted body into an exception.
Future<void> requireSuccessfulResponse(
  http.StreamedResponse response, {
  required String operation,
  void Function()? abort,
}) async {
  if (response.statusCode < 400) return;
  abort?.call();
  await cancelHttpResponse(response);
  throw http.ClientException('$operation failed: HTTP ${response.statusCode}.');
}

/// Bound a byte stream by size, inactivity and total elapsed time.
///
/// The owned subscription is cancelled on every failure and when the consumer
/// stops listening. This matters for a response which has already supplied
/// headers but then stalls or trickles forever.
Stream<List<int>> boundedHttpBytes(
  Stream<List<int>> bytes, {
  required int maxBytes,
  required Duration idleTimeout,
  required Duration totalTimeout,
  required String operation,
  void Function()? abort,
}) async* {
  if (maxBytes <= 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
  }
  _requirePositiveDuration(idleTimeout, 'idleTimeout');
  _requirePositiveDuration(totalTimeout, 'totalTimeout');

  final clock = Stopwatch()..start();
  final iterator = StreamIterator<List<int>>(bytes);
  var read = 0;
  var completed = false;
  try {
    while (true) {
      final remaining = totalTimeout - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw http.ClientException('$operation exceeded its total deadline.');
      }
      final totalComesFirst = remaining.compareTo(idleTimeout) <= 0;
      final wait = totalComesFirst ? remaining : idleTimeout;
      final bool hasChunk;
      try {
        hasChunk = await iterator.moveNext().timeout(wait);
      } on TimeoutException {
        throw http.ClientException(
          totalComesFirst
              ? '$operation exceeded its total deadline.'
              : '$operation stopped sending data.',
        );
      }
      if (!hasChunk) {
        completed = true;
        return;
      }
      if (clock.elapsed >= totalTimeout) {
        throw http.ClientException('$operation exceeded its total deadline.');
      }
      final chunk = iterator.current;
      read += chunk.length;
      if (read > maxBytes) {
        throw http.ClientException('$operation was too large.');
      }
      yield chunk;
    }
  } finally {
    if (!completed) abort?.call();
    try {
      await iterator.cancel();
    } catch (_) {
      // Preserve the size/deadline failure which triggered cancellation.
    }
  }
}

/// Read and decode one bounded JSON object.
Future<Map<String, dynamic>> readBoundedJsonObject(
  Stream<List<int>> bytes, {
  required int maxBytes,
  required Duration idleTimeout,
  required Duration totalTimeout,
  required String operation,
  void Function()? abort,
}) async {
  final buffer = BytesBuilder(copy: false);
  await for (final chunk in boundedHttpBytes(
    bytes,
    maxBytes: maxBytes,
    idleTimeout: idleTimeout,
    totalTimeout: totalTimeout,
    operation: operation,
    abort: abort,
  )) {
    buffer.add(chunk);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(buffer.takeBytes()));
  } on FormatException {
    throw http.ClientException('$operation returned invalid JSON.');
  }
  if (decoded is! Map<String, dynamic>) {
    throw http.ClientException('$operation returned invalid JSON.');
  }
  return decoded;
}

void _requirePositiveDuration(Duration value, String name) {
  if (value <= Duration.zero) {
    throw ArgumentError.value(value, name, 'must be positive');
  }
}
