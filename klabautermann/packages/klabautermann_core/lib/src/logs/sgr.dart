import 'package:meta/meta.dart';

/// A colour an SGR sequence selects. The app maps it to the theme: palette
/// entries 0 to 15 to its safe palette, 16 to 255 to the xterm cube and
/// grey ramp, and RGB values as given. Matching colours (`30;40`) would
/// hide text, so the view must hold each span's foreground and background
/// to a minimum contrast, RGB included (03 §10.8).
sealed class SgrColor {
  const SgrColor();
}

/// Palette entry [index], 0 to 255: 30 to 37 select 0 to 7, 90 to 97
/// select 8 to 15, and `38;5;n` selects n.
@immutable
final class SgrPaletteColor extends SgrColor {
  const SgrPaletteColor(this.index);

  final int index;

  @override
  bool operator ==(Object other) =>
      other is SgrPaletteColor && other.index == index;

  @override
  int get hashCode => index.hashCode;

  @override
  String toString() => 'SgrPaletteColor($index)';
}

/// A direct colour from `38;2;r;g;b` or its colon forms, each component 0
/// to 255.
@immutable
final class SgrRgbColor extends SgrColor {
  const SgrRgbColor(this.red, this.green, this.blue);

  final int red;
  final int green;
  final int blue;

  @override
  bool operator ==(Object other) =>
      other is SgrRgbColor &&
      other.red == red &&
      other.green == green &&
      other.blue == blue;

  @override
  int get hashCode => Object.hash(red, green, blue);

  @override
  String toString() => 'SgrRgbColor($red, $green, $blue)';
}

/// The attributes [parseSgr] keeps. Blink (5, 6) and conceal (8) are left
/// out on purpose: log text never animates or hides behind an attribute.
/// Colours can still hide it; see [SgrColor].
/// [inverse] is kept as a flag; the renderer swaps the colours.
@immutable
final class SgrStyle {
  const SgrStyle({
    this.foreground,
    this.background,
    this.bold = false,
    this.faint = false,
    this.italic = false,
    this.underline = false,
    this.inverse = false,
    this.strikethrough = false,
  });

  /// The style a line starts with.
  static const plain = SgrStyle();

  /// Null is the theme's default colour.
  final SgrColor? foreground;
  final SgrColor? background;
  final bool bold;
  final bool faint;
  final bool italic;
  final bool underline;
  final bool inverse;
  final bool strikethrough;

  @override
  bool operator ==(Object other) =>
      other is SgrStyle &&
      other.foreground == foreground &&
      other.background == background &&
      other.bold == bold &&
      other.faint == faint &&
      other.italic == italic &&
      other.underline == underline &&
      other.inverse == inverse &&
      other.strikethrough == strikethrough;

  @override
  int get hashCode => Object.hash(
    foreground,
    background,
    bold,
    faint,
    italic,
    underline,
    inverse,
    strikethrough,
  );

  @override
  String toString() => [
    'SgrStyle(',
    [
      if (foreground != null) 'fg: $foreground',
      if (background != null) 'bg: $background',
      if (bold) 'bold',
      if (faint) 'faint',
      if (italic) 'italic',
      if (underline) 'underline',
      if (inverse) 'inverse',
      if (strikethrough) 'strikethrough',
    ].join(', '),
    ')',
  ].join();
}

/// [style] over the UTF-16 code units `[start, end)` of [SgrText.text].
@immutable
final class SgrSpan {
  const SgrSpan(this.start, this.end, this.style);

  final int start;
  final int end;
  final SgrStyle style;

  @override
  bool operator ==(Object other) =>
      other is SgrSpan &&
      other.start == start &&
      other.end == end &&
      other.style == style;

  @override
  int get hashCode => Object.hash(start, end, style);

  @override
  String toString() => 'SgrSpan($start, $end, $style)';
}

/// One log line as [parseSgr] reads it: the visible [text] and the styled
/// runs over it, in order, never empty or overlapping. Text outside every
/// span is [SgrStyle.plain].
@immutable
final class SgrText {
  const SgrText(this.text, this.spans);

  final String text;
  final List<SgrSpan> spans;
}

