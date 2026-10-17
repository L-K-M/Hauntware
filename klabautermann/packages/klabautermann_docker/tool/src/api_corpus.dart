// The recorded Docker API corpus (03 §11.1, D21; spike S1): the raw
// response format, the manifest and the structural comparison that
// capture.sh's check mode runs. Pure Dart: no dart:io, so the package
// tests cover it without a daemon.
//
// A corpus directory, `test/fixtures/api-<version>/` or `api-podman/`,
// holds one `<exchange>.http` file per recorded exchange (the response
// bytes exactly as the daemon sent them: status line, headers and the
// body with its chunked framing), plus MANIFEST.json and SOURCE.md.
import 'dart:convert';
import 'dart:typed_data';

/// The manifest's file name in a corpus directory.
const String manifestFileName = 'MANIFEST.json';

/// The provenance note's file name in a corpus directory.
const String sourceFileName = 'SOURCE.md';

/// The manifest format this tool writes and reads.
const int manifestFormat = 1;

/// How a response body is delimited on the wire (RFC 9112 §6.3).
enum BodyFraming { none, length, chunked, close }

/// What a body holds, judged from its bytes: the check compares the kind,
/// never the content.
enum BodyKind { empty, json, jsonLines, stdcopy, text }

/// One response parsed from its raw bytes.
final class RecordedResponse {
  const RecordedResponse({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.framing,
    required this.body,
    required this.complete,
  });

  final int statusCode;
  final String reasonPhrase;

  /// Header fields in wire order, names as sent.
  final List<(String, String)> headers;
  final BodyFraming framing;

  /// The body with any chunked framing removed.
  final Uint8List body;

  /// False when the bytes end before the framing says the body does: a
  /// truncated stream recording.
  final bool complete;

  /// The first value of header [name], compared case-insensitively.
  String? header(String name) {
    final lower = name.toLowerCase();
    for (final (n, v) in headers) {
      if (n.toLowerCase() == lower) return v;
    }
    return null;
  }

  /// The media type of `Content-Type` in lowercase, parameters dropped.
  String? get mediaType {
    final value = header('content-type');
    if (value == null) return null;
    return value.split(';').first.trim().toLowerCase();
  }
}

/// Parses a recorded response. [headRequest] marks a response to `HEAD`,
/// which has no body whatever its headers say. Throws [FormatException]
/// on bytes that are not an HTTP/1.1 response.
RecordedResponse parseRecordedResponse(
  List<int> raw, {
  bool headRequest = false,
}) {
  final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
  final headEnd = _indexOf(bytes, const [13, 10, 13, 10], 0);
  if (headEnd < 0) throw const FormatException('no end of the header block');

  final lines = latin1.decode(bytes.sublist(0, headEnd)).split('\r\n');
  final status = RegExp(
    r'^HTTP/1\.[01] (\d{3})(?: (.*))?$',
  ).firstMatch(lines.first);
  if (status == null) {
    throw FormatException('bad status line', lines.first);
  }
  final headers = <(String, String)>[];
  for (final line in lines.skip(1)) {
    final colon = line.indexOf(':');
    if (colon <= 0) throw FormatException('bad header line', line);
    headers.add((line.substring(0, colon), line.substring(colon + 1).trim()));
  }

  final statusCode = int.parse(status[1]!);
  final response = RecordedResponse(
    statusCode: statusCode,
    reasonPhrase: status[2] ?? '',
    headers: headers,
    framing: BodyFraming.none,
    body: Uint8List(0),
    complete: true,
  );
  final rest = bytes.sublist(headEnd + 4);
  final framing = _framing(response, statusCode, headRequest);
  final (body, complete) = switch (framing) {
    BodyFraming.none => (Uint8List(0), true),
    BodyFraming.length => _lengthBody(response, rest),
    BodyFraming.chunked => _dechunk(rest),
    BodyFraming.close => (rest, true),
  };
  if (framing == BodyFraming.none && rest.isNotEmpty) {
    throw const FormatException('bytes after a response without a body');
  }
  return RecordedResponse(
    statusCode: statusCode,
    reasonPhrase: response.reasonPhrase,
    headers: headers,
    framing: framing,
    body: body,
    complete: complete,
  );
}

BodyFraming _framing(RecordedResponse head, int status, bool headRequest) {
  if (headRequest || status == 204 || status == 304 || status < 200) {
    return BodyFraming.none;
  }
  final te = head.header('transfer-encoding');
  if (te != null && te.toLowerCase().contains('chunked')) {
    return BodyFraming.chunked;
  }
  if (head.header('content-length') != null) return BodyFraming.length;
  return BodyFraming.close;
}

