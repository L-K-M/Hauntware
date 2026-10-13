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