const int _bel = 0x07;
const int _tab = 0x09;
const int _can = 0x18;
const int _sub = 0x1a;
const int _esc = 0x1b;
const int _space = 0x20;
const int _del = 0x7f;
const int _lastC1 = 0x9f;
const int _csiIntroducer = 0x5b; // [
const int _oscIntroducer = 0x5d; // ]
const int _stFinal = 0x5c; // \, the second half of ST (ESC \)
const int _sgrFinal = 0x6d; // m
const int _semicolon = 0x3b;
const int _colon = 0x3a;
const int _firstPrivateMarker = 0x3c; // <, then = > ?: private parameters

/// The introducers of strings that only ST ends: DCS, SOS, PM and APC.
const Set<int> _stStringIntroducers = {0x50, 0x58, 0x5e, 0x5f}; // P X ^ _

/// Larger parameters are clamped: any value above 255 is already invalid,
/// and clamping keeps a long run of digits from growing without bound.
const int _maxParameter = 65535;

bool _isParameterByte(int c) => c >= 0x30 && c <= 0x3f;
bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isIntermediateByte(int c) => c >= 0x20 && c <= 0x2f;
bool _isFinalByte(int c) => c >= 0x40 && c <= 0x7e;

/// The final byte of an escape sequence other than CSI (ECMA-35).
bool _isEscapeFinalByte(int c) => c >= 0x30 && c <= 0x7e;

/// C0 controls but tab, DEL, and the C1 range.
bool _isDropped(int c) =>
    (c < _space && c != _tab) || (c >= _del && c <= _lastC1);

/// A C0 control other than CAN, SUB and ESC, or DEL: inside an escape or
/// CSI sequence, xterm and VTE execute or ignore it and go on with the
/// sequence. The parser drops it as it does anywhere else.
bool _isSkippedInSequence(int c) =>
    (c < _space && c != _can && c != _sub && c != _esc) || c == _del;

/// Reads the ANSI SGR colours and attributes in one log [line] into spans
/// over its visible text (03 §10.8). Everything else is dropped: other CSI
/// sequences (cursor moves, erasing, modes), OSC strings (titles, OSC 52
/// clipboard writes, OSC 8 links, which keep only their text), DCS, SOS,
/// PM and APC strings, two-character escapes, and the C0 controls but tab,
/// DEL and the C1 controls (which are not read as 8-bit introducers). So a
/// log line can only colour its own text, never act on the app (03 §8.12).
///
/// Each line starts from [SgrStyle.plain]: no style carries over from the
/// line before, which would also let one line restyle every line after it.
/// A sequence cut off by the end of the line, as the buffer's line cap can
/// leave it, is dropped, so an unterminated OSC, DCS, SOS, PM or APC
/// string hides the rest of its own line, never the next. Never throws.
SgrText parseSgr(String line) {
  if (!_needsParsing(line)) return SgrText(line, const []);

  return _SgrParser(line).parse();
}

bool _needsParsing(String line) {
  for (var i = 0; i < line.length; i++) {
    if (_isDropped(line.codeUnitAt(i))) return true;
  }
  return false;
}

final class _SgrParser {
  _SgrParser(this._line);

  final String _line;
  final _text = StringBuffer();
  final _spans = <SgrSpan>[];
  final _pen = _Pen();

  /// The style of the run that started at [_runStart] in [_text].
  SgrStyle _runStyle = SgrStyle.plain;
  int _runStart = 0;

  SgrText parse() {
    final line = _line;
    var copyFrom = 0;
    var i = 0;
    while (i < line.length) {
      final c = line.codeUnitAt(i);
      if (!_isDropped(c)) {
        i++;
        continue;
      }

      _text.write(line.substring(copyFrom, i));
      i = c == _esc ? _escape(i + 1) : i + 1;
      copyFrom = i;
    }
    _text.write(line.substring(copyFrom));
    _closeRun();

    final spans = _spans.isEmpty
        ? const <SgrSpan>[]
        : List<SgrSpan>.unmodifiable(_spans);
    return SgrText(_text.toString(), spans);
  }

