// Strict whitespace-only JSON reformat for Format/Minify JSON, and the
// editor's JSON validation over the same grammar.
//
// The tools never decode values: numbers, strings and literals are copied
// verbatim so large integers, exponents and escapes keep their source
// spelling and object order is untouched. Only insignificant whitespace
// between tokens is rewritten. Invalid input refuses with a line/column
// rather than guessing.

import 'dart:convert' show jsonDecode;

import 'text_metrics.dart' show lineStartOffsets;
import 'text_problem.dart';

/// A strict-JSON syntax error with a 1-based position in the run's input.
final class JsonFormatError implements Exception {
  const JsonFormatError(
    this.message,
    this.line,
    this.column, {
    required this.start,
    required this.end,
  });

  final String message;
  final int line;
  final int column;

  /// The offending text as offsets into the input, for an underline. It
  /// starts at [line] and [column] unless the error is a string that a line
  /// break cut short, which is flagged from its opening quote.
  final int start;
  final int end;

  @override
  String toString() => 'line $line, column $column: $message';
}

/// Pretty-prints [input] as JSON with two-space indent. [newline] is the
/// line separator for the emitted breaks — the caller's document EOL —
/// defaulting to LF. Throws [JsonFormatError] on invalid input.
String formatJsonWhitespace(String input, {String newline = '\n'}) =>
    _JsonReformatter(input, pretty: true, newline: newline).run();

/// Minifies [input] to JSON with no insignificant whitespace. Throws
/// [JsonFormatError] on invalid input.
String minifyJsonWhitespace(String input) =>
    _JsonReformatter(input, pretty: false).run();

/// Which JSON a document is read as.
enum JsonDialect {
  /// RFC 8259 JSON. Comments and trailing commas are still read past, so the
  /// rest of the document is checked, but each one is reported.
  strict,

  /// JSON with comments, as TypeScript and VS Code read their configuration:
  /// `//` and `/* */` comments and trailing commas are accepted.
  withComments,
}

/// Problems in [input] read as [dialect] JSON: each repeated object key, each
/// comment or trailing comma the dialect does not allow, and the first syntax
/// error, after which the input cannot be read further. Blank input has
/// none, so a new file is not flagged before anything is typed. At most
/// [limit] problems; the syntax error always fits.
List<TextProblem> validateJsonText(
  String input, {
  required JsonDialect dialect,
  int limit = textProblemLimit,
}) => _JsonValidator(input, dialect: dialect, limit: limit).run();

class _JsonReformatter extends _JsonScanner {
  _JsonReformatter(super.input, {required this.pretty, this.newline = '\n'});

  final bool pretty;

  /// The separator pretty output breaks lines with. Minified output has
  /// no breaks, so it never reads this.
  final String newline;

  String run() {
    _skipWhitespace();
    if (pos >= input.length) throw _error('empty input, expected a value', 0);
    final value = _parseValue(0);
    _skipWhitespace();
    if (pos < input.length) throw _error('unexpected trailing content', pos);
    return value;
  }

  String _parseValue(int depth) {
    if (depth > _JsonScanner._maxDepth) {
      throw _error('nesting too deep', pos);
    }
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
    final out = StringBuffer()..write('{$newline');
    for (var i = 0; i < keys.length; i++) {
      out.write(_indent(depth + 1));
      out.write(keys[i]);
      out.write(': ');
      out.write(values[i]);
      if (i + 1 < keys.length) out.write(',');
      out.write(newline);
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
    final out = StringBuffer()..write('[$newline');
    for (var i = 0; i < items.length; i++) {
      out.write(_indent(depth + 1));
      out.write(items[i]);
      if (i + 1 < items.length) out.write(',');
      out.write(newline);
    }
    out.write(_indent(depth));
    out.write(']');
    return out.toString();
  }

  String _indent(int level) => '  ' * level;
}

/// The token grammar Format JSON, Minify JSON and validation share:
/// strict strings, numbers and literals read from [input] at [pos].
abstract class _JsonScanner {
  _JsonScanner(this.input);

