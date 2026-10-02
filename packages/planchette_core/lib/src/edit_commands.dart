/// Selection and line-insertion helpers behind the Edit menu.
///
/// These are pure text transforms, so every host gets identical behaviour
/// and they can be tested without Flutter. Clipboard, file and UI mechanics
/// stay in the controller and the app: this file never touches them.
library;

import 'dart:math' as math;

import 'editor_syntax.dart';
import 'line_operations.dart';

const _return = 0x0d;
const _space = 0x20;
const _tab = 0x09;

bool _isIndentUnit(int unit) => unit == _space || unit == _tab;

bool _isBlankRange(String text, int from, int to) {
  for (var i = from; i < to; i++) {
    final unit = text.codeUnitAt(i);
    if (unit != _space && unit != _tab && unit != _return) return false;
  }
  return true;
}

/// Expands the selection to the whole lines it touches, keeping its
/// direction. A selection ending at column 0 does not touch that line,
/// like the line commands. Empty buffers select nothing.
({int base, int extent}) selectLineRange(String text, int base, int extent) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  if (text.isEmpty) return (base: 0, extent: 0);
  final lines = touchedLineRange(text, base, extent);
  return base <= extent
      ? (base: lines.start, extent: lines.end)
      : (base: lines.end, extent: lines.start);
}

/// Expands the selection to the paragraph it touches, keeping its
/// direction. A paragraph is a run of non-blank lines; blank is empty or
/// spaces and tabs only, as for Remove Blank Lines. A caret on a blank
/// line selects that line alone.
({int base, int extent}) selectParagraphRange(
  String text,
  int base,
  int extent,
) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  if (text.isEmpty) return (base: 0, extent: 0);
  final from = math.min(base, extent);
  final to = math.max(base, extent);
  var start = lineStart(text, from);
  var end = lineContentEnd(text, to);
  if (_isBlankRange(text, start, end)) {
    return base <= extent
        ? (base: start, extent: end)
        : (base: end, extent: start);
  }
  while (start > 0) {
    final separator = lineSeparatorBefore(text, start);
    final previousEnd = start - separator.length;
    final previousStart = lineStart(text, previousEnd);
    final previousContentEnd = lineContentEnd(text, previousEnd);
    if (_isBlankRange(text, previousStart, previousContentEnd)) break;
    start = previousStart;
  }
  while (end < text.length) {
    final separator = lineSeparatorAt(text, end);
    if (separator.isEmpty) break;
    final nextStart = end + separator.length;
    if (nextStart >= text.length) break;
    final nextEnd = lineContentEnd(text, nextStart);
    if (_isBlankRange(text, nextStart, nextEnd)) break;
    end = nextEnd;
  }
  return base <= extent
      ? (base: start, extent: end)
      : (base: end, extent: start);
}

const _closerOf = {0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D};
const _openerOf = {0x29: 0x28, 0x5D: 0x5B, 0x7D: 0x7B};

bool _isTextToken(SyntaxToken token) =>
    token.type == SyntaxTokenType.string ||
    token.type == SyntaxTokenType.comment;

/// Selects the innermost bracket pair enclosing the selection, including
/// the brackets themselves, keeping the selection direction. Repeating
/// the command expands outwards, as an exact match is skipped. Brackets
/// pair with their own type only. Inside a string or comment token only
/// that token's pairs count, as for Go to Matching Bracket; elsewhere
/// those tokens are skipped. Returns null when nothing encloses it.
({int base, int extent})? selectEnclosingBracketsRange(
  String text,
  int base,
  int extent,
  List<SyntaxToken> tokens,
) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  final from = math.min(base, extent);
  final to = math.max(base, extent);
  final region = _codeRegion(text, from, to, tokens);
  final pairs = _bracketPairs(region.text, region.start, region.end, tokens);
  ({int open, int close})? best;
  for (final pair in pairs) {
    if (pair.open > from) continue;
    if (pair.close + 1 < to) continue;
    if (pair.open == from && pair.close + 1 == to) continue;
    if (from == to) {
      if (!(pair.open <= from && pair.close >= from)) continue;
    } else {
      if (!(pair.open <= from && pair.close + 1 >= to)) continue;
    }
    if (best == null || pair.open > best.open) best = pair;
  }
  if (best == null) return null;
  return base <= extent
      ? (base: best.open, extent: best.close + 1)
      : (base: best.close + 1, extent: best.open);
}

