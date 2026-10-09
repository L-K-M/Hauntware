part of 'text_validation.dart';

/// Joins the parts of a dotted key, so `a."b.c"` and `a.b.c` stay distinct.
const _tomlKeySeparator = '\u0000';

/// Flags what TOML forbids and every reader rejects: a key defined twice in
/// one table, and a table declared twice or both as a table and as an array
/// of tables. Each `[[array]]` header starts a new element, so its keys and
/// sub-tables start afresh. Keys compare by the parts they spell, so `a.b`,
/// `a . b` and `"a".b` are the same key. Keys are not compared with table
/// headers, nor keys inside inline tables, so a table a key implies goes
/// unflagged. Multi-line strings and arrays are stepped over.
void _validateToml(String text, _ProblemSink sink) {
  final reader = _TomlReader(text, sink);
  for (final (start, end) in _lines(text)) {
    if (sink.isFull) return;
    reader.read(start, end);
  }
}

/// A key or table name: its parts joined for comparing and for reading,
/// where it is written, and where the line goes on after it.
typedef _TomlKey = ({
  String identity,
  String name,
  int start,
  int end,
  int after,
});

final class _TomlReader {
  _TomlReader(this._text, this._sink);

  final String _text;
  final _ProblemSink _sink;

  /// Tables declared with `[name]`, and the line of each declaration.
  final _tables = <String, int>{};

  /// Arrays of tables declared with `[[name]]`, and the line of the first
  /// element.
  final _arrays = <String, int>{};

  /// Keys defined in the current table, and the line of each definition.
  var _keys = <String, int>{};

  /// Inside a multi-line string that spans lines: its delimiter.
  String? _multiline;

  /// Brackets still open in an array or inline table that spans lines.
  int _depth = 0;

  void read(int start, int end) {
    if (_multiline != null || _depth > 0) {
      _scanValue(start, end);
      return;
    }
    final pos = _skipBlanks(start, end);
    if (pos == end || _text.codeUnitAt(pos) == 0x23 /* # */ ) return;
    if (_text.codeUnitAt(pos) == 0x5b /* [ */ ) {
      _header(pos, end);
      return;
    }

    final key = _key(pos, end, 0x3d /* = */);
    if (key == null) return;
    final first = _keys[key.identity];
    if (first == null) {
      _keys[key.identity] = _sink.lineOf(key.start);
    } else {
      _sink.add(
        TextProblemKind.duplicateKey,
        TextProblemSeverity.error,
        key.start,
        key.end,
        subject: key.name,
        relatedLine: first,
      );
    }
    _scanValue(key.after, end);
  }

  /// A `[table]` or `[[array]]` header at [pos].
  void _header(int pos, int end) {
    final array = pos + 1 < end && _text.codeUnitAt(pos + 1) == 0x5b;
    final name = _key(pos + (array ? 2 : 1), end, 0x5d /* ] */);
    // Even a header that does not parse ends the table before it, so its
    // keys are not compared with the next table's.
    _keys = {};
    if (name == null) return;
    // A name is a table or an array of tables, never both.
    final clash = array ? _tables[name.identity] : _arrays[name.identity];
    if (clash != null) {
      _flagTable(name, clash);
      return;
    }
    if (array) {
      _arrays.putIfAbsent(name.identity, () => _sink.lineOf(name.start));
      // A new element: the previous element's sub-tables and nested arrays
      // may be declared again for this one.
      final prefix = '${name.identity}$_tomlKeySeparator';
      _tables.removeWhere((table, _) => table.startsWith(prefix));
      _arrays.removeWhere((nested, _) => nested.startsWith(prefix));
      return;
    }
    final first = _tables[name.identity];
    if (first == null) {
      _tables[name.identity] = _sink.lineOf(name.start);
      return;
    }
    _flagTable(name, first);
  }

  void _flagTable(_TomlKey name, int first) {
    _sink.add(
      TextProblemKind.duplicateTable,
      TextProblemSeverity.error,
      name.start,
      name.end,
      subject: name.name,
      relatedLine: first,
    );
  }

  /// A dotted key at [pos] ending at [stop]: bare parts, `"basic"` and
  /// `'literal'` parts, joined by dots with optional blanks.
  _TomlKey? _key(int pos, int end, int stop) {
    final parts = <String>[];
    pos = _skipBlanks(pos, end);
    final start = pos;
    var keyEnd = pos;
    while (pos < end) {
      final c = _text.codeUnitAt(pos);
      final String part;
      if (c == 0x22 /* " */ || c == 0x27 /* ' */ ) {
        final close = _closingQuote(pos + 1, end, c);
        if (close < 0) return null;
        final raw = _text.substring(pos + 1, close);
        part = c == 0x22 ? _tomlUnescape(raw) : raw;
        pos = close + 1;
      } else if (_isBareKeyChar(c)) {
        final from = pos;
        while (pos < end && _isBareKeyChar(_text.codeUnitAt(pos))) {
          pos++;
        }
        part = _text.substring(from, pos);
      } else {
        return null;
      }
      parts.add(part);
      keyEnd = pos;
      pos = _skipBlanks(pos, end);
      if (pos < end && _text.codeUnitAt(pos) == 0x2e /* . */ ) {
        pos = _skipBlanks(pos + 1, end);
        continue;
      }
      if (pos >= end || _text.codeUnitAt(pos) != stop) return null;
      return (
        identity: parts.join(_tomlKeySeparator),
        name: parts.join('.'),
        start: start,
        end: keyEnd,
        after: pos + 1,
      );
    }
    return null;
  }

