import 'dart:typed_data';

/// The bytes a wire parser has received and not yet consumed: chunks are
/// appended at the end and taken from the front.
///
/// Backed by one `Uint8List`, a byte per byte. A growable `List<int>`
/// holds a machine word per byte, so a stdcopy frame at its 8 MiB cap,
/// whose length the peer names, cost 64 MiB there.
///
/// ```
///   _bytes: [ consumed | unread ............ | free ]
///                      ^_start               ^_end
/// ```
///
/// Indexes are relative to the first unread byte.
final class ByteReadBuffer {
  Uint8List _bytes = _empty;
  int _start = 0;
  int _end = 0;

  static final Uint8List _empty = Uint8List(0);

  /// The smallest backing store allocated.
  static const int _minCapacity = 1024;

  /// A drained buffer larger than this is let go, so one large frame
  /// does not stay allocated for the rest of a long stream.
  static const int _keepCapacity = 64 * 1024;

  /// How many unread bytes are held.
  int get length => _end - _start;

  bool get isEmpty => _end == _start;
  bool get isNotEmpty => _end != _start;

  /// The unread byte at [index].
  int operator [](int index) {
    RangeError.checkValidIndex(index, this, 'index', length);
    return _bytes[_start + index];
  }

  /// Appends [chunk].
  void add(List<int> chunk) {
    final count = chunk.length;
    if (count == 0) return;
    _reserve(count);
    _bytes.setRange(_end, _end + count, chunk);
    _end += count;
  }

  /// The first index at or after [from] that holds [byte], or -1.
  int indexOf(int byte, [int from = 0]) {
    for (var i = _start + from; i < _end; i++) {
      if (_bytes[i] == byte) return i - _start;
    }
    return -1;
  }

  /// The first index at or after [from] where a CR LF pair starts, or -1.
  int indexOfCrlf([int from = 0]) {
    for (var i = _start + from; i + 1 < _end; i++) {
      if (_bytes[i] == 0x0D && _bytes[i + 1] == 0x0A) return i - _start;
    }
    return -1;
  }

  /// The unread bytes from [start] to [end] without copying them. The
  /// view is only good until the buffer is next added to or consumed.
  Uint8List view(int start, int end) {
    RangeError.checkValidRange(start, end, length);
    return Uint8List.sublistView(_bytes, _start + start, _start + end);
  }

  /// Removes the first [count] bytes and returns a copy of them.
  Uint8List take(int count) {
    final out = Uint8List.fromList(view(0, count));
    skip(count);
    return out;
  }

  /// Removes and returns every unread byte.
  Uint8List takeAll() => take(length);

  /// Removes the first [count] bytes.
  void skip(int count) {
    RangeError.checkValueInInterval(count, 0, length, 'count');
    _start += count;
    if (_start != _end) return;
    _start = _end = 0;
    if (_bytes.length > _keepCapacity) _bytes = _empty;
  }

  /// Removes everything.
  void clear() => skip(length);

  /// Makes room for [count] more bytes: the unread ones move to the
  /// front when that is enough, else into a store at least twice as
  /// large, so appending stays linear overall.
  void _reserve(int count) {
    if (_end + count <= _bytes.length) return;
    final unread = length;
    final needed = unread + count;
    if (needed <= _bytes.length && _start >= unread) {
      // Moving costs at most what was consumed since the last move.
      _bytes.setRange(0, unread, _bytes, _start);
    } else {
      var capacity = _bytes.length < _minCapacity
          ? _minCapacity
          : _bytes.length * 2;
      while (capacity < needed) {
        capacity *= 2;
      }
      _bytes = Uint8List(capacity)..setRange(0, unread, _bytes, _start);
    }
    _start = 0;
    _end = unread;
  }
}
