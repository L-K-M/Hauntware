import 'package:flutter/foundation.dart';
import 'package:klabautermann_core/klabautermann_core.dart';

/// One log view's lines and follow state (03 §10.8, LOG-02). It owns the
/// view's [LogBuffer] and notifies its listeners after every change to the
/// lines; [following] notifies separately, so a panel's Live or Paused
/// chip does not rebuild on every batch.
///
/// The [LogView] showing it pauses following when the user scrolls away
/// from the newest line and follows again when they scroll back to it,
/// press End, or choose Follow.
class LogViewController extends ChangeNotifier {
  LogViewController({LogBuffer? buffer}) : _buffer = buffer ?? LogBuffer();

  final LogBuffer _buffer;
  final _following = ValueNotifier(true);

  /// The entries held, oldest first.
  int get length => _buffer.length;

  /// The [LogEntry.seq] of the oldest entry held (see [LogBuffer.firstSeq]).
  int get firstSeq => _buffer.firstSeq;

  /// The entry at [index], 0 being the oldest held.
  LogEntry operator [](int index) => _buffer[index];

  /// Whether the view keeps the newest line in sight as lines arrive.
  ValueListenable<bool> get following => _following;

  /// Appends one batch; see [LogBuffer.add].
  void add(Iterable<String> lines, {int dropped = 0}) {
    _buffer.add(lines, dropped: dropped);
    notifyListeners();
  }

  /// Appends one batch of journal entries (LOG-01); see
  /// [LogBuffer.addJournal].
  void addJournal(Iterable<JournalEntry> entries, {int dropped = 0}) {
    _buffer.addJournal(entries, dropped: dropped);
    notifyListeners();
  }

  /// Empties the view and follows again, since an empty view has no place
  /// to hold; see [LogBuffer.clear].
  void clear() {
    _buffer.clear();
    _following.value = true;
    notifyListeners();
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
