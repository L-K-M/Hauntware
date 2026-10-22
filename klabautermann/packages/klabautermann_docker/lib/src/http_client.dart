import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'api_version.dart';
import 'duplex.dart';
import 'errors.dart';
import 'http_types.dart';
import 'json_streams.dart';

/// 03 §5.5: parser and pool limits.
const int _maxStatusLineBytes = 8 * 1024;
const int _maxHeaderLineBytes = 16 * 1024;
const int _maxHeaderBlockBytes = 64 * 1024;
const int _maxHeaderCount = 128;
const int _maxChunkSizeLineBytes = 8 * 1024;
const int _maxErrorBodyBytes = 64 * 1024;
const int defaultMaxBufferedBytes = 16 * 1024 * 1024;

/// 03 §5.2: at most 16 duplexes per host toward the engine socket, to
/// protect the daemon and the per-channel window.
const int defaultMaxConnections = 16;

final RegExp _statusLineRe = RegExp(
  r'^HTTP/(\d+)\.(\d+) (\d{3})(?:[ \t](.*))?$',
);
final RegExp _tokenRe = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// Headers the client owns; caller-supplied copies are dropped.
const Set<String> _managedHeaders = {
  'host',
  'content-length',
  'content-type',
  'connection',
  'upgrade',
};

/// Pure-Dart HTTP/1.1 client for the Docker Engine API (03 §5.5, D20):
/// one serialized request per connection, keep-alive reuse until the
/// daemon says `Connection: close`, a small pool opening fresh duplexes
/// through the injected [DuplexOpener] up to [maxConnections].
final class DockerHttpClient {
  DockerHttpClient(
    this._opener, {
    int maxConnections = defaultMaxConnections,
    Duration? defaultTimeout = const Duration(seconds: 30),
  }) : _maxConnections = maxConnections,
       _defaultTimeout = defaultTimeout {
    assert(maxConnections > 0, 'maxConnections must be positive');
    assert(
      defaultTimeout == null || defaultTimeout > Duration.zero,
      'defaultTimeout must be positive',
    );
  }

  final DuplexOpener _opener;
  final int _maxConnections;
  final Duration? _defaultTimeout;

  final Queue<_Connection> _idle = Queue<_Connection>();
  final Set<_Connection> _all = <_Connection>{};
  final Queue<_Waiter> _waiters = Queue<_Waiter>();
  int _opening = 0;
  bool _closed = false;

  /// Live duplexes: idle, serving, and hijacked. Diagnostics only.
  int get connectionCount => _all.length;

  /// Sends [request] and returns the head with the whole body buffered,
  /// capped at [maxBytes] (03 §5.5 `buffered`). The timeout covers the
  /// whole exchange.
  Future<DockerResponse<Uint8List>> sendBuffered(
    DockerHttpRequest request, {
    int maxBytes = defaultMaxBufferedBytes,
  }) => _guard(request, (scope) async {
    final result = await _transact(request, scope);
    final head = result.head;
    return DockerResponse<Uint8List>(
      statusCode: head.statusCode,
      reasonPhrase: head.reasonPhrase,
      headers: head.headers,
      body: await _collect(result.body as Stream<List<int>>, maxBytes),
    );
  });

  /// Sends [request] and returns the head with the body as a raw chunk
  /// stream (03 §5.5 `bytes`). The timeout covers the response head only;
  /// the stream then flows until consumed or cancelled. Cancelling the
  /// stream closes the duplex.
  Future<DockerResponse<Stream<List<int>>>> sendBytes(
    DockerHttpRequest request,
  ) => _guard(request, (scope) async {
    final result = await _transact(request, scope);
    final head = result.head;
    return DockerResponse<Stream<List<int>>>(
      statusCode: head.statusCode,
      reasonPhrase: head.reasonPhrase,
      headers: head.headers,
      body: result.body as Stream<List<int>>,
    );
  });

  /// Sends [request] and returns the head with the body split into lines
  /// for the daemon's JSON stream formats: NDJSON, `application/json-seq`
  /// (leading RS stripped) and `application/jsonl` (03 §5.5 `lines`).
  /// Empty lines are skipped.
  Future<DockerResponse<Stream<String>>> sendLines(DockerHttpRequest request) =>
      _guard(request, (scope) async {
        final result = await _transact(request, scope);
        final head = result.head;
        return DockerResponse<Stream<String>>(
          statusCode: head.statusCode,
          reasonPhrase: head.reasonPhrase,
          headers: head.headers,
          body: byteStreamToLines(result.body as Stream<List<int>>),
        );
      });