(Uint8List, bool) _lengthBody(RecordedResponse head, Uint8List rest) {
  final length = int.tryParse(head.header('content-length')!.trim());
  if (length == null || length < 0) {
    throw const FormatException('bad Content-Length');
  }
  if (rest.length > length) {
    throw const FormatException('bytes after the Content-Length body');
  }
  return (rest, rest.length == length);
}

/// De-chunks [rest]; the bool is false when the bytes stop before the
/// last chunk.
(Uint8List, bool) _dechunk(Uint8List rest) {
  final out = BytesBuilder(copy: false);
  for (final chunk in _chunks(rest)) {
    if (chunk.last) {
      return (out.takeBytes(), true);
    }
    out.add(rest.sublist(chunk.dataStart, chunk.dataEnd));
  }
  return (out.takeBytes(), false);
}

typedef _Chunk = ({int dataStart, int dataEnd, int end, bool last});

/// The complete chunks of a chunked body, in order. A partial chunk at
/// the end is left out; the terminal chunk has `last` set and ends the
/// sequence (trailers are not expected from the Engine API).
Iterable<_Chunk> _chunks(Uint8List rest) sync* {
  var at = 0;
  while (at < rest.length) {
    final lineEnd = _indexOf(rest, const [13, 10], at);
    if (lineEnd < 0) return;
    final sizeText = latin1.decode(rest.sublist(at, lineEnd)).split(';').first;
    final size = int.tryParse(sizeText.trim(), radix: 16);
    if (size == null || size < 0) {
      throw FormatException('bad chunk size', sizeText);
    }
    final dataStart = lineEnd + 2;
    if (size == 0) {
      final end = _indexOf(rest, const [13, 10], dataStart);
      if (end < 0) return;
      if (end + 2 != rest.length) {
        throw const FormatException('bytes after the last chunk');
      }
      yield (
        dataStart: dataStart,
        dataEnd: dataStart,
        end: end + 2,
        last: true,
      );
      return;
    }
    final dataEnd = dataStart + size;
    if (dataEnd + 2 > rest.length) return;
    if (rest[dataEnd] != 13 || rest[dataEnd + 1] != 10) {
      throw const FormatException('missing CRLF after a chunk');
    }
    yield (
      dataStart: dataStart,
      dataEnd: dataEnd,
      end: dataEnd + 2,
      last: false,
    );
    at = dataEnd + 2;
  }
}

/// Where to cut a recorded stream so that it holds the first [lines]
/// newline-terminated lines of its body and nothing after them: the end
/// of the chunk that completes line [lines] for a chunked body, the byte
/// after that newline for a close-delimited one. Null when the bytes hold
/// fewer lines, or the body has another framing.
int? truncationPoint(List<int> raw, int lines) {
  assert(lines > 0, 'lines must be positive');
  final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
  final headEnd = _indexOf(bytes, const [13, 10, 13, 10], 0);
  if (headEnd < 0) return null;
  final bodyStart = headEnd + 4;
  final response = parseRecordedResponse(bytes.sublist(0, bodyStart));
  final rest = bytes.sublist(bodyStart);
  var seen = 0;
  switch (_framing(response, response.statusCode, false)) {
    case BodyFraming.chunked:
      for (final chunk in _chunks(rest)) {
        if (chunk.last) return null;
        for (var i = chunk.dataStart; i < chunk.dataEnd; i++) {
          if (rest[i] == 10 && ++seen == lines) return bodyStart + chunk.end;
        }
      }
      return null;
    case BodyFraming.close:
      for (var i = 0; i < rest.length; i++) {
        if (rest[i] == 10 && ++seen == lines) return bodyStart + i + 1;
      }
      return null;
    case BodyFraming.none || BodyFraming.length:
      return null;
  }
}

/// The kind of [body]: one JSON value, JSON lines, a sequence of
/// stdcopy frames (03 §5.6), other text, or nothing.
BodyKind classifyBody(Uint8List body) {
  if (body.isEmpty) return BodyKind.empty;
  if (_isStdcopy(body)) return BodyKind.stdcopy;
  final text = utf8.decode(body, allowMalformed: true);
  if (_tryJson(text) case (true, _)) return BodyKind.json;
  final lines = _jsonLines(text);
  if (lines != null && lines.isNotEmpty) return BodyKind.jsonLines;
  return BodyKind.text;
}

