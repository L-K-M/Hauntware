/// The length of [text] encoded as UTF-8, counted without encoding it. An
/// unpaired surrogate counts 3 bytes, as `utf8.encode` writes it as U+FFFD.
int utf8EncodedLength(String text) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (_isLeadSurrogate(unit) &&
        i + 1 < text.length &&
        _isTrailSurrogate(text.codeUnitAt(i + 1))) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}

bool _isLeadSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

bool _isTrailSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

/// Offsets at which logical lines begin: 0 plus the position after each
/// `\n`. A trailing newline therefore still counts its empty final line.
List<int> lineStartOffsets(String text) {
  final starts = <int>[0];
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0a) starts.add(i + 1);
  }
  return starts;
}