  /// Follows a value from [pos] to the line's end, noting a multi-line
  /// string or bracket left open for the next lines.
  void _scanValue(int pos, int end) {
    while (pos < end) {
      if (_multiline case final delimiter?) {
        final close = _multilineClose(pos, end, delimiter);
        if (close < 0) return;
        _multiline = null;
        pos = close + delimiter.length;
        continue;
      }
      final c = _text.codeUnitAt(pos);
      if (c == 0x23 /* # */ ) return;
      if (_text.startsWith('"""', pos) || _text.startsWith("'''", pos)) {
        _multiline = _text.substring(pos, pos + 3);
        pos += 3;
        continue;
      }
      if (c == 0x22 || c == 0x27) {
        final close = _closingQuote(pos + 1, end, c);
        if (close < 0) return;
        pos = close + 1;
        continue;
      }
      if (c == 0x5b /* [ */ || c == 0x7b /* { */ ) {
        _depth++;
      } else if ((c == 0x5d /* ] */ || c == 0x7d /* } */ ) && _depth > 0) {
        _depth--;
      }
      pos++;
    }
  }

  /// The [delimiter] that closes a multi-line string, at or after [from] on
  /// the line, or -1. Searching only the line keeps a long string linear,
  /// and in a basic string a backslash escapes the next character, so
  /// `\"""` is a quote and two more inside the string.
  int _multilineClose(int from, int end, String delimiter) {
    for (var i = from; i < end; i++) {
      if (delimiter == '"""' && _text.codeUnitAt(i) == 0x5c /* backslash */ ) {
        i++;
        continue;
      }
      if (i + delimiter.length <= end && _text.startsWith(delimiter, i)) {
        return i;
      }
    }
    return -1;
  }

  /// The closing [quote] of a one-line string from [from], or -1. Basic
  /// strings take backslash escapes; literal strings take none.
  int _closingQuote(int from, int end, int quote) {
    for (var i = from; i < end; i++) {
      final c = _text.codeUnitAt(i);
      if (quote == 0x22 && c == 0x5c /* backslash */ ) {
        i++;
        continue;
      }
      if (c == quote) return i;
    }
    return -1;
  }

  int _skipBlanks(int pos, int end) {
    while (pos < end && _isBlank(_text.codeUnitAt(pos))) {
      pos++;
    }
    return pos;
  }
}

/// A basic string's escapes resolved, so `"a\u0062"` and `ab` are the same
/// key while `"a\tb"`, holding a tab, and `'a\tb'` are not. An escape TOML
/// does not define stays as written.
String _tomlUnescape(String raw) {
  if (!raw.contains(r'\')) return raw;
  final out = StringBuffer();
  for (var i = 0; i < raw.length; i++) {
    final c = raw[i];
    if (c != r'\' || i + 1 == raw.length) {
      out.write(c);
      continue;
    }
    final escaped = raw[++i];
    final digits = switch (escaped) {
      'x' => 2,
      'u' => 4,
      'U' => 8,
      _ => 0,
    };
    if (digits > 0) {
      // Hex digits only: int.tryParse would also take a sign.
      final hex = i + digits < raw.length
          ? raw.substring(i + 1, i + 1 + digits)
          : '';
      final code = hex.isNotEmpty && hex.codeUnits.every(_isHexDigit)
          ? int.parse(hex, radix: 16)
          : null;
      if (code != null && code <= 0x10ffff) {
        out.writeCharCode(code);
        i += digits;
      } else {
        out.write('\\$escaped');
      }
      continue;
    }
    out.write(switch (escaped) {
      'b' => '\b',
      't' => '\t',
      'n' => '\n',
      'f' => '\f',
      'r' => '\r',
      'e' => '\x1b',
      '"' || r'\' => escaped,
      _ => '\\$escaped',
    });
  }
  return out.toString();
}

bool _isHexDigit(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x46) ||
    (c >= 0x61 && c <= 0x66);

/// `A-Z a-z 0-9 _ -`, the characters of a bare key.
bool _isBareKeyChar(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    (c >= 0x30 && c <= 0x39) ||
    c == 0x5f ||
    c == 0x2d;