  /// Sends [request] and returns the head with the body scanned as
  /// concatenated JSON values, no separators required (03 §5.5
  /// `jsonValues`; pull progress in §5.6).
  Future<DockerResponse<Stream<Object?>>> sendJsonValues(
    DockerHttpRequest request,
  ) => _guard(request, (scope) async {
    final result = await _transact(request, scope);
    final head = result.head;
    return DockerResponse<Stream<Object?>>(
      statusCode: head.statusCode,
      reasonPhrase: head.reasonPhrase,
      headers: head.headers,
      body: byteStreamToJsonValues(result.body as Stream<List<int>>),
    );
  });

  /// Sends [request] (usually with `upgrade: true`) and on `101` or `200`
  /// hands the hijacked duplex to the caller, buffered remainder included
  /// (03 §5.5 `hijack`, §5.7). Any other status is a typed failure.
  Future<DockerResponse<HijackedDuplex>> sendHijack(
    DockerHttpRequest request,
  ) => _guard(request, (scope) async {
    final result = await _transact(request, scope, expectHijack: true);
    final head = result.head;
    return DockerResponse<HijackedDuplex>(
      statusCode: head.statusCode,
      reasonPhrase: head.reasonPhrase,
      headers: head.headers,
      body: result.body as HijackedDuplex,
    );
  });

