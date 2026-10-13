import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'api_version.dart';
import 'errors.dart';

/// 03 §5.6: cap on one multiplexed frame's payload.
const int defaultMaxStdcopyFrameBytes = 8 * 1024 * 1024;

/// 03 §5.6: cap on one log line, in characters. Overlong lines are hard
/// split so memory stays bounded.
const int defaultMaxLogLineChars = 128 * 1024;

/// 03 §5.6: the bounded ring's defaults, kept under the 64 MiB viewer
/// budget of 03 §11.4.
const int defaultLogRingLines = 2000;
const int defaultLogRingChars = 16 * 1024 * 1024;

/// The multiplexed-stream `Content-Type` values the daemon sends from
/// API 1.42 (03 §5.6).
const String contentTypeMultiplexed =
    'application/vnd.docker.multiplexed-stream';
const String contentTypeRawStream = 'application/vnd.docker.raw-stream';

/// The stdcopy stream type byte (03 §5.6).
enum StdcopyKind {
  stdin(0),
  stdout(1),
  stderr(2),
  systemerr(3);

  const StdcopyKind(this.code);
  final int code;

  static StdcopyKind? fromCode(int code) {
    for (final k in values) {
      if (k.code == code) return k;
    }
    return null;
  }
}

/// One demultiplexed frame: an 8-byte header (stream type plus
/// big-endian length) and its payload.
final class StdcopyFrame {
  const StdcopyFrame(this.stream, this.bytes);

  final StdcopyKind stream;
  final Uint8List bytes;
}

/// Demultiplexes a raw byte stream into stdcopy frames (03 §5.6). The
/// frame header is 8 bytes: type, 3 unused, 4-byte big-endian length.
/// Robust to any input split; an oversized or untyped frame and a
/// truncated tail are protocol errors.
Stream<StdcopyFrame> demuxStdcopy(
  Stream<List<int>> input, {
  int maxFrameBytes = defaultMaxStdcopyFrameBytes,
}) async* {
  final buf = <int>[];
  var pos = 0;
  await for (final chunk in input) {
    buf.addAll(chunk);
    while (buf.length - pos >= 8) {
      final kindCode = buf[pos];
      final kind = StdcopyKind.fromCode(kindCode);
      if (kind == null) {
        throw DockerProtocolException('invalid stdcopy stream type $kindCode');
      }
      final len =
          (buf[pos + 4] << 24) |
          (buf[pos + 5] << 16) |
          (buf[pos + 6] << 8) |
          buf[pos + 7];
      if (len > maxFrameBytes) {
        throw DockerProtocolException(
          'stdcopy frame of $len bytes exceeds the $maxFrameBytes byte cap',
        );
      }
      if (buf.length - pos < 8 + len) break;
      yield StdcopyFrame(
        kind,
        Uint8List.fromList(buf.sublist(pos + 8, pos + 8 + len)),
      );
      pos += 8 + len;
    }
    if (pos > 64 * 1024 && pos * 2 > buf.length) {
      buf.removeRange(0, pos);
      pos = 0;
    }
  }
  if (buf.length - pos != 0) {
    throw const DockerProtocolException('truncated stdcopy frame');
  }
}

/// Adapts a raw (unmultiplexed) log stream to frames so the same line
/// pipeline serves both shapes (03 §5.6).
Stream<StdcopyFrame> rawLogFrames(Stream<List<int>> input) =>
    input.map((c) => StdcopyFrame(StdcopyKind.stdout, Uint8List.fromList(c)));

/// How log bytes are framed on the wire (03 §5.6).
enum LogFraming { multiplexed, raw }

/// The outcome of the framing choice, plus a warning when the signals
/// disagree.
final class LogFramingChoice {
  const LogFramingChoice(this.framing, [this.warning]);

  final LogFraming framing;
  final String? warning;
}

/// Picks the wire framing for a logs or attach response (03 §5.6): from
/// API 1.42 the `Content-Type` header is used when present and
/// cross-checked with `Config.Tty`; below 1.42 `Config.Tty` decides.
LogFramingChoice resolveLogFraming({
  required ApiVersion negotiated,
  required bool tty,
  String? contentType,
}) {
  if (negotiated < apiVersionLogsContentType) {
    return LogFramingChoice(tty ? LogFraming.raw : LogFraming.multiplexed);
  }
  if (contentType == null) {
    return LogFramingChoice(
      tty ? LogFraming.raw : LogFraming.multiplexed,
      'no Content-Type on a >= 1.42 logs response; fell back to '
      'Config.Tty',
    );
  }
  final ct = contentType.split(';').first.trim().toLowerCase();
  switch (ct) {
    case contentTypeMultiplexed:
      return LogFramingChoice(
        LogFraming.multiplexed,
        tty ? 'multiplexed-stream Content-Type contradicts Config.Tty' : null,
      );
    case contentTypeRawStream:
      return LogFramingChoice(
        LogFraming.raw,
        tty ? null : 'raw-stream Content-Type contradicts Config.Tty',
      );
    default:
      return LogFramingChoice(
        tty ? LogFraming.raw : LogFraming.multiplexed,
        'unknown Content-Type $contentType on a logs response; fell back '
        'to Config.Tty',
      );
  }
}