/// The stretch a balance scan runs over: the string or comment token
/// holding the whole selection, or the document with those tokens skipped.
({String text, int start, int end}) _codeRegion(
  String text,
  int from,
  int to,
  List<SyntaxToken> tokens,
) {
  for (final token in tokens) {
    if (!_isTextToken(token)) continue;
    if (token.start <= from && to <= token.end) {
      final end = math.min(token.end, text.length);
      return (text: text, start: token.start, end: end);
    }
  }
  return (text: text, start: 0, end: text.length);
}

/// Every paired (opener, closer) offset in [start, end), pairing each type
/// with its own kind and skipping string and comment tokens, unless the
/// region itself is one such token.
List<({int open, int close})> _bracketPairs(
  String text,
  int start,
  int end,
  List<SyntaxToken> tokens,
) {
  final inToken = tokens.any(
    (token) => _isTextToken(token) && token.start == start && token.end == end,
  );
  var skip = -1;
  bool skipped(int offset) {
    if (inToken) return false;
    while (skip + 1 < tokens.length && tokens[skip + 1].end <= offset) {
      skip++;
    }
    return skip + 1 < tokens.length &&
        tokens[skip + 1].start <= offset &&
        _isTextToken(tokens[skip + 1]);
  }

  final stacks = <int, List<int>>{
    for (final opener in _closerOf.keys) opener: [],
  };
  final pairs = <({int open, int close})>[];
  var i = start;
  while (i < end) {
    if (skipped(i)) {
      i = tokens[skip + 1].end;
      continue;
    }
    final unit = text.codeUnitAt(i);
    final closer = _closerOf[unit];
    if (closer != null) {
      stacks[unit]!.add(i);
    } else {
      final opener = _openerOf[unit];
      if (opener != null) {
        final stack = stacks[opener]!;
        if (stack.isNotEmpty) pairs.add((open: stack.removeLast(), close: i));
      }
    }
    i++;
  }
  return pairs;
}

/// The leading spaces and tabs of the line holding [offset].
String _leadingIndent(String text, int offset) {
  final start = lineStart(text, offset);
  final end = lineContentEnd(text, offset);
  var i = start;
  while (i < end && _isIndentUnit(text.codeUnitAt(i))) {
    i++;
  }
  return text.substring(start, i);
}

/// A break for a new line next to [lineBegins, contentEnd]: the line's own
/// break, or the one before it, or LF on a single line without breaks.
String _nearbySeparator(String text, int lineBegins, int contentEnd) {
  final after = lineSeparatorAt(text, contentEnd);
  if (after.isNotEmpty) return after;
  if (lineBegins > 0) return lineSeparatorBefore(text, lineBegins);
  return '\n';
}

/// Inserts an empty indented line above the caret's line and parks the
/// caret on it. The new line takes the current line's indentation and a
/// nearby break, so CRLF buffers stay CRLF.
LineEdit insertLineAbove(String text, int base, int extent) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  final caret = extent;
  final start = lineStart(text, caret);
  final end = lineContentEnd(text, caret);
  final leading = _leadingIndent(text, caret);
  final separator = _nearbySeparator(text, start, end);
  final result = text.replaceRange(start, start, '$leading$separator');
  final at = start + leading.length;
  return LineEdit(result, at, at);
}

