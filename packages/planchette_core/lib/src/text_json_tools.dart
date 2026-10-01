// Strict whitespace-only JSON reformat for Format/Minify JSON.
//
// The tools never decode values: numbers, strings and literals are copied
// verbatim so large integers, exponents and escapes keep their source
// spelling and object order is untouched. Only insignificant whitespace
// between tokens is rewritten. Invalid input refuses with a line/column
// rather than guessing.

/// A strict-JSON syntax error with a 1-based position in the run's input.
final class JsonFormatError implements Exception {
  const JsonFormatError(this.message, this.line, this.column);

  final String message;
  final int line;
  final int column;

  @override
  String toString() => 'line $line, column $column: $message';
}

/// Pretty-prints [input] as JSON with two-space indent. Throws
/// [JsonFormatError] on invalid input.
String formatJsonWhitespace(String input) =>
    _JsonReformatter(input, pretty: true).run();

/// Minifies [input] to JSON with no insignificant whitespace. Throws
/// [JsonFormatError] on invalid input.
String minifyJsonWhitespace(String input) =>
    _JsonReformatter(input, pretty: false).run();

class _JsonReformatter {
  _JsonReformatter(this.input, {required this.pretty});

  final String input;
  final bool pretty;
  int pos = 0;

  static const _maxDepth = 200;

  String run() {
    _skipWhitespace();
    if (pos >= input.length) throw _error('empty input, expected a value', 0);
    final value = _parseValue(0);
    _skipWhitespace();
    if (pos < input.length) throw _error('unexpected trailing content', pos);
    return value;
  }

  String _parseValue(int depth) {
    if (depth > _maxDepth) throw _error('nesting too deep', pos);
    if (pos >= input.length) throw _error('expected a value', pos);
    final c = input.codeUnitAt(pos);
    if (c == 0x7b) return _parseObject(depth);
    if (c == 0x5b) return _parseArray(depth);
    if (c == 0x22) return _parseStringRaw();
    if (c == 0x74 || c == 0x66 || c == 0x6e) return _parseLiteralRaw();
    if (c == 0x2d || (c >= 0x30 && c <= 0x39)) return _parseNumberRaw();
    throw _error('expected a value', pos);
  }

  String _parseObject(int depth) {
    pos++; // consume '{'
    _skipWhitespace();
    if (pos < input.length && input.codeUnitAt(pos) == 0x7d) {
      pos++;
      return '{}';
    }
    final keys = <String>[];
    final values = <String>[];
    while (true) {
      _skipWhitespace();
      if (pos >= input.length || input.codeUnitAt(pos) != 0x22) {
        throw _error('expected a string key', pos);
      }
      keys.add(_parseStringRaw());
      _skipWhitespace();
      if (pos >= input.length || input.codeUnitAt(pos) != 0x3a) {
        throw _error("expected ':' after the key", pos);
      }
      pos++;
      _skipWhitespace();
      values.add(_parseValue(depth + 1));
      _skipWhitespace();
      if (pos >= input.length) throw _error("expected ',' or '}'", pos);
      final next = input.codeUnitAt(pos);
      if (next == 0x2c) {
        pos++;
        _skipWhitespace();
        if (pos < input.length && input.codeUnitAt(pos) == 0x7d) {
          throw _error('trailing comma', pos);
        }
        continue;
      }
      if (next == 0x7d) {
        pos++;
        break;
      }
      throw _error("expected ',' or '}'", pos);
    }
    if (!pretty) {
      final out = StringBuffer()..write('{');
      for (var i = 0; i < keys.length; i++) {
        if (i > 0) out.write(',');
        out.write(keys[i]);
        out.write(':');
        out.write(values[i]);
      }
      out.write('}');
      return out.toString();
    }
    // Nested values already carry their absolute indentation from
    // _parseValue(depth + 1); only the first line joins the key's line.
    final out = StringBuffer()..write('{\n');
    for (var i = 0; i < keys.length; i++) {
      out.write(_indent(depth + 1));
      out.write(keys[i]);
      out.write(': ');
      out.write(values[i]);
      if (i + 1 < keys.length) out.write(',');
      out.write('\n');
    }
    out.write(_indent(depth));
    out.write('}');
    return out.toString();
  }

  String _parseArray(int depth) {
    pos++; // consume '['
    _skipWhitespace();
    if (pos < input.length && input.codeUnitAt(pos) == 0x5d) {
      pos++;
      return '[]';
    }
    final items = <String>[];
    while (true) {
      _skipWhitespace();
      if (pos < input.length && input.codeUnitAt(pos) == 0x5d) {
        throw _error('trailing comma', pos);
      }
      items.add(_parseValue(depth + 1));
      _skipWhitespace();
      if (pos >= input.length) throw _error("expected ',' or ']'", pos);
      final next = input.codeUnitAt(pos);
      if (next == 0x2c) {
        pos++;
        continue;
      }
      if (next == 0x5d) {
        pos++;
        break;
      }
      throw _error("expected ',' or ']'", pos);
    }
    if (!pretty) return '[${items.join(',')}]';
    final out = StringBuffer()..write('[\n');
    for (var i = 0; i < items.length; i++) {
      out.write(_indent(depth + 1));
      out.write(items[i]);
      if (i + 1 < items.length) out.write(',');
      out.write('\n');
    }
    out.write(_indent(depth));
    out.write(']');
    return out.toString();
  }