  /// Closes every pooled and hijacked duplex and fails queued requests.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final conns = _all.toList();
    _all.clear();
    _idle.clear();
    for (final c in conns) {
      c.abort(const DockerTransportException('client closed'));
    }
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().fail(
        const DockerTransportException('client closed'),
      );
    }
  }

  // --- internals -------------------------------------------------------

  /// Runs [work] under the request's timeout and cancel token. The timer
  /// covers whatever [work] awaits; the token aborts the in-flight
  /// exchange. The scope is disarmed when [work] completes so a late
  /// cancel cannot kill a connection already serving another request.
  Future<T> _guard<T>(
    DockerHttpRequest request,
    Future<T> Function(_RequestScope scope) work,
  ) {
    final scope = _RequestScope();
    final timeout = request.timeout ?? _defaultTimeout;
    final token = request.cancelToken;
    if (timeout == null && token == null) return work(scope);

    final out = Completer<T>();
    Timer? timer;
    work(scope).then(
      (v) {
        timer?.cancel();
        scope.disarm();
        if (!out.isCompleted) out.complete(v);
      },
      onError: (Object e, StackTrace st) {
        timer?.cancel();
        scope.disarm();
        if (!out.isCompleted) out.completeError(e, st);
      },
    );
    if (timeout != null) {
      timer = Timer(timeout, () {
        if (out.isCompleted) return;
        final err = DockerTimeoutException(timeout);
        scope.abort(err);
        out.completeError(err);
      });
    }
    token?.onCancel(() {
      if (out.isCompleted) return;
      const err = DockerCancelledException('request cancelled');
      scope.abort(err);
      out.completeError(err);
    });
    return out.future;
  }

  /// Acquires a connection, writes the request, parses the head, maps
  /// error statuses, then returns the head plus the body conduit: a
  /// `Stream<List<int>>` of de-chunked bytes, or the hijacked duplex.
  /// One connection carries one request at a time (03 §5.5: no
  /// pipelining).
  Future<({Object? body, _Head head})> _transact(
    DockerHttpRequest request,
    _RequestScope scope, {
    bool expectHijack = false,
  }) async {
    // Serialize first: caller-side validation errors must not cost a
    // healthy pooled connection.
    final requestBytes = _encodeRequest(request);
    final conn = await _acquire(scope);
    var owned = true;
    try {
      conn.write(requestBytes);
      final head = await conn.readHead(
        isHeadRequest: request.method.toUpperCase() == 'HEAD',
      );
      final ok = expectHijack
          ? head.statusCode == 101 || head.statusCode ~/ 100 == 2
          : head.statusCode < 300;
      if (!ok) {
        var errorBody = Uint8List(0);
        try {
          // Draining releases the connection through the body pump's
          // completion path when the body ends cleanly.
          errorBody = await conn.drainErrorBody(head);
        } catch (_) {
          errorBody = Uint8List(0);
        }
        owned = false;
        throw _apiError(head.statusCode, errorBody);
      }
      if (expectHijack) {
        final hijacked = conn.hijack();
        owned = false;
        return (head: head, body: hijacked);
      }
      final body = conn.attachBody(head);
      return (head: head, body: body);
    } catch (e) {
      if (owned) {
        conn.abort(
          e is DockerException
              ? e
              : DockerTransportException('request failed', cause: e),
        );
      }
      rethrow;
    }
  }

  Future<_Connection> _acquire(_RequestScope scope) async {
    if (scope.aborted) throw scope.abortError!;
    if (_closed) throw const DockerTransportException('client is closed');
    while (_idle.isNotEmpty) {
      final c = _idle.removeFirst();
      if (!c.usable) {
        _all.remove(c);
        c.dispose();
        continue;
      }
      c.markBusy();
      scope.bind(c);
      return c;
    }
    // In-flight opens count toward the cap, or concurrent acquires and
    // waiter handoffs could overshoot it.
    if (_all.length + _opening < _maxConnections) {
      _opening++;
      try {
        final c = await _open(scope);
        _all.add(c);
        c.markBusy();
        scope.bind(c);
        return c;
      } finally {
        _opening--;
      }
    }
    final w = _Waiter(scope);
    _waiters.add(w);
    scope.bindAction((e) {
      if (_waiters.remove(w)) w.fail(e);
    });
    return w.completer.future;
  }

  Future<_Connection> _open(_RequestScope scope) async {
    ByteDuplex? duplex;
    scope.bindAction((_) {
      final d = duplex;
      if (d != null) unawaited(d.close());
    });
    try {
      duplex = await _opener();
    } catch (e) {
      throw DockerTransportException('failed to open a duplex', cause: e);
    }
    if (scope.aborted) {
      unawaited(duplex.close());
      throw scope.abortError ?? const DockerCancelledException('cancelled');
    }
    return _Connection(duplex, onIdle: _release, onDead: _drop);
  }

  /// The connection finished its request: reuse, hand to a queued
  /// request, or drop it (03 §5.5: `Connection: close` retires it).
  void _release(_Connection conn, {required bool keepAlive}) {
    if (!conn.alive || !keepAlive || _closed) {
      conn.dispose();
      _drop(conn);
      return;
    }
    if (_waiters.isNotEmpty) {
      final w = _waiters.removeFirst();
      conn.markBusy();
      w.complete(conn);
      return;
    }
    _idle.add(conn);
  }

  /// The connection left the rotation: dead, retired, or hijacked-side
  /// cleanup. Freed capacity serves queued requests.
  void _drop(_Connection conn) {
    _all.remove(conn);
    _idle.remove(conn);
    while (_waiters.isNotEmpty &&
        _all.length + _opening < _maxConnections &&
        !_closed) {
      final w = _waiters.removeFirst();
      _opening++;
      unawaited(
        _open(w.scope)
            .then((c) {
              _opening--;
              _all.add(c);
              c.markBusy();
              w.complete(c);
            })
            .onError((Object e, StackTrace st) {
              _opening--;
              w.fail(e);
            }),
      );
    }
  }

  Future<Uint8List> _collect(Stream<List<int>> body, int maxBytes) async {
    final b = BytesBuilder(copy: false);
    await for (final c in body) {
      if (b.length + c.length > maxBytes) {
        throw DockerBodyTooLargeException(maxBytes);
      }
      b.add(c);
    }
    return b.takeBytes();
  }

  /// Maps an error status to a typed failure (03 §5.5): 400 version
  /// shaped or plain, 404, 409, 5xx, anything else.
  DockerApiException _apiError(int status, Uint8List body) {
    String? message;
    try {
      final decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
      if (decoded is Map && decoded['message'] is String) {
        message = decoded['message'] as String;
      }
    } catch (_) {
      final text = utf8.decode(body, allowMalformed: true).trim();
      if (text.isNotEmpty) {
        message = text.length > 200 ? '${text.substring(0, 200)}...' : text;
      }
    }
    message ??= 'HTTP $status';
    switch (status) {
      case 400:
        final m = RegExp(
          r'client version (\d+\.\d+) is too new.*?[Mm]aximum supported API version is (\d+\.\d+)',
        ).firstMatch(message);
        if (m != null) {
          return DockerVersionException(
            status,
            message,
            clientVersion: ApiVersion.tryParse(m.group(1)!),
            serverMaxVersion: ApiVersion.tryParse(m.group(2)!),
          );
        }
        final lower = message.toLowerCase();
        if (lower.contains('client version') && lower.contains('api version')) {
          return DockerVersionException(status, message);
        }
        return DockerBadRequestException(status, message);
      case 404:
        return DockerNotFoundException(status, message);
      case 409:
        return DockerConflictException(status, message);
      default:
        if (status >= 500) return DockerServerException(status, message);
        return DockerUnexpectedStatusException(status, message);
    }
  }

  /// Serializes a request: request line, `Host: docker`, encoded query,
  /// JSON bodies with `Content-Length`, `Upgrade` headers when asked
  /// (03 §5.5).
  Uint8List _encodeRequest(DockerHttpRequest r) {
    if (r.method.isEmpty || !_tokenRe.hasMatch(r.method)) {
      throw ArgumentError.value(r.method, 'method', 'invalid HTTP method');
    }
    if (!r.path.startsWith('/') ||
        r.path.contains('\r') ||
        r.path.contains('\n') ||
        r.path.contains(' ')) {
      throw ArgumentError.value(r.path, 'path', 'invalid request path');
    }

    final head = StringBuffer()
      ..write(r.method)
      ..write(' ')
      ..write(r.path);
    if (r.query != null && r.query!.isNotEmpty) {
      var first = true;
      for (final e in r.query!.entries) {
        if (e.key.contains('\r') ||
            e.key.contains('\n') ||
            e.value.contains('\r') ||
            e.value.contains('\n')) {
          throw ArgumentError.value(
            r.query,
            'query',
            'CR/LF in query parameter',
          );
        }
        head.write(first ? '?' : '&');
        first = false;
        head
          ..write(Uri.encodeQueryComponent(e.key))
          ..write('=')
          ..write(Uri.encodeQueryComponent(e.value));
      }
    }
    head
      ..write(' HTTP/1.1\r\n')
      ..write('Host: docker\r\n');
    if (r.headers != null) {
      for (final e in r.headers!.entries) {
        if (_managedHeaders.contains(e.key.toLowerCase())) continue;
        if (e.key.contains('\r') ||
            e.key.contains('\n') ||
            e.key.contains(':') ||
            e.value.contains('\r') ||
            e.value.contains('\n')) {
          throw ArgumentError.value(
            r.headers,
            'headers',
            'CR/LF or colon in header',
          );
        }
        head
          ..write(e.key)
          ..write(': ')
          ..write(e.value)
          ..write('\r\n');
      }
    }
    final bodyBytes = r.json != null ? utf8.encode(jsonEncode(r.json)) : r.body;
    if (bodyBytes != null) {
      final ct = r.json != null ? 'application/json' : r.contentType;
      if (ct != null) head.write('Content-Type: $ct\r\n');
      head.write('Content-Length: ${bodyBytes.length}\r\n');
    } else if (const {
      'POST',
      'PUT',
      'PATCH',
    }.contains(r.method.toUpperCase())) {
      head.write('Content-Length: 0\r\n');
    }
    if (r.upgrade) {
      head.write('Connection: Upgrade\r\nUpgrade: tcp\r\n');
    }
    head.write('\r\n');

    final builder = BytesBuilder()..add(latin1.encode(head.toString()));
    if (bodyBytes != null) builder.add(bodyBytes);
    return builder.takeBytes();
  }
}

