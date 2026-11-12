import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'errors.dart';

/// Record separator used by `application/json-seq` (RFC 7464).
const int _rs = 0x1E;

/// The most bytes one line or JSON value of a streamed body may take.
/// An event, a stats sample or a pull progress record is a few KiB at
/// most; a peer that never ends one, such as a relay printing a banner
/// without a newline, fails the stream instead of growing memory.
@visibleForTesting
const int maxJsonStreamItemBytes = 1024 * 1024;

/// Pipes a byte stream through a transform with pause, resume and cancel
/// propagation so backpressure reaches the duplex subscription (03 §5.5).
Stream<R> _pipe<I, R>(
  Stream<I> source, {
  required void Function(I event, StreamSink<R> out) onData,
  void Function(StreamSink<R> out)? onDone,
}) {
  late StreamController<R> out;
  late StreamSubscription<I> sub;
  var started = false;
  out = StreamController<R>(
    onListen: () {
      if (started) return;
      started = true;
      sub = source.listen(
        (d) {
          try {
            onData(d, out);
          } on DockerProtocolException catch (e, st) {
            // The peer broke the format: end the stream with the error
            // and stop reading the body.
            out.addError(e, st);
            unawaited(sub.cancel());
            unawaited(out.close());
          }
        },
        onError: out.addError,
        onDone: () {
          onDone?.call(out);
          if (!out.isClosed) unawaited(out.close());
        },
      );
    },
    onPause: () {
      if (started) sub.pause();
    },
    onResume: () {
      if (started) sub.resume();
    },
    onCancel: () {
      if (started) unawaited(sub.cancel());
    },
  );
  return out.stream;
}

/// Splits a byte stream into text lines for the daemon's JSON stream
/// formats (03 §5.5 `lines`): NDJSON, `application/json-seq` (leading RS
/// stripped) and `application/jsonl`. Splitting happens at the byte
/// level, which is UTF-8 safe; each line is then decoded with malformed
/// bytes replaced. Empty lines are skipped. A line over
/// [maxJsonStreamItemBytes] ends the stream with a
/// [DockerProtocolException].
Stream<String> byteStreamToLines(Stream<List<int>> body) {
  final pending = <int>[];
  // How far [pending] is known to hold no newline, so a long line that
  // arrives in many chunks is scanned once.
  var scanned = 0;

  void emitLines(StreamSink<String> out, {required bool flush}) {
    var start = 0;
    for (var i = scanned; i < pending.length; i++) {
      if (pending[i] != 0x0A) continue;
      if (i - start > maxJsonStreamItemBytes) throw _tooLong('line');
      final line = _decodeLine(pending, start, i);
      if (line.isNotEmpty) out.add(line);
      start = i + 1;
    }
    if (start > 0) pending.removeRange(0, start);
    scanned = pending.length;
    if (pending.length > maxJsonStreamItemBytes) throw _tooLong('line');
    if (flush && pending.isNotEmpty) {
      final line = _decodeLine(pending, 0, pending.length);
      if (line.isNotEmpty) out.add(line);
      pending.clear();
    }
  }

  return _pipe<List<int>, String>(
    body,
    onData: (chunk, out) {
      pending.addAll(chunk);
      emitLines(out, flush: false);
    },
    onDone: (out) => emitLines(out, flush: true),
  );
}

DockerProtocolException _tooLong(String what) => DockerProtocolException(
  'a streamed $what exceeds $maxJsonStreamItemBytes bytes',
);

/// Decodes one raw line: leading RS bytes and a trailing CR are dropped
/// before UTF-8 decoding.
String _decodeLine(List<int> bytes, int start, int end) {
  while (start < end && bytes[start] == _rs) {
    start++;
  }
  if (end > start && bytes[end - 1] == 0x0D) end--;
  return utf8.decode(bytes.sublist(start, end), allowMalformed: true);
}

/// Scans a byte stream for concatenated JSON values without separators
/// (03 §5.5 `jsonValues`; pull progress in §5.6). Structure tracking is
/// byte-level and UTF-8 safe; each completed value is decoded. A value
/// over [maxJsonStreamItemBytes] ends the stream with a
/// [DockerProtocolException].
Stream<Object?> byteStreamToJsonValues(Stream<List<int>> body) {
  final scanner = _JsonValueScanner();

  void emit(Uint8List slice, StreamSink<Object?> out) {
    try {
      out.add(jsonDecode(utf8.decode(slice)));
    } catch (e) {
      out.addError(
        DockerProtocolException('malformed JSON value in stream', cause: e),
      );
      scanner.fail();
    }
  }

  return _pipe<List<int>, Object?>(
    body,
    onData: (chunk, out) {
      for (final slice in scanner.feed(chunk)) {
        emit(slice, out);
      }
    },
    onDone: (out) {
      final tail = scanner.end();
      if (tail == null) return;
      emit(tail, out);
    },
  );
}

/// Incremental scanner for concatenated JSON values. Whitespace and RS
/// bytes separate values; `{...}`, `[...]`, `"..."` and scalars each end
/// at their own boundary.
final class _JsonValueScanner {
  final BytesBuilder _value = BytesBuilder();
  var _inValue = false;
  var _scalar = false;
  var _inString = false;
  var _escape = false;
  var _depth = 0;
  var _failed = false;

  static bool _isWs(int b) =>
      b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == _rs;

  void fail() => _failed = true;

  List<Uint8List> feed(List<int> chunk) {
    final out = <Uint8List>[];
    if (_failed) return out;
    for (final b in chunk) {
      if (!_inValue) {
        if (_isWs(b)) continue;
        _begin(b);
        continue;
      }
      if (_scalar) {
        // A scalar ends at whitespace or at the next value's first byte.
        if (_isWs(b)) {
          _complete(out);
          continue;
        }
        if (b == 0x7B || b == 0x5B || b == 0x22) {
          _complete(out);
          _begin(b);
          continue;
        }
        _add(b);
        continue;
      }
      _add(b);
      if (_inString) {
        if (_escape) {
          _escape = false;
        } else if (b == 0x5C) {
          _escape = true;
        } else if (b == 0x22) {
          _inString = false;
          // A bare string value ends at its closing quote.
          if (_depth == 0) _complete(out);
        }
        continue;
      }
      if (b == 0x22) {
        _inString = true;
      } else if (b == 0x7B || b == 0x5B) {
        _depth++;
      } else if (b == 0x7D || b == 0x5D) {
        _depth--;
        if (_depth == 0) _complete(out);
      }
    }
    return out;
  }

  void _add(int b) {
    if (_value.length >= maxJsonStreamItemBytes) throw _tooLong('JSON value');
    _value.addByte(b);
  }

  void _begin(int b) {
    _inValue = true;
    _scalar = b != 0x7B && b != 0x5B && b != 0x22;
    _inString = b == 0x22;
    _depth = _scalar || _inString ? 0 : 1;
    _value.addByte(b);
  }

  void _complete(List<Uint8List> out) {
    out.add(_value.takeBytes());
    _inValue = false;
    _scalar = false;
    _inString = false;
    _escape = false;
    _depth = 0;
  }

  /// The leftover partial value at EOF, or null for pure whitespace.
  Uint8List? end() {
    if (_value.isEmpty) return null;
    return _value.takeBytes();
  }
}
