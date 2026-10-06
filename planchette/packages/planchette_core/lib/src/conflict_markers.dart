part of 'text_validation.dart';

/// Git writes its conflict markers this many characters long.
const _conflictMarkerLength = 7;

/// Flags each conflict a merge left behind: a `<<<<<<<` line, then
/// `=======`, then `>>>>>>>`, each at the start of a line, with diff3's
/// `|||||||` section allowed between the first two. Only the opening marker
/// is underlined, so one conflict is one problem and the caret lands where
/// it starts. A lone `=======`, such as a Markdown heading's underline, is
/// never a conflict.
void _findConflictMarkers(String text, _ProblemSink sink) {
  // Most documents have none: one search instead of a pass over the lines.
  if (!text.contains('<<<<<<<')) return;
  int? openStart;
  var openEnd = 0;
  var separated = false;
  for (final (start, end) in _lines(text)) {
    if (sink.isFull) return;
    if (_isConflictMarker(text, start, end, 0x3c /* < */)) {
      openStart = start;
      openEnd = end;
      separated = false;
      continue;
    }
    if (openStart == null) continue;
    if (!separated) {
      separated = _isConflictSeparator(text, start, end);
      continue;
    }
    if (!_isConflictMarker(text, start, end, 0x3e /* > */)) continue;
    sink.add(
      TextProblemKind.mergeConflict,
      TextProblemSeverity.error,
      openStart,
      openEnd,
    );
    openStart = null;
  }
}

/// Seven [marker] characters, then the line's end or a space and the side's
/// label, as in `<<<<<<< HEAD`. An eighth marker character is not Git's.
bool _isConflictMarker(String text, int start, int end, int marker) {
  if (end - start < _conflictMarkerLength) return false;
  for (var i = start; i < start + _conflictMarkerLength; i++) {
    if (text.codeUnitAt(i) != marker) return false;
  }
  return end - start == _conflictMarkerLength ||
      _isBlank(text.codeUnitAt(start + _conflictMarkerLength));
}

/// Exactly seven `=`, then nothing but blanks.
bool _isConflictSeparator(String text, int start, int end) {
  if (end - start < _conflictMarkerLength) return false;
  for (var i = start; i < end; i++) {
    final c = text.codeUnitAt(i);
    if (i < start + _conflictMarkerLength ? c != 0x3d /* = */ : !_isBlank(c)) {
      return false;
    }
  }
  return true;
}