/// Inserts an empty indented line below the caret's line and parks the
/// caret on it. The last line without a break gains one, so the buffer
/// never ends mid-line.
LineEdit insertLineBelow(String text, int base, int extent) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  final caret = extent;
  final start = lineStart(text, caret);
  final end = lineContentEnd(text, caret);
  final leading = _leadingIndent(text, caret);
  final after = lineSeparatorAt(text, end);
  if (after.isNotEmpty) {
    final at = end + after.length;
    final separator = _nearbySeparator(text, start, end);
    final result = text.replaceRange(at, at, '$leading$separator');
    final caretAt = at + leading.length;
    return LineEdit(result, caretAt, caretAt);
  }
  final separator = start > 0 ? lineSeparatorBefore(text, start) : '\n';
  final result = text.replaceRange(end, end, '$separator$leading');
  final at = end + separator.length + leading.length;
  return LineEdit(result, at, at);
}

/// The text Copy Line would put on the clipboard: the touched lines with
/// their breaks. The last line without its own break copies without one.
/// Empty buffers copy nothing.
String copyLineText(String text, int base, int extent) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  if (text.isEmpty) return '';
  final lines = touchedLineRange(text, base, extent);
  final after = lineSeparatorAt(text, lines.end);
  return text.substring(lines.start, lines.end + after.length);
}

final _decimalNumber = RegExp(r'-?\d+(?:\.\d+)?');
final _hexNumber = RegExp(r'-?0[xX][0-9a-fA-F]+');

/// The number at the caret or covered by the selection, for Increment and
/// Decrement. A non-empty selection must itself be the number; a caret
/// takes the number touching it. Only ASCII decimal integers, simple
/// decimals and hex integers count: no exponents or underscores.
({int start, int end, bool hex, int fractions})? _numberAt(
  String text,
  int base,
  int extent,
) {
  if (base != extent) {
    final from = math.min(base, extent);
    final to = math.max(base, extent);
    final selected = text.substring(from, to);
    if (RegExp('^${_hexNumber.pattern}\$').hasMatch(selected)) {
      return (start: from, end: to, hex: true, fractions: 0);
    }
    if (RegExp('^${_decimalNumber.pattern}\$').hasMatch(selected)) {
      final fractions = selected.contains('.')
          ? selected.split('.').last.length
          : 0;
      return (start: from, end: to, hex: false, fractions: fractions);
    }
    return null;
  }
  for (final pattern in [_hexNumber, _decimalNumber]) {
    for (final match in pattern.allMatches(text)) {
      if (match.start <= base && base <= match.end) {
        final hex = identical(pattern, _hexNumber);
        final fractions = hex || !match[0]!.contains('.')
            ? 0
            : match[0]!.split('.').last.length;
        return (
          start: match.start,
          end: match.end,
          hex: hex,
          fractions: fractions,
        );
      }
    }
  }
  return null;
}

/// Adds [delta] to the number at the caret or selection, preserving its
/// literal shape: leading-zero width, decimal places and hex prefix case.
/// Returns null when no number is there.
LineEdit? changeNumber(String text, int base, int extent, int delta) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  final found = _numberAt(text, base, extent);
  if (found == null) return null;
  final raw = text.substring(found.start, found.end);
  final forward = base <= extent;
  final String replacement;
  if (found.hex) {
    final prefix = raw.startsWith('-0X') || raw.startsWith('0X') ? '0X' : '0x';
    final negative = raw.startsWith('-');
    final digitsStart = negative ? 3 : 2;
    final digits = raw.substring(digitsStart);
    final upper = digits.contains(RegExp(r'[A-F]'));
    final value = int.parse('${negative ? '-' : ''}$digits', radix: 16);
    final next = value + delta;
    final nextDigits = next.abs().toRadixString(16);
    final padded = nextDigits.length >= digits.length
        ? nextDigits
        : nextDigits.padLeft(digits.length, '0');
    final cased = upper ? padded.toUpperCase() : padded.toLowerCase();
    replacement = '${next < 0 ? '-' : ''}$prefix$cased';
  } else if (found.fractions > 0) {
    final value = double.parse(raw) + delta;
    final fixed = value.toStringAsFixed(found.fractions);
    // Keep the integer width a leading zero implies: 007.50 + 1 is 008.50.
    final rawInt = raw.split('.').first.replaceFirst('-', '');
    final fixedParts = fixed.split('.');
    final fixedInt = fixedParts.first.replaceFirst('-', '');
    final paddedInt = fixedInt.length >= rawInt.length
        ? fixedParts.first
        : '${fixed.startsWith('-') ? '-' : ''}${fixedInt.padLeft(rawInt.length, '0')}';
    replacement = '$paddedInt.${fixedParts.last}';
  } else {
    final value = int.parse(raw) + delta;
    final rawDigits = raw.replaceFirst('-', '');
    final nextDigits = value.abs().toString();
    final padded = nextDigits.length >= rawDigits.length
        ? nextDigits
        : nextDigits.padLeft(rawDigits.length, '0');
    replacement = '${value < 0 ? '-' : ''}$padded';
  }
  final result = text.replaceRange(found.start, found.end, replacement);
  final end = found.start + replacement.length;
  if (base == extent) return LineEdit(result, end, end);
  return forward
      ? LineEdit(result, found.start, end)
      : LineEdit(result, end, found.start);
}

