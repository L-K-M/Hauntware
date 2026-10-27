import 'package:klabautermann_core/klabautermann_core.dart'
    show LogLine, continuesLine, jsonLineFields, linePriority, parseSgr;

import 'log_level.dart';
import 'log_view_controller.dart';

/// How far back a stack trace's continuation looks for the line that
/// opened it.
const _continuationReach = 200;

/// How many lines' readings a [ContainerLineReader] keeps.
const _cacheMax = 4096;

/// CTX-05's reading of container log lines for the log view, over
/// [linePriority], [continuesLine] and [jsonLineFields]: each line's
/// level from what it says of itself, a stack trace's continuation lines
/// taking the level of the line that opened it, so the trace reads as
/// one, and a JSON object line's keys as fields a tap shows beneath it.
///
/// A line's reading is kept by seq, which [LogViewController] never
/// reuses; [skipWords] leaves out words a view puts before a line, as a
/// stack's logs put the container's name.
final class ContainerLineReader {
  ContainerLineReader(this._logs, {this.skipWords = 0});

  final LogViewController _logs;
  final int skipWords;

  final _levels = <int, LogLevel?>{};
  final _fields = <int, List<(String, String?)>?>{};

  /// [line]'s level, or for a continuation line the level of the line
  /// that opened its trace; null when it names none.
  LogLevel? levelOf(LogLine line) {
    if (_levels.containsKey(line.seq)) return _levels[line.seq];
    if (_levels.length > _cacheMax) _levels.clear();

    final text = _ownText(line);
    var level = switch (linePriority(text)) {
      final priority? => LogLevel.fromSyslogPriority(priority.index),
      null => null,
    };
    if (level == null && continuesLine(text)) level = _openerLevel(line);
    return _levels[line.seq] = level;
  }

  /// [line]'s keys when it is a JSON object; null for any other line.
  List<(String, String?)>? fieldsOf(LogLine line) {
    if (_fields.containsKey(line.seq)) return _fields[line.seq];
    if (_fields.length > _cacheMax) _fields.clear();

    return _fields[line.seq] = jsonLineFields(_ownText(line));
  }

  String _ownText(LogLine line) {
    var text = parseSgr(line.text).text;
    for (var i = 0; i < skipWords; i++) {
      final space = text.indexOf(' ');
      text = space < 0
          ? text.substring(text.length)
          : text.substring(space + 1);
    }
    return text;
  }

  LogLevel? _openerLevel(LogLine line) {
    final index = line.seq - _logs.firstSeq;
    for (var i = index - 1; i >= 0 && i >= index - _continuationReach; i--) {
      final entry = _logs[i];
      if (entry is! LogLine) return null;
      if (!continuesLine(_ownText(entry))) return levelOf(entry);
    }
    return null;
  }
}
