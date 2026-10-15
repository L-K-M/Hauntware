import 'dart:collection';

import 'package:meta/meta.dart';

/// The most entries a [LogBuffer] holds by default (03 §10.8).
const int logBufferMaxLines = 50000;

/// The most text bytes a [LogBuffer] holds by default (03 §10.8), counted
/// as the VM stores the text (see [LogBuffer]).
const int logBufferMaxBytes = 32 * 1024 * 1024;

/// The longest line a [LogBuffer] keeps whole by default (03 §10.8):
/// 16,384 Latin-1 or 8,192 other UTF-16 code units.
const int logLineMaxBytes = 16 * 1024;

/// The highest code unit the VM's one-byte strings hold: Latin-1, so all
/// ASCII.
const int _maxOneByteUnit = 0xff;

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
/// Bytes count only line text, as the Dart VM stores it: one byte a code
/// unit for a line whose units are all Latin-1, two otherwise. Dart code
/// cannot see that representation, but the VM picks the one-byte form
/// whenever every unit fits, whether a string is decoded, split or cut, so
/// the byte cap bounds the text's memory for the 64 MiB viewer budget
/// (03 §11.4); the memory budget test checks both kinds. A drop record
/// holds no bytes but counts against [maxLines]. The per-entry overhead is
/// bounded by [maxLines] and covered by the same test. Plain Dart with no
/// listeners: the controller that owns it notifies the view.
final class LogBuffer {
  LogBuffer({
    this.maxLines = logBufferMaxLines,
    this.maxBytes = logBufferMaxBytes,
    this.maxLineBytes = logLineMaxBytes,
  }) {
    if (maxLines < 1) {
      throw ArgumentError.value(maxLines, 'maxLines', 'must be at least 1');
    }
    if (maxLineBytes < 2) {
      throw ArgumentError.value(
        maxLineBytes,
        'maxLineBytes',
        'must hold one two-byte code unit',
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

  /// Appends one batch, such as a `LogBatch`'s records as text: a
  /// [LogDroppedLines] record for [dropped] lines first, merged into the
  /// newest entry when that is a drop record too, then [lines], each cut
  /// at the line cap. [lines] are already split; a line's newlines and
  /// other controls are dropped when it is styled.
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
    final bytes = _byteLength(line);
    if (bytes <= maxLineBytes) {
      _append(LogLine(_nextSeq++, line), bytes);
      return;
    }

    final text = line.substring(0, _cutIndex(line));
    _append(
      LogLine(_nextSeq++, text, originalLength: line.length),
      _byteLength(text),
    );
  }

  /// Where a line longer than the cap is cut: after [maxLineBytes] units
  /// when those are all Latin-1, else after half as many, or one unit
  /// earlier rather than keep half of a surrogate pair.
  int _cutIndex(String line) {
    final oneByte =
        line.length >= maxLineBytes && _isOneByte(line, maxLineBytes);
    final cut = oneByte ? maxLineBytes : maxLineBytes ~/ 2;
    final last = line.codeUnitAt(cut - 1);
    final splitsPair = last >= 0xd800 && last <= 0xdbff;
    return splitsPair ? cut - 1 : cut;
  }

  void _append(LogEntry entry, int bytes) {
    _entries.addLast(entry);
    _bytes += bytes;
    while (_entries.length > maxLines || _bytes > maxBytes) {
      final evicted = _entries.removeFirst();
      if (evicted is LogLine) _bytes -= _byteLength(evicted.text);
    }
  }

  static int _byteLength(String text) =>
      _isOneByte(text, text.length) ? text.length : 2 * text.length;

  /// Whether the first [end] code units of [text] are all Latin-1.
  static bool _isOneByte(String text, int end) {
    for (var i = 0; i < end; i++) {
      if (text.codeUnitAt(i) > _maxOneByteUnit) return false;
    }
    return true;
  }
}
