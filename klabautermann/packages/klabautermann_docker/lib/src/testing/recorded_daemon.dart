import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../api_version.dart';
import '../duplex.dart';
import '../../testing.dart' show FakeDuplexPair;

/// One recorded exchange of an `api-*` corpus (03 §11.1, D21): the
/// request as the capture tool sent it and the raw response bytes,
/// status line, headers and chunked framing included.
final class RecordedExchange {
  RecordedExchange._({
    required this.name,
    required this.method,
    required this.path,
    required this.query,
    required this.status,
    required this.bytes,
  });

  /// The exchange name, which is also its file name without `.http`.
  final String name;
  final String method;

  /// The request path as recorded, with its version prefix when it has
  /// one (`/v1.44/info`).
  final String path;

  /// The request query, decoded.
  final Map<String, String> query;

  /// The recorded response status.
  final int status;

  /// The response bytes exactly as the daemon sent them.
  final Uint8List bytes;

  /// The API version in [path], or null for `/_ping` and `/version`.
  ApiVersion? get pathVersion => _splitVersion(path).$1;

  /// The response headers, names lower-cased.
  Map<String, String> get headers => _parseHead(bytes).$1;

  /// The response body after the head, still in its wire framing.
  Uint8List get rawBody => Uint8List.sublistView(bytes, _parseHead(bytes).$2);

  /// True when the recording stops before the response ended: a chunked
  /// body without its terminating chunk (`stats-stream`).
  bool get truncated {
    if (headers['transfer-encoding']?.toLowerCase() != 'chunked') {
      return false;
    }
    const end = [0x30, 0x0d, 0x0a, 0x0d, 0x0a]; // "0\r\n\r\n"
    if (bytes.length < end.length) return true;
    for (var i = 0; i < end.length; i++) {
      if (bytes[bytes.length - end.length + i] != end[i]) return true;
    }
    return false;
  }

  /// True when the daemon ended the connection after this response.
  bool get closesConnection {
    final h = headers;
    if (h['connection']?.toLowerCase() == 'close') return true;
    // A body with neither length nor chunked framing ends at EOF; HEAD,
    // 1xx, 204 and 304 responses have no body at all.
    if (method == 'HEAD' ||
        (status >= 100 && status < 200) ||
        status == 204 ||
        status == 304) {
      return false;
    }
    return !h.containsKey('content-length') &&
        h['transfer-encoding']?.toLowerCase() != 'chunked';
  }
}

/// A recorded Docker API corpus, one `api-*` directory (03 §11.1, D21),
/// read through [readFile] so this library stays free of `dart:io`.
final class RecordedCorpus {
  RecordedCorpus._(this.name, this.manifest, this.exchanges);

  /// Parses `MANIFEST.json` and reads each exchange's `.http` file with
  /// [readFile], which takes a file name relative to the corpus
  /// directory.
  factory RecordedCorpus.parse(
    String manifestJson,
    List<int> Function(String fileName) readFile,
  ) {
    final manifest = jsonDecode(manifestJson) as Map<String, Object?>;
    final exchanges = <RecordedExchange>[];
    for (final raw in manifest['exchanges']! as List<Object?>) {
      final e = raw! as Map<String, Object?>;
      final request = e['request']! as String;
      final space = request.indexOf(' ');
      final target = Uri.parse(request.substring(space + 1));
      exchanges.add(
        RecordedExchange._(
          name: e['name']! as String,
          method: request.substring(0, space),
          path: Uri.decodeComponent(target.path),
          query: target.queryParameters,
          status: e['status']! as int,
          bytes: Uint8List.fromList(readFile(e['file']! as String)),
        ),
      );
    }
    return RecordedCorpus._(manifest['corpus']! as String, manifest, exchanges);
  }

  /// The directory name, for example `api-1.44`.
  final String name;

  /// The decoded `MANIFEST.json`: daemon facts, seeded ids, exchanges.
  final Map<String, Object?> manifest;

  /// Every exchange in recording order.
  final List<RecordedExchange> exchanges;

  Map<String, Object?> get _daemon =>
      manifest['daemon']! as Map<String, Object?>;