  /// Skips the escape sequence whose ESC came just before [start] and
  /// returns where ordinary text resumes.
  int _escape(int start) {
    final line = _line;
    var i = _skipInSequence(start);
    if (i >= line.length) return i;

    final c = line.codeUnitAt(i);
    if (c == _csiIntroducer) return _csi(i + 1);
    if (c == _oscIntroducer) return _string(i + 1, endsAtBel: true);
    if (_stStringIntroducers.contains(c)) {
      return _string(i + 1, endsAtBel: false);
    }

    if (_isIntermediateByte(c)) {
      // ESC, intermediates, then one final byte (charset designations
      // such as `ESC ( B`).
      while (i < line.length && _isIntermediateByte(line.codeUnitAt(i))) {
        i = _skipInSequence(i + 1);
      }
      if (i >= line.length) return i;
      return _isEscapeFinalByte(line.codeUnitAt(i)) ? i + 1 : i;
    }

    // Two-character escapes such as `ESC 7` or `ESC c`. Anything else
    // (CAN, SUB, ESC, a non-ASCII character) ends the escape and is read
    // again.
    return _isEscapeFinalByte(c) ? i + 1 : i;
  }

  /// The first index from [start] not [_isSkippedInSequence].
  int _skipInSequence(int start) {
    var i = start;
    while (i < _line.length && _isSkippedInSequence(_line.codeUnitAt(i))) {
      i++;
    }
    return i;
  }

  /// A CSI from its parameters at [start]: parameter bytes, then
  /// intermediates, then a final byte. Only a final `m` with plain
  /// parameters and no intermediates is SGR. CAN, SUB, ESC or a non-ASCII
  /// character abandons the sequence and is read again as text or a new
  /// escape.
  int _csi(int start) {
    final line = _line;
    var i = start;
    var valid = true;
    var sawIntermediate = false;
    while (i < line.length) {
      final c = line.codeUnitAt(i);
      if (_isParameterByte(c)) {
        // Parameters after an intermediate, and private markers
        // (`< = > ?`), make the sequence one this parser does not apply.
        if (sawIntermediate || c >= _firstPrivateMarker) valid = false;
        i++;
      } else if (_isIntermediateByte(c)) {
        sawIntermediate = true;
        i++;
      } else if (_isFinalByte(c)) {
        if (valid && !sawIntermediate && c == _sgrFinal) {
          _applySgr(_parameters(start, i));
        }
        return i + 1;
      } else if (_isSkippedInSequence(c)) {
        i++;
      } else {
        return i;
      }
    }
    return i;
  }

  /// An OSC, DCS, SOS, PM or APC string from [start]. ST (`ESC \`) ends
  /// it, BEL too for OSC; any other ESC ends it and starts a sequence of
  /// its own. An unterminated string runs to the end of the line.
  int _string(int start, {required bool endsAtBel}) {
    final line = _line;
    for (var i = start; i < line.length; i++) {
      final c = line.codeUnitAt(i);
      if (endsAtBel && c == _bel) return i + 1;
      if (c != _esc) continue;

      final terminatedBySt =
          i + 1 < line.length && line.codeUnitAt(i + 1) == _stFinal;
      return terminatedBySt ? i + 2 : i;
    }
    return line.length;
  }

  /// The `;`-separated parameters in `[start, end)`, each with its
  /// `:`-separated sub-parameters; an empty one is null. Controls skipped
  /// inside the sequence are not part of them.
  List<List<int?>> _parameters(int start, int end) {
    final line = _line;
    final parameters = <List<int?>>[];
    var current = <int?>[];
    int? value;
    for (var i = start; i < end; i++) {
      final c = line.codeUnitAt(i);
      if (c == _semicolon) {
        parameters.add(current..add(value));
        current = <int?>[];
        value = null;
      } else if (c == _colon) {
        current.add(value);
        value = null;
      } else if (_isDigit(c)) {
        final digit = c - 0x30;
        final next = (value ?? 0) * 10 + digit;
        value = next > _maxParameter ? _maxParameter : next;
      }
    }
    parameters.add(current..add(value));
    return parameters;
  }