  /// Copies a JSON string verbatim, validating escapes. Returns the raw
  /// source including its quotes.
  String _parseStringRaw() {
    final start = pos;
    pos++; // opening quote
    while (true) {
      if (pos >= input.length) throw _error('unterminated string', start);
      final c = input.codeUnitAt(pos);
      if (c == 0x22) {
        pos++;
        return input.substring(start, pos);
      }
      if (c == 0x5c) {
        if (pos + 1 >= input.length) {
          throw _error('unterminated escape', start);
        }
        final e = input.codeUnitAt(pos + 1);
        if (e == 0x75) {
          if (pos + 5 >= input.length ||
              !_isHex(input.codeUnitAt(pos + 2)) ||
              !_isHex(input.codeUnitAt(pos + 3)) ||
              !_isHex(input.codeUnitAt(pos + 4)) ||
              !_isHex(input.codeUnitAt(pos + 5))) {
            throw _error('invalid \\u escape', pos);
          }
          pos += 6;
        } else if (e == 0x22 ||
            e == 0x5c ||
            e == 0x2f ||
            e == 0x62 ||
            e == 0x66 ||
            e == 0x6e ||
            e == 0x72 ||
            e == 0x74) {
          pos += 2;
        } else {
          throw _error('invalid escape', pos);
        }
        continue;
      }
      // Unescaped controls (including literal line breaks) are invalid.
      if (c < 0x20) throw _error('unescaped control character', pos);
      pos++;
    }
  }

  /// Copies a JSON number verbatim after validating its grammar.
  String _parseNumberRaw() {
    final start = pos;
    if (pos < input.length && input.codeUnitAt(pos) == 0x2d) pos++;
    if (pos >= input.length) throw _error('invalid number', start);
    final first = input.codeUnitAt(pos);
    if (first == 0x30) {
      pos++;
    } else if (first >= 0x31 && first <= 0x39) {
      while (pos < input.length && _isDigit(input.codeUnitAt(pos))) {
        pos++;
      }
    } else {
      throw _error('invalid number', start);
    }
    if (pos < input.length && input.codeUnitAt(pos) == 0x2e) {
      pos++;
      if (pos >= input.length || !_isDigit(input.codeUnitAt(pos))) {
        throw _error('invalid number', start);
      }
      while (pos < input.length && _isDigit(input.codeUnitAt(pos))) {
        pos++;
      }
    }
    if (pos < input.length &&
        (input.codeUnitAt(pos) == 0x65 || input.codeUnitAt(pos) == 0x45)) {
      pos++;
      if (pos < input.length &&
          (input.codeUnitAt(pos) == 0x2b || input.codeUnitAt(pos) == 0x2d)) {
        pos++;
      }
      if (pos >= input.length || !_isDigit(input.codeUnitAt(pos))) {
        throw _error('invalid number', start);
      }
      while (pos < input.length && _isDigit(input.codeUnitAt(pos))) {
        pos++;
      }
    }
    return input.substring(start, pos);
  }

  /// Copies true/false/null verbatim.
  String _parseLiteralRaw() {
    for (final word in const ['true', 'false', 'null']) {
      if (input.startsWith(word, pos)) {
        final after = pos + word.length;
        if (after < input.length && _isLiteralTail(input.codeUnitAt(after))) {
          throw _error('invalid literal', pos);
        }
        pos = after;
        return word;
      }
    }
    throw _error('expected a value', pos);
  }

  void _skipWhitespace() {
    while (pos < input.length) {
      final c = input.codeUnitAt(pos);
      if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) {
        pos++;
      } else {
        break;
      }
    }
  }

  String _indent(int level) => '  ' * level;

  JsonFormatError _error(String message, int at) {
    final (line, column) = _lineColumnAt(input, at);
    return JsonFormatError(message, line, column);
  }
}

/// The 1-based line/column of [pos] in [text]: \r\n counts once.
(int, int) _lineColumnAt(String text, int pos) {
  var line = 1;
  var column = 1;
  var i = 0;
  final end = pos.clamp(0, text.length);
  while (i < end) {
    final c = text.codeUnitAt(i);
    if (c == 0x0a) {
      line++;
      column = 1;
      i++;
    } else if (c == 0x0d) {
      line++;
      column = 1;
      i++;
      if (i < end && text.codeUnitAt(i) == 0x0a) i++;
    } else {
      column++;
      i++;
    }
  }
  return (line, column);
}

bool _isDigit(int c) => c >= 0x30 && c <= 0x39;
bool _isHex(int c) =>
    _isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);
bool _isLiteralTail(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f;
