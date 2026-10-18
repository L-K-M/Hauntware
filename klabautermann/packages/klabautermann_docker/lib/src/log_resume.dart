import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'docker_parse_result.dart';
import 'log_time.dart';
import 'stdcopy.dart';

/// A log line with its RFC3339Nano timestamp split off (03 §5.6). The
/// timestamp is present when the request set `timestamps=1`.
@immutable
final class TimestampedLogLine {
  const TimestampedLogLine({
    this.timestamp,
    required this.message,
    required this.stream,
  });

  final LogTimestamp? timestamp;
  final String message;
  final StdcopyKind stream;
}

/// Splits the leading RFC3339Nano timestamp off one line. When
/// `timestamps=0` the line has none and the whole text is the message.
DockerParseResult<TimestampedLogLine> parseTimestampedLogLine(LogLine line) {
  final text = line.text;
  final space = text.indexOf(' ');
  if (space > 0) {
    final ts = LogTimestamp.tryParse(text.substring(0, space));
    if (ts != null) {
      return DockerParseResult(
        TimestampedLogLine(
          timestamp: ts,
          message: text.substring(space + 1),
          stream: line.stream,
        ),
      );
    }
  }
  return DockerParseResult(
    TimestampedLogLine(timestamp: null, message: text, stream: line.stream),
  );
}

/// Maps a line stream through [parseTimestampedLogLine].
Stream<TimestampedLogLine> parseTimestampedLogLines(Stream<LogLine> lines) =>
    lines.map((l) => parseTimestampedLogLine(l).value);

/// 03 §5.6: `since` is inclusive, so a resumed stream re-sends the line at
/// the last delivered timestamp. Drops the leading run of lines whose
/// timestamp is less than or equal to [since]. A line without a timestamp
/// cannot be compared, so it ends the drop and is delivered.
Stream<TimestampedLogLine> dropInclusiveSince(
  Stream<TimestampedLogLine> lines,
  LogTimestamp since,
) async* {
  var dropping = true;
  await for (final line in lines) {
    if (dropping) {
      final ts = line.timestamp;
      if (ts != null && ts <= since) continue;
      dropping = false;
    }
    yield line;
  }
}

/// The newest timestamp in [lines], for the next `since=` resume value
/// (03 §5.6).
LogTimestamp? lastDeliveredTimestamp(Iterable<TimestampedLogLine> lines) {
  LogTimestamp? last;
  for (final line in lines) {
    final ts = line.timestamp;
    if (ts == null) continue;
    if (last == null || ts > last) last = ts;
  }
  return last;
}

/// [dropInclusiveSince] over raw [LogLine]s whose text still carries the
/// RFC3339Nano timestamp, for callers that want the original lines back.
Stream<LogLine> dropInclusiveSinceLines(
  Stream<LogLine> lines,
  LogTimestamp since,
) async* {
  var dropping = true;
  await for (final line in lines) {
    if (dropping) {
      final ts = parseTimestampedLogLine(line).value.timestamp;
      if (ts != null && ts <= since) continue;
      dropping = false;
    }
    yield line;
  }
}

/// Joins the demultiplexed frames of a `timestamps=1` logs response into
/// timestamped lines (03 §5.6), each cut to [maxLineBytes] (the rest of
/// an overlong line is discarded), without its `\n` or `\r\n`.
///
/// With [LogFraming.multiplexed] each frame is one log message, which
/// the daemon prefixes with its own timestamp. A message without a
/// trailing `\n` leaves its line open, and the next frame of the same
/// stream continues it after dropping that frame's timestamp: Podman
/// splits a line so during a follow (`TS stdout lin`, then `TS e 520\n`),
/// and Docker a message over 16 KiB. The joined line keeps the first
/// timestamp. A raw (TTY) stream is one byte stream, cut wherever the
/// transport cut it, so only `\n` ends its lines and nothing is dropped.
Stream<TimestampedLogLine> joinTimestampedLogLines(
  Stream<StdcopyFrame> frames, {
  required LogFraming framing,
  int maxLineBytes = defaultMaxLogLineChars,
}) async* {
  final open = <StdcopyKind, _OpenLine>{};
  await for (final frame in frames) {
    final line = open.putIfAbsent(frame.stream, () => _OpenLine(maxLineBytes));
    final bytes = frame.bytes;
    var start = framing == LogFraming.multiplexed && line.isNotEmpty
        ? _afterTimestamp(bytes)
        : 0;
    while (true) {
      final newline = bytes.indexOf(_newline, start);
      line.add(bytes, start, newline < 0 ? bytes.length : newline);
      if (newline < 0) break;
      yield _timestamped(line.take(), frame.stream);
      start = newline + 1;
    }
  }
  for (final MapEntry(key: stream, value: line) in open.entries) {
    if (line.isNotEmpty) yield _timestamped(line.take(), stream);
  }
}

const _newline = 0x0a;
const _space = 0x20;

/// The longest RFC3339Nano timestamp with an offset, and a little more.
const _timestampMaxBytes = 40;

/// Where [bytes] continue after a leading timestamp and its space; 0
/// without one.
int _afterTimestamp(Uint8List bytes) {
  final limit = bytes.length < _timestampMaxBytes
      ? bytes.length
      : _timestampMaxBytes;
  for (var i = 0; i < limit; i++) {
    if (bytes[i] != _space) continue;
    final text = latin1.decode(Uint8List.sublistView(bytes, 0, i));
    return LogTimestamp.tryParse(text) == null ? 0 : i + 1;
  }
  return 0;
}

TimestampedLogLine _timestamped(Uint8List bytes, StdcopyKind stream) {
  var text = utf8.decode(bytes, allowMalformed: true);
  if (text.endsWith('\r')) text = text.substring(0, text.length - 1);
  return parseTimestampedLogLine(LogLine(stream, text)).value;
}

/// One stream's line in progress, at most its cap.
final class _OpenLine {
  _OpenLine(this._maxBytes);

  final int _maxBytes;
  final _bytes = BytesBuilder();

  bool get isNotEmpty => _bytes.isNotEmpty;

  void add(Uint8List chunk, int start, int end) {
    final room = _maxBytes - _bytes.length;
    final stop = end - start > room ? start + room : end;
    if (stop > start) _bytes.add(Uint8List.sublistView(chunk, start, stop));
  }

  Uint8List take() => _bytes.takeBytes();
}