/// Carries the abort action for the guarded exchange through the acquire
/// phases: queued wait, opener in flight, then the bound connection.
final class _RequestScope {
  void Function(Object error)? _abort;
  Object? abortError;
  bool _disarmed = false;

  bool get aborted => abortError != null;

  void abort(Object error) {
    if (_disarmed || aborted) return;
    abortError = error;
    _abort?.call(error);
  }

  void disarm() => _disarmed = true;

  void bind(_Connection conn) => _abort = conn.abort;

  void bindAction(void Function(Object error) action) => _abort = action;
}

final class _Waiter {
  _Waiter(this.scope);
  final _RequestScope scope;
  final Completer<_Connection> completer = Completer<_Connection>();

  void complete(_Connection c) {
    if (completer.isCompleted) return;
    scope.bind(c);
    completer.complete(c);
  }

  void fail(Object e) {
    if (!completer.isCompleted) completer.completeError(e);
  }
}

enum _BodyShape { empty, length, chunked, close }

final class _Head {
  _Head({
    required this.statusCode,
    required this.reasonPhrase,
    required this.headers,
    required this.httpMinor,
    required this.shape,
    required this.contentLength,
  });

  final int statusCode;
  final String reasonPhrase;
  final HttpHeaders headers;
  final int httpMinor;
  final _BodyShape shape;
  final int contentLength;