/// The JSON values of [body]: one for [BodyKind.json], one per line for
/// [BodyKind.jsonLines], none otherwise.
List<Object?> jsonValues(Uint8List body) {
  final text = utf8.decode(body, allowMalformed: true);
  return switch (classifyBody(body)) {
    BodyKind.json => [_tryJson(text).$2],
    BodyKind.jsonLines => _jsonLines(text)!,
    _ => const [],
  };
}

(bool, Object?) _tryJson(String text) {
  try {
    return (true, jsonDecode(text));
  } on FormatException {
    return (false, null);
  }
}

List<Object?>? _jsonLines(String text) {
  final values = <Object?>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) continue;
    final (ok, value) = _tryJson(trimmed);
    if (!ok) return null;
    values.add(value);
  }
  return values;
}

/// True when [body] is a whole number of stdcopy frames: a stream byte
/// of 0, 1 or 2, three zero bytes and a big-endian payload length.
bool _isStdcopy(Uint8List body) {
  var at = 0;
  while (at < body.length) {
    if (at + 8 > body.length) return false;
    if (body[at] > 2 || body[at + 1] != 0 || body[at + 2] != 0) return false;
    if (body[at + 3] != 0) return false;
    final size = ByteData.sublistView(body, at + 4, at + 8).getUint32(0);
    at += 8 + size;
  }
  return at == body.length;
}

/// The payloads of [body]'s stdcopy frames in order, with their stream
/// (1 stdout, 2 stderr). Throws [FormatException] when it is not stdcopy.
List<(int, Uint8List)> stdcopyFrames(Uint8List body) {
  if (!_isStdcopy(body)) throw const FormatException('not stdcopy frames');
  final frames = <(int, Uint8List)>[];
  var at = 0;
  while (at < body.length) {
    final size = ByteData.sublistView(body, at + 4, at + 8).getUint32(0);
    frames.add((body[at], body.sublist(at + 8, at + 8 + size)));
    at += 8 + size;
  }
  return frames;
}

/// Object keys whose children the check does not compare: free-form
/// maps whose keys are data (labels, event attributes, driver options),
/// and the stats subtrees whose keys follow the host's cgroup version
/// (v1 on a developer machine, v2 on CI runners), not the API.
const Set<String> opaqueKeys = {
  'Labels',
  'Attributes',
  'Options',
  'DriverOpts',
  'Data',
  'memory_stats',
  'blkio_stats',
  'cpu_stats',
  'precpu_stats',
  'pids_stats',
};

/// A key that is an object id, such as the container ids keying a
/// Podman network's `Containers`; it changes with every run.
final RegExp _idKey = RegExp(r'^[0-9a-f]{64}$');

/// Every key path in [value]: `a.b` for nested objects, `a[]` for the
/// elements of a list (all elements merged), `<id>` for a 64-digit hex
/// id key, stopping below [opaqueKeys]. Values themselves never appear.
Set<String> jsonKeyPaths(Object? value) {
  final paths = <String>{};
  void walk(Object? node, String prefix) {
    if (node is Map) {
      for (final MapEntry(:key, value: child) in node.entries) {
        final name = _idKey.hasMatch('$key') ? '<id>' : '$key';
        final path = prefix.isEmpty ? name : '$prefix.$name';
        paths.add(path);
        if (!opaqueKeys.contains(key)) walk(child, path);
      }
    } else if (node is List) {
      for (final child in node) {
        walk(child, '$prefix[]');
      }
    }
  }

  walk(value, '');
  return paths;
}

/// Response headers that vary with the body size or the moment, left out
/// of the comparison.
const Set<String> volatileHeaders = {
  'connection',
  'content-length',
  'date',
  'keep-alive',
  'transfer-encoding',
};

/// The daemon facts a corpus is recorded from.
final class DaemonFacts {
  const DaemonFacts({
    required this.runtime,
    required this.version,
    required this.apiVersion,
    required this.minApiVersion,
    this.details = const {},
  });

  factory DaemonFacts.fromJson(Map<String, Object?> json) => DaemonFacts(
    runtime: json['runtime']! as String,
    version: json['version']! as String,
    apiVersion: json['apiVersion']! as String,
    minApiVersion: json['minApiVersion']! as String,
    details: {
      for (final MapEntry(:key, :value) in json.entries)
        if (!_daemonKeys.contains(key)) key: value,
    },
  );

  static const _daemonKeys = {
    'runtime',
    'version',
    'apiVersion',
    'minApiVersion',
  };

  /// `docker` or `podman`.
  final String runtime;
  final String version;
  final String apiVersion;
  final String minApiVersion;

