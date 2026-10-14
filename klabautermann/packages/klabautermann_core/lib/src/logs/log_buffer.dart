import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:klabautermann_host/klabautermann_host.dart' show JournalEntry;
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
  const LogLine(super.seq, this.text, {this.originalLength, this.journal});

  /// The line, or a journal entry's MESSAGE.
  final String text;

  /// The line's length in UTF-16 code units before the line cap cut it, or
  /// null when it was kept whole. The view shows the truncation marker for
  /// a cut line.
  final int? originalLength;

  bool get truncated => originalLength != null;

  /// The other fields of a journal entry ([LogBuffer.addJournal]), or null
  /// for a plain line.
  final JournalFields? journal;
}

/// What a journal line keeps besides its MESSAGE, which is its
/// [LogLine.text] (LOG-01, 03 §10.8): the columns its row shows, and every
/// other field encoded once as UTF-8 JSON, so an entry costs a few objects
/// however many fields it has and the byte cap counts what it holds.
@immutable
final class JournalFields {
  const JournalFields._({
    required this.priority,
    required this.source,
    required this.pid,
    required this.messageNotSent,
    required this.fieldsLeftOut,
    required this._encoded,
  });

  /// `PRIORITY`, the syslog severity 0 to 7, when it parsed.
  final int? priority;

  /// The entry's unit ([JournalEntry.unit]) or, without one, its
  /// `SYSLOG_IDENTIFIER` (`kernel` for the kernel's lines).
  final String? source;

  /// `_PID`, when it parsed.
  final int? pid;

  /// Whether MESSAGE arrived as JSON null: `journalctl -o json` sends a
  /// field larger than 4,096 bytes as null unless it runs with `--all`.
  final bool messageNotSent;

  /// The fields left out of [fields] because they would have passed the
  /// line cap.
  final int fieldsLeftOut;

  final Uint8List _encoded;

  /// Every field kept but MESSAGE, in the order received, decoded on each
  /// call. A null value is one journalctl sent as null.
  List<(String, String?)> get fields {
    if (_encoded.isEmpty) return const [];

    final decoded = jsonDecode(utf8.decode(_encoded)) as Map<String, Object?>;
    return [
      for (final MapEntry(:key, :value) in decoded.entries)
        (key, value as String?),
    ];
  }

  int get _bytes =>
      _encoded.length + (source == null ? 0 : LogBuffer._byteLength(source!));
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
/// Bytes count line text as the Dart VM stores it: one byte a code
/// unit for a line whose units are all Latin-1, two otherwise. Dart code
/// cannot see that representation, but the VM picks the one-byte form
/// whenever every unit fits, whether a string is decoded, split or cut, so
/// the byte cap bounds the text's memory for the 64 MiB viewer budget
/// (03 §11.4); the memory budget test checks both kinds. A journal line
/// also counts its source and its encoded fields ([JournalFields]), and
/// the same test fills a buffer with journal lines. A drop record holds
/// no bytes but counts against [maxLines]. The per-entry overhead is
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

  /// Appends one batch of journal entries as [add] appends lines: each
  /// entry's MESSAGE becomes a line's text, cut at the line cap, and its
  /// other fields the line's [LogLine.journal]. Those count against
  /// [maxBytes] too, within the line cap: fields that would pass it are
  /// left out and counted, so an entry fits however many fields it has.
  void addJournal(Iterable<JournalEntry> entries, {int dropped = 0}) {
    RangeError.checkNotNegative(dropped, 'dropped');

    if (dropped > 0) _addDropped(dropped);
    for (final entry in entries) {
      _addJournal(entry);
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

    _entries.addLast(LogDroppedLines(_nextSeq++, count));
    _evict();
  }

  void _addLine(String line) {
    final text = _fit(line, maxLineBytes);
    _append(
      LogLine(
        _nextSeq++,
        text,
        originalLength: text.length < line.length ? line.length : null,
      ),
    );
  }

  void _addJournal(JournalEntry entry) {
    final message = entry.fields['MESSAGE'];
    final text = _fit(message ?? '', maxLineBytes);
    final textBytes = _byteLength(text);

    // The source and the fields share what the text leaves of the line
    // cap, so an entry never needs more than the byte cap.
    var room = math.min(maxLineBytes, maxBytes - textBytes);
    final kept = _fit(entry.unit ?? entry.identifier ?? '', room);
    final source = kept.isEmpty ? null : kept;
    room -= _byteLength(kept);

    // {"name":value,...}: the braces, and a comma or brace after each.
    final encoded = BytesBuilder(copy: false);
    var size = 1;
    var leftOut = 0;
    for (final MapEntry(:key, :value) in entry.fields.entries) {
      if (key == 'MESSAGE') continue;

      final field = utf8.encode('${jsonEncode(key)}:${jsonEncode(value)}');
      if (size + field.length + 1 > room) {
        leftOut++;
        continue;
      }
      encoded.addByte(size == 1 ? 0x7b : 0x2c); // { or ,
      encoded.add(field);
      size += field.length + 1;
    }
    if (size > 1) encoded.addByte(0x7d); // }

    _append(
      LogLine(
        _nextSeq++,
        text,
        originalLength: text.length < (message?.length ?? 0)
            ? message!.length
            : null,
        journal: JournalFields._(
          priority: entry.priority,
          source: source,
          pid: entry.pid,
          messageNotSent:
              entry.fields.containsKey('MESSAGE') && message == null,
          fieldsLeftOut: leftOut,
          encoded: encoded.takeBytes(),
        ),
      ),
    );
  }

  /// [text] whole when it takes at most [limit] bytes; otherwise cut after
  /// [limit] units when those are all Latin-1, else after half as many, or
  /// one unit earlier rather than keep half of a surrogate pair.
  static String _fit(String text, int limit) {
    if (_byteLength(text) <= limit) return text;

    final oneByte = text.length >= limit && _isOneByte(text, limit);
    final cut = oneByte ? limit : limit ~/ 2;
    if (cut == 0) return '';
    final last = text.codeUnitAt(cut - 1);
    final splitsPair = last >= 0xd800 && last <= 0xdbff;
    return text.substring(0, splitsPair ? cut - 1 : cut);
  }

  void _append(LogLine line) {
    _entries.addLast(line);
    _bytes += _lineBytes(line);
    _evict();
  }

  void _evict() {
    while (_entries.length > maxLines || _bytes > maxBytes) {
      final evicted = _entries.removeFirst();
      if (evicted is LogLine) _bytes -= _lineBytes(evicted);
    }
  }

  static int _lineBytes(LogLine line) =>
      _byteLength(line.text) + (line.journal?._bytes ?? 0);

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