  final String input;
  int pos = 0;

  static const _maxDepth = 200;

  /// Copies a JSON string verbatim, validating escapes. Returns the raw
  /// source including its quotes.
  String _parseStringRaw() {
    final start = pos;
    pos++; // opening quote
    while (true) {
      if (pos >= input.length) {
        throw _error('unterminated string', start, end: _lineEnd(start));
      }
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
      // Unescaped controls (including literal line breaks) are invalid. A
      // line break usually means a missing closing quote: flag the string.
      if (c < 0x20) {
        throw _isLineBreak(c)
            ? _error('unescaped control character', pos, start: start, end: pos)
            : _error('unescaped control character', pos);
      }
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

  /// An error at [at], flagging [start] to [end] when given, else the
  /// token at [at].
  JsonFormatError _error(String message, int at, {int? start, int? end}) {
    final (line, column) = _lineColumnAt(input, at);
    final (tokenStart, tokenEnd) = _tokenAt(at);
    return JsonFormatError(
      message,
      line,
      column,
      start: start ?? tokenStart,
      end: end ?? tokenEnd,
    );
  }

  /// The word or single character at [at]. At the end of the input, the
  /// last character that is not whitespace: the nearest place a reader sees.
  (int, int) _tokenAt(int at) {
    if (input.isEmpty) return (0, 0);
    if (at >= input.length) {
      var last = input.length - 1;
      while (last > 0 && _isJsonSpace(input.codeUnitAt(last))) {
        last--;
      }
      return (last, last + 1);
    }
    var end = at + 1;
    if (_isLiteralTail(input.codeUnitAt(at))) {
      while (end < input.length && _isLiteralTail(input.codeUnitAt(end))) {
        end++;
      }
    }
    return (at, end);
  }

  /// The end of the line holding [from].
  int _lineEnd(int from) {
    var end = from;
    while (end < input.length && !_isLineBreak(input.codeUnitAt(end))) {
      end++;
    }
    return end;
  }
}

/// Reads a document through the shared grammar without building output,
/// collecting problems instead of stopping at the first.
class _JsonValidator extends _JsonScanner {
  _JsonValidator(super.input, {required this.dialect, required this.limit});

  final JsonDialect dialect;
  final int limit;
  final _problems = <TextProblem>[];
  List<int>? _lineStarts;

  List<TextProblem> run() {
    try {
      _skipWhitespace();
      if (pos >= input.length) return _problems;
      _value(0);
      _skipWhitespace();
      if (pos < input.length) throw _error('unexpected trailing content', pos);
    } on JsonFormatError catch (error) {
      _problems.add(
        TextProblem(
          kind: TextProblemKind.syntaxError,
          severity: TextProblemSeverity.error,
          start: error.start,
          end: error.end,
          detail: error.message,
        ),
      );
    }
    return _problems;
  }

  void _value(int depth) {
    if (depth > _JsonScanner._maxDepth) throw _error('nesting too deep', pos);
    if (pos >= input.length) throw _error('expected a value', pos);
    final c = input.codeUnitAt(pos);
    if (c == 0x7b) return _object(depth);
    if (c == 0x5b) return _array(depth);
    if (c == 0x22) {
      _parseStringRaw();
    } else if (c == 0x74 || c == 0x66 || c == 0x6e) {
      _parseLiteralRaw();
    } else if (c == 0x2d || _isDigit(c)) {
      _parseNumberRaw();
    } else {
      throw _error('expected a value', pos);
    }
  }

  void _object(int depth) {
    pos++; // consume '{'
    _skipWhitespace();
    if (_at(0x7d)) {
      pos++;
      return;
    }
    // Decoded names, so "a" and "\u0061" are the same key, as every reader
    // decodes them.
    final keys = <String, int>{};
    while (true) {
      _skipWhitespace();
      if (!_at(0x22)) throw _error('expected a string key', pos);
      final keyStart = pos;
      final key = jsonDecode(_parseStringRaw()) as String;
      final first = keys[key];
      if (first == null) {
        keys[key] = keyStart;
      } else {
        _warn(
          TextProblemKind.duplicateKey,
          keyStart,
          pos,
          subject: key,
          relatedLine: _lineOf(first),
        );
      }
      _skipWhitespace();
      if (!_at(0x3a)) throw _error("expected ':' after the key", pos);
      pos++;
      _skipWhitespace();
      _value(depth + 1);
      _skipWhitespace();
      if (pos >= input.length) throw _error("expected ',' or '}'", pos);
      final next = input.codeUnitAt(pos);
      if (next == 0x7d) {
        pos++;
        return;
      }
      if (next != 0x2c) throw _error("expected ',' or '}'", pos);
      if (_trailingComma(0x7d)) return;
    }
  }

  void _array(int depth) {
    pos++; // consume '['
    _skipWhitespace();
    if (_at(0x5d)) {
      pos++;
      return;
    }
    while (true) {
      _skipWhitespace();
      _value(depth + 1);
      _skipWhitespace();
      if (pos >= input.length) throw _error("expected ',' or ']'", pos);
      final next = input.codeUnitAt(pos);
      if (next == 0x5d) {
        pos++;
        return;
      }
      if (next != 0x2c) throw _error("expected ',' or ']'", pos);
      if (_trailingComma(0x5d)) return;
    }
  }

  /// Consumes the comma at [pos], and the [closer] when only whitespace and
  /// comments come between them, which strict JSON reports. Returns whether
  /// the closer ended the container.
  bool _trailingComma(int closer) {
    final comma = pos;
    pos++;
    _skipWhitespace();
    if (!_at(closer)) return false;
    if (dialect == JsonDialect.strict) {
      _warn(TextProblemKind.jsonTrailingComma, comma, comma + 1);
    }
    pos++;
    return true;
  }

  /// Steps over whitespace and comments, reporting comments that strict JSON
  /// does not allow. A `/` that opens no comment is left for the caller to
  /// reject.
  @override
  void _skipWhitespace() {
    while (pos < input.length) {
      final c = input.codeUnitAt(pos);
      if (_isJsonSpace(c)) {
        pos++;
        continue;
      }
      if (c != 0x2f || pos + 1 >= input.length) return;
      final start = pos;
      final opener = input.codeUnitAt(pos + 1);
      if (opener == 0x2f) {
        pos = _lineEnd(pos);
      } else if (opener == 0x2a) {
        final close = input.indexOf('*/', pos + 2);
        if (close < 0) {
          throw _error('unterminated comment', start, end: _lineEnd(start));
        }
        pos = close + 2;
      } else {
        return;
      }
      if (dialect == JsonDialect.strict) {
        // Only the comment's first line: a long block comment would
        // otherwise be one wide underline.
        final firstLineEnd = _lineEnd(start);
        _warn(
          TextProblemKind.jsonComment,
          start,
          firstLineEnd < pos ? firstLineEnd : pos,
        );
      }
    }
  }

  bool _at(int c) => pos < input.length && input.codeUnitAt(pos) == c;

  /// Records a warning while it leaves room for a later syntax error.
  void _warn(
    TextProblemKind kind,
    int start,
    int end, {
    String? subject,
    int? relatedLine,
  }) {
    if (_problems.length >= limit - 1) return;
    _problems.add(
      TextProblem(
        kind: kind,
        severity: TextProblemSeverity.warning,
        start: start,
        end: end,
        subject: subject,
        relatedLine: relatedLine,
      ),
    );
  }

  /// The 1-based line holding [offset], as the editor's gutter numbers it.
  int _lineOf(int offset) {
    final starts = _lineStarts ??= lineStartOffsets(input);
    var lo = 0;
    var hi = starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
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
bool _isJsonSpace(int c) => c == 0x20 || c == 0x09 || _isLineBreak(c);
bool _isLineBreak(int c) => c == 0x0a || c == 0x0d;
bool _isLiteralTail(int c) =>
    (c >= 0x30 && c <= 0x39) ||
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f;