  /// OS, kernel, cgroup and storage facts plus the daemon image; recorded
  /// for the reader, never compared.
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => {
    'runtime': runtime,
    'version': version,
    'apiVersion': apiVersion,
    'minApiVersion': minApiVersion,
    ...details,
  };
}

/// One recorded exchange as the manifest lists it.
final class ExchangeEntry {
  const ExchangeEntry({
    required this.name,
    required this.request,
    required this.status,
    required this.contentType,
    required this.framing,
    this.truncatedAfterLines,
  });

  factory ExchangeEntry.fromJson(Map<String, Object?> json) => ExchangeEntry(
    name: json['name']! as String,
    request: json['request']! as String,
    status: json['status']! as int,
    contentType: json['contentType'] as String?,
    framing: BodyFraming.values.byName(json['framing']! as String),
    truncatedAfterLines: json['truncatedAfterLines'] as int?,
  );

  /// Stable across corpora; the file is `<name>.http`.
  final String name;

  /// `<METHOD> <path>[?<query>]` as sent.
  final String request;
  final int status;
  final String? contentType;
  final BodyFraming framing;

  /// Set for a stream the tool cut after this many lines; the bytes end
  /// at a chunk boundary inside the body.
  final int? truncatedAfterLines;

  String get file => '$name.http';

  String get method => request.substring(0, request.indexOf(' '));

  Uri get target => Uri.parse(request.substring(request.indexOf(' ') + 1));

  Map<String, Object?> toJson() => {
    'name': name,
    'file': file,
    'request': request,
    'status': status,
    'contentType': contentType,
    'framing': framing.name,
    'truncatedAfterLines': ?truncatedAfterLines,
  };
}

/// MANIFEST.json of one corpus directory.
final class CorpusManifest {
  const CorpusManifest({
    required this.corpus,
    required this.capturedAt,
    required this.daemon,
    required this.images,
    required this.seeded,
    required this.exchanges,
  });

  factory CorpusManifest.fromJson(Map<String, Object?> json) {
    final format = json['format'];
    if (format != manifestFormat) {
      throw FormatException('unknown manifest format $format');
    }
    return CorpusManifest(
      corpus: json['corpus']! as String,
      capturedAt: json['capturedAt']! as String,
      daemon: DaemonFacts.fromJson(json['daemon']! as Map<String, Object?>),
      images: (json['images']! as Map<String, Object?>).cast(),
      seeded: json['seeded']! as Map<String, Object?>,
      exchanges: [
        for (final e in json['exchanges']! as List<Object?>)
          ExchangeEntry.fromJson(e! as Map<String, Object?>),
      ],
    );
  }

  /// The directory name: `api-<version>` or `api-podman`.
  final String corpus;
  final String capturedAt;
  final DaemonFacts daemon;

  /// Image references and ids by role (`seed`, `seedId`, `dangling`).
  final Map<String, String> images;

  /// Ids of what the tool created, by name; values differ on every run.
  final Map<String, Object?> seeded;
  final List<ExchangeEntry> exchanges;

  Map<String, Object?> toJson() => {
    'format': manifestFormat,
    'corpus': corpus,
    'capturedAt': capturedAt,
    'daemon': daemon.toJson(),
    'images': images,
    'seeded': seeded,
    'exchanges': [for (final e in exchanges) e.toJson()],
  };

  /// Two-space indented JSON with a final newline.
  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';
}

/// What check mode compares for one exchange: never IDs, timestamps or
/// other values, which change with every run.
final class ExchangeShape {
  ExchangeShape._({
    required this.name,
    required this.method,
    required this.path,
    required this.queryKeys,
    required this.status,
    required this.mediaType,
    required this.headerNames,
    required this.bodyKind,
    required this.keyPaths,
    required this.truncated,
  });

  /// The shape of [entry] from its recorded bytes [raw]. Throws
  /// [FormatException] when the bytes do not parse or disagree with the
  /// manifest entry.
  factory ExchangeShape.of(ExchangeEntry entry, List<int> raw) {
    final response = parseRecordedResponse(
      raw,
      headRequest: entry.method == 'HEAD',
    );
    if (response.statusCode != entry.status) {
      throw FormatException(
        '${entry.file}: status ${response.statusCode}, '
        'manifest ${entry.status}',
      );
    }
    if (response.framing != entry.framing) {
      throw FormatException(
        '${entry.file}: ${response.framing.name} framing, '
        'manifest ${entry.framing.name}',
      );
    }
    if (!response.complete && entry.truncatedAfterLines == null) {
      throw FormatException('${entry.file}: the body is incomplete');
    }
    final kind = classifyBody(response.body);
    return ExchangeShape._(
      name: entry.name,
      method: entry.method,
      path: entry.target.path,
      queryKeys: entry.target.queryParameters.keys.toList()..sort(),
      status: response.statusCode,
      mediaType: response.mediaType,
      headerNames: {
        for (final (name, _) in response.headers)
          if (!volatileHeaders.contains(name.toLowerCase())) name.toLowerCase(),
      }.toList()..sort(),
      bodyKind: kind,
      keyPaths: {
        for (final value in jsonValues(response.body)) ...jsonKeyPaths(value),
      }.toList()..sort(),
      truncated: entry.truncatedAfterLines != null,
    );
  }