/// Adds one to the number at the caret or selection. See [changeNumber].
LineEdit? incrementNumber(String text, int base, int extent) =>
    changeNumber(text, base, extent, 1);

/// Subtracts one from the number at the caret or selection. See
/// [changeNumber].
LineEdit? decrementNumber(String text, int base, int extent) =>
    changeNumber(text, base, extent, -1);

/// Wraps [inner] with a block-comment pair, spacing bare text as
/// `/* text */` and `<!-- text -->` do. Markers already spaced are left
/// alone.
String _wrapBlock(String open, String inner, String close) {
  final left = inner.startsWith(' ') || inner.startsWith('\t') ? '' : ' ';
  final right = inner.endsWith(' ') || inner.endsWith('\t') || inner.isEmpty
      ? ''
      : ' ';
  return '$open$left$inner$right$close';
}

/// Removes one wrapping pair and the single spaces it added, when present.
String _unwrapBlock(String wrapped, String open, String close) {
  var inner = wrapped.substring(open.length, wrapped.length - close.length);
  if (inner.startsWith(' ') && !wrapped.startsWith('$open  ')) {
    inner = inner.substring(1);
  }
  if (inner.endsWith(' ') && !wrapped.endsWith('  $close')) {
    inner = inner.substring(0, inner.length - 1);
  }
  return inner;
}