/// One log line after demultiplexing (03 §5.6).
final class LogLine {
  const LogLine(this.stream, this.text);

  /// The stdcopy stream the line came from (`stdout` for raw streams).
  final StdcopyKind stream;
  final String text;
}

/// Splits demultiplexed frames into lines (03 §5.6): UTF-8 decoded
/// incrementally so multibyte characters survive frame splits, `\r\n`
/// endings normalized, lines hard split at [maxLineChars].
Stream<LogLine> splitLogLines(
  Stream<StdcopyFrame> frames, {
  int maxLineChars = defaultMaxLogLineChars,
}) async* {
  final states = <StdcopyKind, _LineState>{};

  await for (final frame in frames) {
    final state = states.putIfAbsent(frame.stream, _LineState.new);
    for (final line in state.feed(frame.bytes, maxLineChars)) {
      yield LogLine(frame.stream, line);
    }
  }
  for (final e in states.entries) {
    for (final line in e.value.flush()) {
      yield LogLine(e.key, line);
    }
  }
}

/// The bounded ring behind a log view (03 §5.6): when the consumer falls
/// behind, the oldest lines drop and [dropped] reports "dropped N lines".
/// Bounded by line count and by characters.
final class BoundedLogRing {
  BoundedLogRing({
    this.maxLines = defaultLogRingLines,
    this.maxChars = defaultLogRingChars,
  });

  final int maxLines;
  final int maxChars;

  final Queue<LogLine> _lines = Queue<LogLine>();
  int _chars = 0;
  int _dropped = 0;

  /// Lines dropped so far because the ring was full.
  int get dropped => _dropped;

  /// The view label of 03 §5.6: "dropped N lines".
  String get droppedLabel => 'dropped $dropped lines';

  int get length => _lines.length;

  List<LogLine> toList() => List<LogLine>.of(_lines);

  void add(LogLine line) {
    _lines.add(line);
    _chars += line.text.length;
    while (_lines.length > maxLines || _chars > maxChars) {
      _chars -= _lines.removeFirst().text.length;
      _dropped++;
    }
  }

  void addAll(Iterable<LogLine> lines) {
    for (final l in lines) {
      add(l);
    }
  }

  void clear() {
    _lines.clear();
    _chars = 0;
  }
}

/// Per-stream decode and split state: an incremental UTF-8 sink plus the
/// pending partial line.
final class _LineState {
  _LineState() {
    // Malformed bytes are replaced, matching byteStreamToLines: one bad
    // sequence must not kill a whole log stream. `fromStringSink` forwards
    // each decoded chunk immediately; `withCallback` buffers until close
    // and would defeat incremental line splitting.
    _sink = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(StringConversionSink.fromStringSink(_pending));
  }

  late final ByteConversionSink _sink;
  final StringBuffer _pending = StringBuffer();

  Iterable<String> feed(Uint8List bytes, int maxLineChars) sync* {
    _sink.add(bytes);
    yield* _drain(maxLineChars);
  }

  Iterable<String> flush() sync* {
    _sink.close();
    if (_pending.isNotEmpty) {
      yield _take(_pending.length);
    }
  }

  Iterable<String> _drain(int maxLineChars) sync* {
    while (true) {
      final text = _pending.toString();
      final nl = text.indexOf('\n');
      if (nl < 0) {
        if (text.length >= maxLineChars) {
          // Hard split keeps memory bounded on overlong lines.
          yield _take(maxLineChars);
          continue;
        }
        return;
      }
      if (nl > maxLineChars) {
        // Same hard split; the \n stays queued.
        yield _take(maxLineChars);
        continue;
      }
      final line = text.substring(
        0,
        nl > 0 && text[nl - 1] == '\r' ? nl - 1 : nl,
      );
      _take(nl + 1);
      yield line;
    }
  }

  String _take(int n) {
    final s = _pending.toString();
    _pending
      ..clear()
      ..write(s.substring(n));
    return s.substring(0, n);
  }
}