  final String name;
  final String method;
  final String path;
  final List<String> queryKeys;
  final int status;
  final String? mediaType;
  final List<String> headerNames;
  final BodyKind bodyKind;
  final List<String> keyPaths;
  final bool truncated;

  /// The differences from [other], each one line naming this exchange.
  List<String> differences(ExchangeShape other) {
    final out = <String>[];
    void compare(String what, Object? a, Object? b) {
      if ('$a' != '$b') out.add('$name: $what $a, now $b');
    }

    compare('request', '$method $path', '${other.method} ${other.path}');
    compare('query keys', queryKeys, other.queryKeys);
    compare('status', status, other.status);
    compare('content type', mediaType, other.mediaType);
    compare('body kind', bodyKind.name, other.bodyKind.name);
    compare('truncated', truncated, other.truncated);
    for (final (what, mine, theirs) in [
      ('header', headerNames, other.headerNames),
      ('key', keyPaths, other.keyPaths),
    ]) {
      final gone = mine.toSet().difference(theirs.toSet());
      final added = theirs.toSet().difference(mine.toSet());
      for (final k in gone.toList()..sort()) {
        out.add('$name: $what $k is gone');
      }
      for (final k in added.toList()..sort()) {
        out.add('$name: $what $k is new');
      }
    }
    return out;
  }
}

/// Reads a corpus directory through [readFile] (relative file name to
/// bytes, or null when the file is missing): the manifest and the shape
/// of every exchange it lists. Throws [FormatException] on a missing or
/// malformed file.
(CorpusManifest, List<ExchangeShape>) readCorpus(
  Uint8List? Function(String file) readFile,
) {
  final manifestBytes = readFile(manifestFileName);
  if (manifestBytes == null) {
    throw const FormatException('no $manifestFileName');
  }
  final manifest = CorpusManifest.fromJson(
    jsonDecode(utf8.decode(manifestBytes)) as Map<String, Object?>,
  );
  final shapes = <ExchangeShape>[];
  for (final entry in manifest.exchanges) {
    final raw = readFile(entry.file);
    if (raw == null) throw FormatException('no ${entry.file}');
    shapes.add(ExchangeShape.of(entry, raw));
  }
  return (manifest, shapes);
}

/// Check mode (capture.sh): every structural difference between the
/// committed corpus and a fresh capture of the same daemon, one line
/// each; empty when they match. The daemon must report the same runtime,
/// version and API range; the exchanges must come in the same order.
List<String> compareCorpora(
  (CorpusManifest, List<ExchangeShape>) committed,
  (CorpusManifest, List<ExchangeShape>) captured,
) {
  final (mine, myShapes) = committed;
  final (theirs, theirShapes) = captured;
  final out = <String>[];
  void compare(String what, Object? a, Object? b) {
    if ('$a' != '$b') out.add('$what $a, now $b');
  }

  compare('corpus', mine.corpus, theirs.corpus);
  compare('runtime', mine.daemon.runtime, theirs.daemon.runtime);
  compare('daemon version', mine.daemon.version, theirs.daemon.version);
  compare('API version', mine.daemon.apiVersion, theirs.daemon.apiVersion);
  compare(
    'minimum API version',
    mine.daemon.minApiVersion,
    theirs.daemon.minApiVersion,
  );
  compare(
    'exchanges',
    [for (final s in myShapes) s.name].join(' '),
    [for (final s in theirShapes) s.name].join(' '),
  );
  final byName = {for (final s in theirShapes) s.name: s};
  for (final shape in myShapes) {
    final other = byName[shape.name];
    if (other != null) out.addAll(shape.differences(other));
  }
  return out;
}

int _indexOf(Uint8List bytes, List<int> needle, int from) {
  outer:
  for (var i = from; i <= bytes.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (bytes[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