  /// The daemon's native maximum API version.
  ApiVersion get apiVersion =>
      ApiVersion.tryParse(_daemon['apiVersion']! as String)!;

  /// The daemon's `MinAPIVersion`.
  ApiVersion get minApiVersion =>
      ApiVersion.tryParse(_daemon['minApiVersion']! as String)!;

  /// True for Podman's compat service.
  bool get isPodman => _daemon['runtime'] == 'podman';

  /// The ids of the seeded containers, by name.
  Map<String, String> get seededContainers {
    final seeded = manifest['seeded']! as Map<String, Object?>;
    return (seeded['containers']! as Map<String, Object?>).cast();
  }

  /// The exchange called [name]; throws when the corpus has none.
  RecordedExchange operator [](String name) => exchanges.firstWhere(
    (e) => e.name == name,
    orElse: () => throw ArgumentError.value(name, 'name', 'no such exchange'),
  );

  /// The exchange recorded for [method] and [target] (path plus query),
  /// or null. An exact path matches first. Otherwise the path's version
  /// is ignored, as long as it lies in the daemon's range: a client that
  /// negotiated below the daemon's maximum gets the native recording.
  /// Query parameters match after [_normalizeQuery].
  RecordedExchange? match(String method, String target) {
    final uri = Uri.parse(target);
    final path = Uri.decodeComponent(uri.path);
    final query = _normalizeQuery(uri.queryParameters);
    bool sameQuery(RecordedExchange e) =>
        _mapEquals(_normalizeQuery(e.query), query);

    for (final e in exchanges) {
      if (e.method == method && e.path == path && sameQuery(e)) return e;
    }

    final (version, rest) = _splitVersion(path);
    if (version == null ||
        version < minApiVersion && !isPodman ||
        version > apiVersion && !isPodman) {
      return null;
    }
    for (final e in exchanges) {
      if (e.method != method || !sameQuery(e)) continue;
      final (ev, erest) = _splitVersion(e.path);
      // Only native-version recordings stand in for other versions; the
      // refusal exchanges answer their own path alone.
      if (ev == apiVersion && erest == rest) return e;
    }
    return null;
  }
}

/// How [RecordedDaemon] hands response bytes to the client.
enum RecordedChunking {
  /// The whole response as one inbound chunk.
  whole,

  /// One inbound chunk per byte, so every chunk boundary of the parser is
  /// exercised (03 §5.5).
  everyByte,
}

/// A scripted daemon that answers [DockerHttpClient] requests from a
/// [RecordedCorpus] (03 §11.1 fake-transport layer, D21). [opener] opens
/// in-memory connections; each one reads requests, serves the matching
/// recording and keeps the connection alive unless the recording closed
/// it. A truncated recording leaves the response open, as a live stream
/// would, until the client closes. A request with no recording gets a
/// 404 naming it and is listed in [unmatched].
final class RecordedDaemon {
  RecordedDaemon(this.corpus, {this.chunking = RecordedChunking.whole});

  final RecordedCorpus corpus;
  final RecordedChunking chunking;

  /// Every request line received, in order (`GET /v1.44/info`).
  final List<String> requests = <String>[];

  /// The requests that matched no recording.
  final List<String> unmatched = <String>[];

  /// Connections opened so far.
  int get connections => _connections;
  int _connections = 0;

  /// The opener to hand to [DockerHttpClient].
  DuplexOpener get opener => _open;

  Future<ByteDuplex> _open() async {
    _connections++;
    final pair = FakeDuplexPair();
    _Connection(this, pair.server);
    return pair.client;
  }

  void _serve(ByteDuplex server, RecordedExchange e) {
    switch (chunking) {
      case RecordedChunking.whole:
        server.sink.add(e.bytes);
      case RecordedChunking.everyByte:
        for (final b in e.bytes) {
          server.sink.add([b]);
        }
    }
  }
}

/// One server-side connection: buffers request bytes, answers each
/// complete request in order.
final class _Connection {
  _Connection(this._daemon, this._server) {
    _sub = _server.stream.listen(_onData, onDone: _stop, onError: (_) {});
  }