/// Comments or uncomments with a block pair such as `/*`/`*/` or
/// `<!--`/`-->`, the fallback for languages without line markers.
///
/// A selection wraps exactly, so part of a line can comment. A caret
/// wraps its line's trimmed content. An already wrapped range unwraps,
/// whether the selection includes the markers or sits between them.
/// Returns null without markers or when nothing would change.
LineEdit? toggleBlockComments(
  String text,
  int base,
  int extent,
  String open,
  String close,
) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  if (open.isEmpty || close.isEmpty) return null;
  final collapsed = base == extent;
  final int from;
  final int to;
  if (collapsed) {
    final start = lineStart(text, base);
    final end = lineContentEnd(text, base);
    var contentStart = start;
    while (contentStart < end && _isIndentUnit(text.codeUnitAt(contentStart))) {
      contentStart++;
    }
    var contentEnd = end;
    while (contentEnd > contentStart &&
        _isIndentUnit(text.codeUnitAt(contentEnd - 1))) {
      contentEnd--;
    }
    if (contentStart >= contentEnd) return null;
    from = contentStart;
    to = contentEnd;
  } else {
    from = math.min(base, extent);
    to = math.max(base, extent);
  }
  final selected = text.substring(from, to);
  final forward = base <= extent;
  // Already includes the markers: unwrap them.
  if (selected.startsWith(open) &&
      selected.endsWith(close) &&
      selected.length >= open.length + close.length) {
    final inner = _unwrapBlock(selected, open, close);
    final result = text.replaceRange(from, to, inner);
    final end = from + inner.length;
    if (collapsed) return LineEdit(result, end, end);
    return forward ? LineEdit(result, from, end) : LineEdit(result, end, from);
  }
  // Sits between the markers: remove the surrounding pair and its spaces.
  var openStart = from - open.length - 1;
  if (openStart < 0 || !text.startsWith(open, openStart)) {
    openStart = from - open.length;
  }
  var closeEnd = to + close.length + 1;
  if (closeEnd > text.length ||
      !text.startsWith(close, closeEnd - close.length)) {
    closeEnd = to + close.length;
  }
  if (openStart >= 0 &&
      closeEnd <= text.length &&
      text.startsWith(open, openStart) &&
      text.startsWith(close, closeEnd - close.length)) {
    var innerStart = openStart + open.length;
    var innerEnd = closeEnd - close.length;
    if (innerStart < innerEnd &&
        text.codeUnitAt(innerStart) == _space &&
        !(innerStart + 1 < innerEnd &&
            text.codeUnitAt(innerStart + 1) == _space)) {
      innerStart++;
    }
    if (innerEnd > innerStart &&
        text.codeUnitAt(innerEnd - 1) == _space &&
        !(innerEnd - 2 >= innerStart &&
            text.codeUnitAt(innerEnd - 2) == _space)) {
      innerEnd--;
    }
    final inner = text.substring(innerStart, innerEnd);
    final result = text.replaceRange(openStart, closeEnd, inner);
    final end = openStart + inner.length;
    if (collapsed) {
      final caret =
          math.min(math.max(base - innerStart, 0), inner.length) + openStart;
      return LineEdit(result, caret, caret);
    }
    return forward
        ? LineEdit(result, openStart, end)
        : LineEdit(result, end, openStart);
  }
  final wrapped = _wrapBlock(open, selected, close);
  final result = text.replaceRange(from, to, wrapped);
  final end = from + wrapped.length;
  if (collapsed) return LineEdit(result, end, end);
  return forward ? LineEdit(result, from, end) : LineEdit(result, end, from);
}

/// Reindents pasted lines to the caret line's indentation, preserving
/// their relative steps. The first pasted line joins the caret as it is;
/// each later non-blank line loses the paste's common indent and gains
/// [baseIndent]. Blank pasted lines stay empty, so no trailing whitespace
/// is introduced. Breaks are emitted as [separator].
String reindentPastedText(
  String pasted,
  String baseIndent, {
  String separator = '\n',
}) {
  final lines = pasted.split(RegExp(r'\r\n|\n|\r'));
  if (lines.length <= 1) return pasted;
  var common = 1 << 30;
  for (var i = 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    var indent = 0;
    while (indent < line.length &&
        (line.codeUnitAt(indent) == _space ||
            line.codeUnitAt(indent) == _tab)) {
      indent++;
    }
    common = math.min(common, indent);
  }
  if (common == 1 << 30) common = 0;
  final out = StringBuffer(lines.first);
  for (var i = 1; i < lines.length; i++) {
    out.write(separator);
    final line = lines[i];
    if (line.trim().isEmpty) continue;
    var stripped = line;
    var remove = 0;
    while (remove < common &&
        remove < stripped.length &&
        (stripped.codeUnitAt(remove) == _space ||
            stripped.codeUnitAt(remove) == _tab)) {
      remove++;
    }
    stripped = stripped.substring(remove);
    out.write('$baseIndent$stripped');
  }
  return out.toString();
}

/// Pastes [pasted] over the selection with its later lines reindented to
/// the caret line, for Paste and Match Indentation. The caret lands after
/// the insert. See [reindentPastedText].
LineEdit pasteWithIndentation(
  String text,
  int base,
  int extent,
  String pasted, {
  String separator = '\n',
}) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  final from = math.min(base, extent);
  final to = math.max(base, extent);
  final indent = _leadingIndent(text, from);
  final normalized = pasted.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final reindented = reindentPastedText(
    normalized,
    indent,
    separator: separator,
  );
  final result = text.replaceRange(from, to, reindented);
  final caret = from + reindented.length;
  return LineEdit(result, caret, caret);
}