  void _applySgr(List<List<int?>> parameters) {
    final pen = _pen;
    var i = 0;
    while (i < parameters.length) {
      final parameter = parameters[i];
      final code = parameter.first ?? 0;
      switch (code) {
        case 0:
          pen.reset();
        case 1:
          pen.bold = true;
        case 2:
          pen.faint = true;
        case 3:
          pen.italic = true;
        case 4:
          // 4:0 is "not underlined"; 4:1 to 4:5 are underline styles.
          pen.underline = parameter.length < 2 || (parameter[1] ?? 0) != 0;
        case 7:
          pen.inverse = true;
        case 9:
          pen.strikethrough = true;
        case 21:
          // Doubly underlined (ECMA-48), not "bold off".
          pen.underline = true;
        case 22:
          pen.bold = false;
          pen.faint = false;
        case 23:
          pen.italic = false;
        case 24:
          pen.underline = false;
        case 27:
          pen.inverse = false;
        case 29:
          pen.strikethrough = false;
        case >= 30 && <= 37:
          pen.foreground = SgrPaletteColor(code - 30);
        case 39:
          pen.foreground = null;
        case >= 40 && <= 47:
          pen.background = SgrPaletteColor(code - 40);
        case 49:
          pen.background = null;
        case >= 90 && <= 97:
          pen.foreground = SgrPaletteColor(code - 90 + 8);
        case >= 100 && <= 107:
          pen.background = SgrPaletteColor(code - 100 + 8);
        case 38 || 48 || 58:
          final (color, consumed) = _extendedColor(parameters, i);
          // 58 (underline colour) is read only to skip its components.
          if (color != null && code == 38) pen.foreground = color;
          if (color != null && code == 48) pen.background = color;
          i += consumed;
        default:
          // Blink (5, 6), conceal (8) and their resets, fonts, frames,
          // overline and anything unknown: deliberately ignored.
          break;
      }
      i++;
    }

    final style = pen.style;
    if (style == _runStyle) return;

    _closeRun();
    _runStyle = style;
  }

  /// The colour after the 38, 48 or 58 at [parameters]`[index]` and how
  /// many following parameters it used. Null when the colour is invalid
  /// or cut short; the components are still used up, so they are never
  /// read as attributes. An unknown colour mode uses up the rest of the
  /// sequence for the same reason.
  (SgrColor?, int) _extendedColor(List<List<int?>> parameters, int index) {
    final parameter = parameters[index];
    if (parameter.length > 1) return (_colonColor(parameter), 0);

    final remaining = parameters.length - index - 1;
    if (remaining == 0) return (null, 0);

    int value(int offset) => parameters[index + offset].first ?? 0;
    switch (value(1)) {
      case 5:
        if (remaining < 2) return (null, remaining);
        return (_paletteColor(value(2)), 2);
      case 2:
        if (remaining < 4) return (null, remaining);
        return (_rgbColor(value(2), value(3), value(4)), 4);
      default:
        return (null, remaining);
    }
  }

  /// `38:5:n`, `38:2:r:g:b`, or ITU T.416's `38:2:<colour space>:r:g:b`.
  SgrColor? _colonColor(List<int?> parameter) {
    int value(int index) => parameter[index] ?? 0;
    return switch ((value(1), parameter.length)) {
      (5, >= 3) => _paletteColor(value(2)),
      (2, 5) => _rgbColor(value(2), value(3), value(4)),
      (2, >= 6) => _rgbColor(value(3), value(4), value(5)),
      _ => null,
    };
  }

  SgrColor? _paletteColor(int index) =>
      index <= 255 ? SgrPaletteColor(index) : null;

  SgrColor? _rgbColor(int red, int green, int blue) =>
      red <= 255 && green <= 255 && blue <= 255
      ? SgrRgbColor(red, green, blue)
      : null;

  /// Ends the current run at the end of [_text]. A plain or empty run adds
  /// no span; a run adjacent to a span of the same style extends it.
  void _closeRun() {
    final end = _text.length;
    final start = _runStart;
    _runStart = end;
    if (end == start || _runStyle == SgrStyle.plain) return;

    if (_spans.isNotEmpty) {
      final last = _spans.last;
      if (last.end == start && last.style == _runStyle) {
        _spans[_spans.length - 1] = SgrSpan(last.start, end, _runStyle);
        return;
      }
    }
    _spans.add(SgrSpan(start, end, _runStyle));
  }
}

/// The parser's current attributes, mutable while one sequence applies.
final class _Pen {
  SgrColor? foreground;
  SgrColor? background;
  bool bold = false;
  bool faint = false;
  bool italic = false;
  bool underline = false;
  bool inverse = false;
  bool strikethrough = false;

  void reset() {
    foreground = null;
    background = null;
    bold = false;
    faint = false;
    italic = false;
    underline = false;
    inverse = false;
    strikethrough = false;
  }

  SgrStyle get style => SgrStyle(
    foreground: foreground,
    background: background,
    bold: bold,
    faint: faint,
    italic: italic,
    underline: underline,
    inverse: inverse,
    strikethrough: strikethrough,
  );
}