  final RecordedDaemon _daemon;
  final ByteDuplex _server;
  late final StreamSubscription<List<int>> _sub;
  final List<int> _buffer = <int>[];
  bool _stopped = false;

  void _onData(List<int> chunk) {
    if (_stopped) return;
    _buffer.addAll(chunk);
    while (!_stopped) {
      final end = _headEnd(_buffer);
      if (end < 0) return;
      final head = latin1.decode(_buffer.sublist(0, end));
      final lines = head.split('\r\n');
      var length = 0;
      for (final line in lines.skip(1)) {
        final colon = line.indexOf(':');
        if (colon > 0 &&
            line.substring(0, colon).trim().toLowerCase() == 'content-length') {
          length = int.parse(line.substring(colon + 1).trim());
        }
      }
      final total = end + 4 + length;
      if (_buffer.length < total) return;
      _buffer.removeRange(0, total);
      _answer(lines.first);
    }
  }

  void _answer(String requestLine) {
    final parts = requestLine.split(' ');
    final method = parts[0];
    final target = parts.length > 1 ? parts[1] : '/';
    _daemon.requests.add('$method $target');

    final e = _daemon.corpus.match(method, target);
    if (e == null) {
      _daemon.unmatched.add('$method $target');
      final body = utf8.encode(
        jsonEncode({'message': 'no recorded exchange for $method $target'}),
      );
      _server.sink.add(
        latin1.encode(
          'HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\n'
          'Content-Length: ${body.length}\r\n\r\n',
        ),
      );
      _server.sink.add(body);
      return;
    }

    _daemon._serve(_server, e);
    if (e.truncated) {
      // Live stream: nothing more is answered on this connection.
      _stopped = true;
      return;
    }
    if (e.closesConnection) {
      _stopped = true;
      unawaited(_server.closeWrite());
    }
  }

  void _stop() {
    _stopped = true;
    unawaited(_sub.cancel());
    unawaited(_server.close());
  }
}

int _headEnd(List<int> bytes) {
  for (var i = 0; i + 3 < bytes.length; i++) {
    if (bytes[i] == 0x0d &&
        bytes[i + 1] == 0x0a &&
        bytes[i + 2] == 0x0d &&
        bytes[i + 3] == 0x0a) {
      return i;
    }
  }
  return -1;
}

(Map<String, String>, int) _parseHead(Uint8List bytes) {
  final end = _headEnd(bytes);
  if (end < 0) return (const {}, bytes.length);
  final lines = latin1.decode(bytes.sublist(0, end)).split('\r\n');
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    headers[line.substring(0, colon).trim().toLowerCase()] = line
        .substring(colon + 1)
        .trim();
  }
  return (headers, end + 4);
}

final RegExp _versionPrefix = RegExp(r'^/v(\d+\.\d+)(/.*)$');

(ApiVersion?, String) _splitVersion(String path) {
  final m = _versionPrefix.firstMatch(path);
  if (m == null) return (null, path);
  return (ApiVersion.tryParse(m.group(1)), m.group(2)!);
}

/// Boolean query values in one spelling, and parameters at the Engine
/// API's default dropped, so `follow=0` matches an absent `follow` and
/// `stream=true` matches `stream=1`.
Map<String, String> _normalizeQuery(Map<String, String> query) {
  final out = <String, String>{};
  for (final MapEntry(:key, :value) in query.entries) {
    final v = switch (value.toLowerCase()) {
      '1' || 'true' => 'true',
      '0' || 'false' => 'false',
      _ => value,
    };
    if (_queryDefaults[key] == v) continue;
    out[key] = v;
  }
  return out;
}

// Engine API defaults of the endpoints the corpus records: `stream` is
// true for stats, which is why it may be left out. `attach`, whose
// `stream` defaults to false, is not recorded; recording it needs these
// keyed by endpoint.
const Map<String, String> _queryDefaults = {
  'all': 'false',
  'size': 'false',
  'follow': 'false',
  'timestamps': 'false',
  'stream': 'true',
  'one-shot': 'false',
};

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final MapEntry(:key, :value) in a.entries) {
    if (b[key] != value) return false;
  }
  return true;
}