  /// 03 §5.5: `Connection: close` retires the connection; HTTP/1.0
  /// without an explicit keep-alive does too.
  bool get keepAlive {
    if (shape == _BodyShape.close) return false;
    final tokens = headers.tokens('connection');
    if (tokens.contains('close')) return false;
    if (httpMinor == 0 && !tokens.contains('keep-alive')) return false;
    return true;
  }
}

/// One keep-alive HTTP/1.1 connection over a [ByteDuplex]. Reads are
/// serialized: inbound bytes are buffered and the parser pulls.
final class _Connection {
  _Connection(this._duplex, {required this.onIdle, required this.onDead}) {
    _sub = _duplex.stream.listen(
      _onData,
      onError: _onReadError,
      onDone: _onReadDone,
    );
    unawaited(
      _duplex.done.then(
        (_) => _remoteClosed(),
        onError: (_, _) => _remoteClosed(),
      ),
    );
  }

  final ByteDuplex _duplex;
  final void Function(_Connection, {required bool keepAlive}) onIdle;
  final void Function(_Connection) onDead;
  late final StreamSubscription<List<int>> _sub;

  final List<int> _buf = <int>[];
  int _pos = 0;
  Completer<void>? _dataReady;
  bool _eof = false;
  Object? _readError;
  Object? _abortError;

  bool _busy = false;
  bool _retired = false;
  _BodyCtl? _bodyCtl;
  StreamController<List<int>>? _hijackCtl;

  bool get _broken => _abortError != null || _readError != null;

  /// Still carries bytes in at least the read direction.
  bool get alive => !_broken && !_eof && !_retired;

  /// Fit to take another request.
  bool get usable => alive && !_busy;

  int get _available => _buf.length - _pos;

  void markBusy() => _busy = true;

  void _onData(List<int> chunk) {
    final h = _hijackCtl;
    if (h != null) {
      h.add(chunk);
      return;
    }
    _buf.addAll(chunk);
    _wake();
  }

  void _onReadError(Object error, StackTrace st) {
    _readError = error;
    _hijackCtl?.addError(error, st);
    _wake();
    if (!_busy) onDead(this);
  }

  void _onReadDone() {
    _eof = true;
    _closeHijackCtl();
    _wake();
    if (!_busy) onDead(this);
  }

  void _remoteClosed() {
    _eof = true;
    _closeHijackCtl();
    _wake();
    if (!_busy) onDead(this);
  }

  void _closeHijackCtl() {
    final h = _hijackCtl;
    if (h != null && !h.isClosed) unawaited(h.close());
  }

