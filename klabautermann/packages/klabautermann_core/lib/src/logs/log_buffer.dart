import 'dart:collection';

import 'package:meta/meta.dart';

/// The most entries a [LogBuffer] holds by default (03 §10.8).
const int logBufferMaxLines = 50000;

/// The most text bytes a [LogBuffer] holds by default (03 §10.8), counted
/// as [logBytesPerCodeUnit] per UTF-16 code unit.
const int logBufferMaxBytes = 32 * 1024 * 1024;

/// The longest line a [LogBuffer] keeps whole by default (03 §10.8): 8,192
/// UTF-16 code units.
const int logLineMaxBytes = 16 * 1024;

/// Bytes a [LogBuffer] counts per UTF-16 code unit. A Dart string stores
/// one or two bytes per code unit, and which one the VM picks is not
/// visible to Dart code, so the buffer counts the larger: its byte cap then
/// bounds the text's memory whatever the VM stores, which the 64 MiB
/// viewer budget (03 §11.4) relies on.
const int logBytesPerCodeUnit = 2;

/// One entry of a [LogBuffer]: a [LogLine] or a [LogDroppedLines] record.
@immutable
sealed class LogEntry {
  const LogEntry(this.seq);

  /// The entry's place in its buffer's numbering, from 0 and never reused,
  /// so a view can keep its position while old entries leave.
  final int seq;
}

/// One log line as received, cut at the line cap if it was longer. [text]
/// still holds any ANSI escapes; the view styles it with `parseSgr`.
final class LogLine extends LogEntry {
  const LogLine(super.seq, this.text, {this.originalLength});

  final String text;

  /// The line's length in UTF-16 code units before the line cap cut it, or
  /// null when it was kept whole. The view shows the truncation marker for
  /// a cut line.
  final int? originalLength;

  bool get truncated => originalLength != null;
}

/// The "dropped N lines" record: [count] lines the engine discarded at
/// this point because the view fell behind (03 §5.6, LOG-02).
final class LogDroppedLines extends LogEntry {
  const LogDroppedLines(super.seq, this.count);

  final int count;
}

/// The log viewer's bounded line store (03 §10.8): a ring capped by entries
/// ([maxLines]) and text bytes ([maxBytes]), with each line cut at
/// [maxLineBytes]. Appending past a cap evicts the oldest entries, which is
/// ordinary scrollback loss and leaves no record; lines the engine dropped
/// before they arrived are recorded as [LogDroppedLines].
///
/// Bytes count only line text, at [logBytesPerCodeUnit] per code unit; a
/// drop record holds none but counts against [maxLines]. The per-entry
/// overhead is bounded by [maxLines] and covered by the memory budget
/// test. Plain Dart with no listeners: the controller that owns it
/// notifies the view.
final class LogBuffer {
  LogBuffer({
    this.maxLines = logBufferMaxLines,
    this.maxBytes = logBufferMaxBytes,
    this.maxLineBytes = logLineMaxBytes,
  }) : _maxLineCodeUnits = maxLineBytes ~/ logBytesPerCodeUnit {
    if (maxLines < 1) {
      throw ArgumentError.value(maxLines, 'maxLines', 'must be at least 1');
    }
    if (_maxLineCodeUnits < 1) {
      throw ArgumentError.value(
        maxLineBytes,
        'maxLineBytes',
        'must hold at least one code unit',
      );
    }
    if (maxLineBytes > maxBytes) {
      throw ArgumentError.value(
        maxLineBytes,
        'maxLineBytes',
        'must not exceed maxBytes ($maxBytes)',
      );
    }
  }

  final int maxLines;
  final int maxBytes;
  final int maxLineBytes;
  final int _maxLineCodeUnits;

  final _entries = ListQueue<LogEntry>();
  int _bytes = 0;
  int _nextSeq = 0;

  int get length => _entries.length;

  bool get isEmpty => _entries.isEmpty;

  /// The text bytes held, as counted against [maxBytes].
  int get bytes => _bytes;

  /// The [LogEntry.seq] of the oldest entry held; when the buffer is empty,
  /// the one the next entry gets. Entry `seq` sits at index
  /// `seq - firstSeq`.
  int get firstSeq => _entries.isEmpty ? _nextSeq : _entries.first.seq;

  /// The entry at [index], 0 being the oldest held.
  LogEntry operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', _entries.length);
    return _entries.elementAt(index);
  }

  /// Appends one `LogBatch`: a [LogDroppedLines] record for [dropped] lines
  /// first, merged into the newest entry when that is a drop record too,
  /// then [lines], each cut at the line cap. [lines] are already split;
  /// a line's newlines and other controls are dropped when it is styled.
  void add(Iterable<String> lines, {int dropped = 0}) {
    RangeError.checkNotNegative(dropped, 'dropped');

    if (dropped > 0) _addDropped(dropped);
    for (final line in lines) {
      _addLine(line);
    }
  }

  /// Empties the buffer; numbering continues where it stood.
  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  void _addDropped(int count) {
    if (_entries.isNotEmpty && _entries.last is LogDroppedLines) {
      final last = _entries.removeLast() as LogDroppedLines;
      _entries.addLast(LogDroppedLines(last.seq, last.count + count));
      return;
    }

    _append(LogDroppedLines(_nextSeq++, count), 0);
  }

  void _addLine(String line) {
    final entry = line.length <= _maxLineCodeUnits
        ? LogLine(_nextSeq++, line)
        : LogLine(
            _nextSeq++,
            line.substring(0, _cutIndex(line)),
            originalLength: line.length,
          );
    _append(entry, entry.text.length * logBytesPerCodeUnit);
  }

  /// Where a line longer than the cap is cut: at the cap, or one unit
  /// earlier rather than keep half of a surrogate pair.
  int _cutIndex(String line) {
    final cut = _maxLineCodeUnits;
    final last = line.codeUnitAt(cut - 1);
    final splitsPair = last >= 0xd800 && last <= 0xdbff;
    return splitsPair ? cut - 1 : cut;
  }

  void _append(LogEntry entry, int bytes) {
    _entries.addLast(entry);
    _bytes += bytes;
    while (_entries.length > maxLines || _bytes > maxBytes) {
      final evicted = _entries.removeFirst();
      if (evicted is LogLine) {
        _bytes -= evicted.text.length * logBytesPerCodeUnit;
      }
    }
  }
}
