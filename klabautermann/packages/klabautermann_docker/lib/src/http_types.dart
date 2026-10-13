import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Cancellation handle for a request (03 §5.5: cancellation closes the
/// duplex). Cancelling during connect, write or header parse aborts the
/// in-flight exchange; cancelling a delivered body stream is done by
/// cancelling the stream subscription itself.
final class DockerCancelToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final l in listeners) {
      l();
    }
  }

  /// Registers [listener] to run once on cancel; runs it immediately when
  /// already cancelled.
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
      return;
    }
    _listeners.add(listener);
  }
}

/// Case-insensitive HTTP header map. Header names are compared
/// case-insensitively; repeated fields collect into one list.
final class HttpHeaders {
  HttpHeaders._(this._values);

  /// Builds headers from (name, value) pairs, merging repeats.
  factory HttpHeaders(Iterable<(String, String)> entries) {
    final map = CanonicalizedMap<String, String, List<String>>(
      (key) => key.toLowerCase(),
    );
    for (final (name, value) in entries) {
      map.putIfAbsent(name, () => <String>[]).add(value);
    }
    return HttpHeaders._(map);
  }

  final CanonicalizedMap<String, String, List<String>> _values;

  /// All values for [name], or null when absent.
  List<String>? operator [](String name) => _values[name];

  /// The first value for [name], or null when absent.
  String? value(String name) {
    final v = _values[name];
    return (v == null || v.isEmpty) ? null : v.first;
  }

  /// Whether [name] is present.
  bool contains(String name) => _values.containsKey(name);

  /// Every distinct header name (as sent) with its values.
  Iterable<MapEntry<String, List<String>>> get entries => _values.entries;

  /// Splits a comma-separated header value into lowercase tokens.
  Set<String> tokens(String name) => {
    for (final v in _values[name] ?? const <String>[])
      for (final t in v.split(','))
        if (t.trim().isNotEmpty) t.trim().toLowerCase(),
  };
}

/// An HTTP request the client can carry (03 §5.5). The caller builds the
/// path (versioned by [DockerClient] when needed); query parameters are
/// percent-encoded by the client.
@immutable
final class DockerHttpRequest {
  const DockerHttpRequest({
    required this.method,
    required this.path,
    this.query,
    this.headers,
    this.json,
    this.body,
    this.contentType,
    this.upgrade = false,
    this.timeout,
    this.cancelToken,
  }) : assert(json == null || body == null, 'json and body are exclusive');

  /// `GET`, `POST`, `DELETE`, `HEAD`, ... Sent verbatim.
  final String method;

  /// The request path, for example `/v1.44/containers/json` or `/_ping`.
  /// Must start with `/` and carry no query string.
  final String path;

  /// Query parameters; keys and values are percent-encoded.
  final Map<String, String>? query;

  /// Extra headers. The client owns `Host`, `Content-Length`,
  /// `Connection` and `Upgrade`; entries naming those are ignored.
  final Map<String, String>? headers;

  /// A value encoded as a JSON request body (`Content-Type:
  /// application/json`).
  final Object? json;

  /// A raw request body; mutually exclusive with [json].
  final List<int>? body;

  /// `Content-Type` for [body] (ignored for [json]).
  final String? contentType;

  /// Sends `Connection: Upgrade` and `Upgrade: tcp` (03 §5.5, §5.7).
  final bool upgrade;

  /// Per-request timeout (03 §5.5). Covers connect, the write and the
  /// response head; for buffered modes also the whole body. Null falls
  /// back to the client's default.
  final Duration? timeout;

  /// Cancels the request; the underlying duplex is closed.
  final DockerCancelToken? cancelToken;
}

/// A parsed response head plus its body. `T` is `Uint8List` for buffered
/// mode, `Stream<List<int>>` for bytes, `Stream<String>` for lines,
/// `Stream<Object?>` for JSON values and the hijacked duplex handle for
/// hijack (03 §5.5).
@immutable
final class DockerResponse<T> {
  const DockerResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.body,
  });

  final int statusCode;
  final String reasonPhrase;
  final HttpHeaders headers;
  final T body;
}