  void _wake() {
    final c = _dataReady;
    _dataReady = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Waits until more than [have] bytes are buffered. Returns false at
  /// remote EOF. A caller holding a partial line or field passes what it
  /// has: the bytes it lacks arrive with a later socket event, and
  /// returning at once would spin in microtasks that starve that event.
  Future<bool> _fill([int have = 0]) async {
    while (_available <= have) {
      final err = _abortError ?? _readError;
      if (err != null) {
        throw err is DockerException
            ? err
            : DockerTransportException('read failed', cause: err);
      }
      if (_eof) return false;
      _dataReady ??= Completer<void>();
      await _dataReady!.future;
    }
    return true;
  }

  void _consume(int n) {
    _pos += n;
    if (_pos >= _buf.length) {
      _buf.clear();
      _pos = 0;
      return;
    }
    if (_pos > 64 * 1024 && _pos * 2 > _buf.length) {
      _buf.removeRange(0, _pos);
      _pos = 0;
    }
  }

  Uint8List _take(int n) {
    final out = Uint8List.fromList(_buf.sublist(_pos, _pos + n));
    _consume(n);
    return out;
  }

  Uint8List _takeAll() => _take(_available);

  int _indexOfCrlf() {
    for (var i = _pos; i + 1 < _buf.length; i++) {
      if (_buf[i] == 0x0D && _buf[i + 1] == 0x0A) return i;
    }
    return -1;
  }

  /// One CRLF-terminated line. Null only at EOF with an empty buffer;
  /// EOF mid-line is a protocol error, as is a line over [maxBytes].
  Future<String?> _readLine(int maxBytes, String what) async {
    while (true) {
      final idx = _indexOfCrlf();
      if (idx >= 0) {
        final len = idx - _pos;
        if (len > maxBytes) {
          throw DockerProtocolException('$what exceeds $maxBytes bytes');
        }
        final line = String.fromCharCodes(_buf, _pos, idx);
        _consume(len + 2);
        return line;
      }
      if (_available > maxBytes) {
        throw DockerProtocolException('$what exceeds $maxBytes bytes');
      }
      if (!await _fill(_available)) {
        if (_available == 0) return null;
        // The peer is gone: the buffered tail can never gain a CRLF.
        throw DockerProtocolException('connection closed mid-$what');
      }
    }
  }

  /// Exactly [n] bytes; null at EOF-short so callers decide truncation.
  Future<Uint8List?> _readBytes(int n) async {
    while (_available < n) {
      if (!await _fill(_available)) return null;
    }
    return _take(n);
  }

  void write(Uint8List bytes) {
    try {
      _duplex.sink.add(bytes);
    } catch (e) {
      throw DockerTransportException('request write failed', cause: e);
    }
  }

  /// Parses the status line and headers (03 §5.5, caps included) and
  /// determines the body shape.
  Future<_Head> readHead({required bool isHeadRequest}) async {
    // Skip informational 1xx (except 101, which terminates the exchange).
    var code = 0;
    var reason = '';
    var httpMinor = 1;
    while (true) {
      final line = await _readLine(_maxStatusLineBytes, 'status line');
      if (line == null) {
        throw const DockerProtocolException(
          'connection closed before a response arrived',
        );
      }
      final m = _statusLineRe.firstMatch(line);
      if (m == null) {
        throw DockerProtocolException(
          'malformed status line: '
          '${line.length > 80 ? '${line.substring(0, 80)}...' : line}',
        );
      }
      httpMinor = int.parse(m.group(2)!);
      code = int.parse(m.group(3)!);
      reason = m.group(4) ?? '';
      if (code != 101 && code >= 100 && code < 200) {
        await _readHeaderBlock();
        continue;
      }
      break;
    }
    final headers = await _readHeaderBlock();

    final shape = _bodyShape(headers, code, isHeadRequest);
    var contentLength = 0;
    if (shape == _BodyShape.length) {
      contentLength = _contentLength(headers);
    }
    return _Head(
      statusCode: code,
      reasonPhrase: reason,
      headers: headers,
      httpMinor: httpMinor,
      shape: shape,
      contentLength: contentLength,
    );
  }

  Future<HttpHeaders> _readHeaderBlock() async {
    final entries = <(String, String)>[];
    var total = 0;
    while (true) {
      final line = await _readLine(_maxHeaderLineBytes, 'header line');
      if (line == null) {
        throw const DockerProtocolException(
          'connection closed inside response headers',
        );
      }
      if (line.isEmpty) break;
      total += line.length + 2;
      if (total > _maxHeaderBlockBytes) {
        throw const DockerProtocolException(
          'response headers exceed the 64 KiB cap',
        );
      }
      if (entries.length >= _maxHeaderCount) {
        throw const DockerProtocolException('too many response headers');
      }
      if ((line.startsWith(' ') || line.startsWith('\t')) &&
          entries.isNotEmpty) {
        // Obsolete line folding: join into the previous value.
        final (name, value) = entries.last;
        entries[entries.length - 1] = (name, '$value ${line.trim()}');
        continue;
      }
      final colon = line.indexOf(':');
      if (colon <= 0) {
        throw DockerProtocolException(
          'malformed header line: '
          '${line.length > 80 ? '${line.substring(0, 80)}...' : line}',
        );
      }
      entries.add((
        line.substring(0, colon).trim(),
        line.substring(colon + 1).trim(),
      ));
    }
    return HttpHeaders(entries);
  }

  _BodyShape _bodyShape(HttpHeaders h, int code, bool isHeadRequest) {
    if (isHeadRequest ||
        code == 204 ||
        code == 304 ||
        (code >= 100 && code < 200 && code != 101)) {
      return _BodyShape.empty;
    }
    // An unexpected 101 outside a hijack leaves opaque bytes to EOF.
    if (code == 101) return _BodyShape.close;
    final te = h.tokens('transfer-encoding');
    if (te.isNotEmpty) {
      if (te.last == 'chunked') return _BodyShape.chunked;
      // An unknown final coding: opaque bytes until close.
      return _BodyShape.close;
    }
    if (h.contains('content-length')) return _BodyShape.length;
    return _BodyShape.close;
  }

  int _contentLength(HttpHeaders h) {
    final values = <int>{};
    for (final raw in h['content-length'] ?? const <String>[]) {
      for (final part in raw.split(',')) {
        final n = int.tryParse(part.trim());
        if (n == null || n < 0) {
          throw DockerProtocolException(
            'malformed Content-Length: ${part.trim()}',
          );
        }
        values.add(n);
      }
    }
    // Conflicting lengths are a desynchronization risk.
    if (values.length > 1) {
      throw const DockerProtocolException('conflicting Content-Length headers');
    }
    return values.first;
  }

  /// Attaches the body pump for [head]; the returned stream yields raw
  /// de-chunked bytes. Completion returns the connection to the pool;
  /// stream cancellation closes the duplex.
  Stream<List<int>> attachBody(_Head head) {
    final ctl = _BodyCtl(this);
    _bodyCtl = ctl;
    unawaited(_pumpBody(head, ctl));
    return ctl.controller.stream;
  }

  /// Reads the error body for a failed status, keeping at most
  /// [_maxErrorBodyBytes] for the daemon message.
  Future<Uint8List> drainErrorBody(_Head head) async {
    final ctl = _BodyCtl(this);
    _bodyCtl = ctl;
    final collected = BytesBuilder(copy: false);
    var overflow = false;
    unawaited(_pumpBody(head, ctl));
    await for (final chunk in ctl.controller.stream) {
      if (!overflow) {
        collected.add(chunk);
        if (collected.length > _maxErrorBodyBytes) overflow = true;
      }
    }
    var bytes = collected.takeBytes();
    if (bytes.length > _maxErrorBodyBytes) {
      bytes = Uint8List.fromList(bytes.sublist(0, _maxErrorBodyBytes));
    }
    return bytes;
  }

  Future<void> _pumpBody(_Head head, _BodyCtl ctl) async {
    final readAll = switch (head.shape) {
      _BodyShape.empty => Future<void>.value(),
      _BodyShape.length => _emitLength(head.contentLength, ctl, 'body'),
      _BodyShape.close => _emitClose(ctl),
      _BodyShape.chunked => _pumpChunked(ctl),
    };
    try {
      await readAll;
      // Return the connection to the pool before the consumer observes
      // stream-done: a keep-alive reuse must find it idle as soon as the
      // body bytes are fully read, otherwise a follow-up request opens a
      // second duplex needlessly.
      release(keepAlive: head.keepAlive);
      if (!ctl.controller.isClosed) await ctl.controller.close();
    } catch (e, st) {
      if (!ctl.controller.isClosed) {
        ctl.controller.addError(e, st);
        unawaited(ctl.controller.close());
      }
      _dead(e);
    }
  }

  Future<void> _emitClose(_BodyCtl ctl) async {
    while (await _fill()) {
      await ctl.emit(_takeAll());
    }
  }

  Future<void> _emitLength(int total, _BodyCtl ctl, String what) async {
    var remaining = total;
    while (remaining > 0) {
      if (!await _fill()) {
        throw DockerProtocolException('connection closed mid-$what');
      }
      final take = math.min(remaining, _available);
      await ctl.emit(_take(take));
      remaining -= take;
    }
  }

  Future<void> _pumpChunked(_BodyCtl ctl) async {
    while (true) {
      final line = await _readLine(_maxChunkSizeLineBytes, 'chunk size');
      if (line == null) {
        throw const DockerProtocolException(
          'connection closed inside a chunked body',
        );
      }
      final semi = line.indexOf(';');
      final size = int.tryParse(
        (semi >= 0 ? line.substring(0, semi) : line).trim(),
        radix: 16,
      );
      if (size == null || size < 0) {
        throw DockerProtocolException('malformed chunk size: $line');
      }
      if (size == 0) {
        // Trailer part: header-like lines, consumed and discarded.
        await _readHeaderBlock();
        return;
      }
      await _emitLength(size, ctl, 'chunked body');
      final crlf = await _readBytes(2);
      if (crlf == null || crlf[0] != 0x0D || crlf[1] != 0x0A) {
        throw const DockerProtocolException('missing CRLF after chunk');
      }
    }
  }

  /// Releases the connection after a fully consumed body.
  void release({required bool keepAlive}) {
    _busy = false;
    _bodyCtl = null;
    onIdle(this, keepAlive: keepAlive);
  }

  /// 03 §5.5: on 101 or 200 the raw duplex goes to the caller, buffered
  /// remainder first. The connection leaves the pool for good.
  HijackedDuplex hijack() {
    _retired = true;
    _busy = false;
    final ctl = StreamController<List<int>>(
      onPause: _sub.pause,
      onResume: _sub.resume,
      onCancel: () =>
          abort(const DockerCancelledException('hijacked stream cancelled')),
    );
    if (_available > 0) ctl.add(_takeAll());
    if (_readError != null) ctl.addError(_readError!);
    if (_eof) unawaited(ctl.close());
    _hijackCtl = ctl;
    return HijackedDuplex(
      _duplex.done,
      _duplex.closeWrite,
      () {
        unawaited(ctl.close());
        return _duplex.close();
      },
      stream: ctl.stream,
      sink: _duplex.sink,
    );
  }

  /// Closes the underlying duplex without an error (pool retirement).
  void dispose() {
    _retired = true;
    _busy = false;
    unawaited(_duplex.close());
  }

  /// Fatal path: the connection can no longer be trusted. Pending and
  /// in-flight reads surface [error].
  void abort(Object error) {
    _abortError ??= error;
    _retired = true;
    _busy = false;
    _bodyCtl?.wake();
    _bodyCtl = null;
    _wake();
    final h = _hijackCtl;
    if (h != null && !h.isClosed) {
      h.addError(error);
      unawaited(h.close());
    }
    unawaited(_duplex.close());
    onDead(this);
  }

  void _dead(Object error) {
    _abortError ??= error is DockerException
        ? error
        : DockerTransportException('connection failed', cause: error);
    _retired = true;
    _busy = false;
    _bodyCtl?.wake();
    _bodyCtl = null;
    unawaited(_duplex.close());
    onDead(this);
  }
}

/// The stream a body pump feeds. Pausing it pauses the duplex
/// subscription (03 §5.5 backpressure); cancelling it aborts the
/// connection, whose byte position is then unknowable.
final class _BodyCtl {
  _BodyCtl(this._conn) {
    controller = StreamController<List<int>>(
      onPause: () {
        _paused = true;
        _conn._sub.pause();
      },
      onResume: () {
        _paused = false;
        final c = _resumed;
        _resumed = null;
        if (c != null && !c.isCompleted) c.complete();
        _conn._sub.resume();
      },
      onCancel: () {
        if (identical(_conn._bodyCtl, this)) {
          _conn.abort(
            const DockerCancelledException('response body cancelled'),
          );
        }
      },
    );
  }

  final _Connection _conn;
  late final StreamController<List<int>> controller;
  bool _paused = false;
  Completer<void>? _resumed;

  /// Wakes an emit stalled on a pause so the connection's death path
  /// can finish (the emit loop then sees `!alive` and throws).
  void wake() {
    final c = _resumed;
    _resumed = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// Adds a chunk, then waits out a pause so buffers stay bounded.
  Future<void> emit(List<int> chunk) async {
    if (controller.isClosed) {
      throw const DockerCancelledException('response body closed');
    }
    controller.add(chunk);
    while (_paused && !_conn._broken) {
      _resumed ??= Completer<void>();
      await _resumed!.future;
    }
    // A clean EOF after the last bytes is not an error: the body reader
    // decides whether the body was truncated. Only a broken connection
    // aborts delivery here.
    if (_conn._broken) {
      final err = _conn._abortError ?? _conn._readError;
      throw err is DockerException
          ? err
          : DockerTransportException('connection lost', cause: err);
    }
  }
}
