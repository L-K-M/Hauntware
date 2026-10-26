import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// What a container's log line keeps besides its text (CTX-01): the
/// stream it came from and when the daemon received it, null when it
/// carried no timestamp.
@immutable
final class ContainerLine {
  const ContainerLine(this.stream, this.at);

  final ContainerLogStream stream;
  final DateTime? at;
}

/// One entry's [ContainerLine] packed into a small integer, so the table
/// beside the buffer costs one list slot an entry: the time in
/// microseconds, then a bit for a container line, one for a time and one
/// for the stream. Zero is any other entry.
extension type const _ContainerSlot(int bits) {
  _ContainerSlot.of(ContainerRecord record)
    : bits =
          (record.at?.microsecondsSinceEpoch ?? 0) << 3 |
          _container |
          (record.at == null ? 0 : _timed) |
          record.stream.index;

  static const _container = 4;
  static const _timed = 2;
  static const _stream = 1;

  static const none = _ContainerSlot(0);

  ContainerLine? get line {
    if (bits & _container == 0) return null;
    return ContainerLine(
      ContainerLogStream.values[bits & _stream],
      bits & _timed == 0
          ? null
          : DateTime.fromMicrosecondsSinceEpoch(bits >> 3, isUtc: true),
    );
  }
}

/// One log view's lines and follow state (03 §10.8, LOG-02). It owns the
/// view's [LogBuffer] and notifies its listeners after every change to the
/// lines; [following] notifies separately, so a panel's Live or Paused
/// chip does not rebuild on every batch.
///
/// The [LogView] showing it pauses following when the user scrolls away
/// from the newest line and follows again when they scroll back to it,
/// press End, or choose Follow.
///
/// Container lines (CTX-01) go into the buffer as text, as the buffer
/// keeps no stream or time; this controller keeps those beside it, one
/// small integer an entry from the first container line on, and drops
/// them as their entries leave. At the buffer's 50,000 entries that is
/// about 400 KiB besides the buffer's own budget (03 §11.4).
class LogViewController extends ChangeNotifier {
  LogViewController({LogBuffer? buffer}) : _buffer = buffer ?? LogBuffer();

  final LogBuffer _buffer;
  final _following = ValueNotifier(true);

  /// The [_ContainerSlot] of each entry from seq [_slotsFrom] on, kept in
  /// step with the buffer once a container line arrived.
  final _slots = ListQueue<_ContainerSlot>();
  int _slotsFrom = 0;

  /// The entries held, oldest first.
  int get length => _buffer.length;

  /// The [LogEntry.seq] of the oldest entry held (see [LogBuffer.firstSeq]).
  int get firstSeq => _buffer.firstSeq;

  /// The entry at [index], 0 being the oldest held.
  LogEntry operator [](int index) => _buffer[index];

  /// The stream and time of [line] when it is a container line held,
  /// otherwise null.
  ContainerLine? containerOf(LogLine line) {
    final index = line.seq - _slotsFrom;
    if (index < 0 || index >= _slots.length) return null;
    return _slots.elementAt(index).line;
  }

  /// Whether the view keeps the newest line in sight as lines arrive.
  ValueListenable<bool> get following => _following;

  /// Appends one batch; see [LogBuffer.add].
  void add(Iterable<String> lines, {int dropped = 0}) {
    final next = _nextSeq;
    _buffer.add(lines, dropped: dropped);
    _track(next, const []);
    notifyListeners();
  }

  /// Appends one batch of journal entries (LOG-01); see
  /// [LogBuffer.addJournal].
  void addJournal(Iterable<JournalEntry> entries, {int dropped = 0}) {
    final next = _nextSeq;
    _buffer.addJournal(entries, dropped: dropped);
    _track(next, const []);
    notifyListeners();
  }

  /// Appends one batch of container lines (CTX-01) as [add] appends
  /// lines, keeping each record's stream and time ([containerOf]).
  void addContainer(List<ContainerRecord> records, {int dropped = 0}) {
    final next = _nextSeq;
    _buffer.add([for (final record in records) record.text], dropped: dropped);
    _track(next, [for (final record in records) _ContainerSlot.of(record)]);
    notifyListeners();
  }

  /// Replaces every entry with [records], as [addContainer] appends them,
  /// keeping [following]: a merged view (CTX-04) that takes a line older
  /// than its newest rebuilds in time order without jumping to the end.
  void replaceContainer(List<ContainerRecord> records) {
    _buffer.clear();
    _slots.clear();
    addContainer(records);
  }

  /// Empties the view and follows again, since an empty view has no place
  /// to hold; see [LogBuffer.clear].
  void clear() {
    _buffer.clear();
    _slots.clear();
    _following.value = true;
    notifyListeners();
  }

  /// The seq the next entry gets: the buffer numbers its entries without
  /// gaps, so the oldest held is [firstSeq] and the rest follow it.
  int get _nextSeq => _buffer.firstSeq + _buffer.length;

  /// Keeps the table beside the buffer in step after an append that
  /// numbered entries from [next] on: a drop record first when one was
  /// added rather than merged, then the lines, [slots] for container
  /// lines. Entries the append evicted take their slots with them.
  void _track(int next, List<_ContainerSlot> slots) {
    if (_slots.isEmpty) {
      if (slots.isEmpty) return;
      _slotsFrom = next;
    }

    final added = _nextSeq - next;
    final drops = slots.isEmpty ? added : added - slots.length;
    for (var i = 0; i < drops; i++) {
      _slots.add(_ContainerSlot.none);
    }
    _slots.addAll(slots);
    while (_slots.isNotEmpty && _slotsFrom < _buffer.firstSeq) {
      _slots.removeFirst();
      _slotsFrom++;
    }
  }

  /// Keeps the newest line in sight from now on, scrolling to it.
  void follow() => _following.value = true;

  /// Leaves the view where it is while lines arrive.
  void pause() => _following.value = false;

  @override
  void dispose() {
    _following.dispose();
    super.dispose();
  }
}
