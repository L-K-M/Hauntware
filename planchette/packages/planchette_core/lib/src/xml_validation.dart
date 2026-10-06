part of 'text_validation.dart';

/// An element left open while the scan reads its content.
typedef _XmlElement = ({String name, int start, int end, int line});

/// Flags the ways an edit most often breaks well-formed XML: a closing tag
/// that does not match the open element, an element never closed, a closing
/// tag with nothing open, an attribute given twice, an unquoted or missing
/// attribute value, a bare `<` in text, and a tag, comment or section that
/// never ends. Entities, the characters allowed in names and the single root
/// element are not checked.
///
/// When a closing tag matches an element further out, the elements between
/// are the ones left open, as in `<a><b></a>`: `<b>` is flagged, not `</a>`.
void _validateXml(String text, _ProblemSink sink) {
  final open = <_XmlElement>[];
  var pos = 0;
  while (!sink.isFull) {
    final lt = text.indexOf('<', pos);
    if (lt < 0) break;
    final int? next;
    if (text.startsWith('<!--', lt)) {
      next = _xmlSkip(text, sink, lt, '-->');
    } else if (text.startsWith('<![CDATA[', lt)) {
      next = _xmlSkip(text, sink, lt, ']]>');
    } else if (text.startsWith('<?', lt)) {
      next = _xmlSkip(text, sink, lt, '?>');
    } else if (text.startsWith('<!', lt)) {
      next = _xmlDeclaration(text, sink, lt);
    } else if (text.startsWith('</', lt)) {
      next = _xmlClosingTag(text, sink, lt, open);
    } else {
      next = _xmlStartTag(text, sink, lt, open);
    }
    // A construct that never ends swallows the rest of the document, so
    // nothing after it, open elements included, can be judged.
    if (next == null) return;
    pos = next;
  }
  for (final element in open) {
    sink.add(
      TextProblemKind.unclosedElement,
      TextProblemSeverity.error,
      element.start,
      element.end,
      subject: element.name,
    );
  }
}

/// The offset after [terminator], which ends the construct opening at
/// [start], or null after flagging a construct that never ends.
int? _xmlSkip(String text, _ProblemSink sink, int start, String terminator) {
  final close = text.indexOf(terminator, start + 2);
  if (close >= 0) return close + terminator.length;
  _xmlUnterminated(text, sink, start, switch (terminator) {
    '-->' => 'unterminated comment',
    ']]>' => 'unterminated CDATA section',
    _ => 'unterminated processing instruction',
  });
  return null;
}

/// A `<!DOCTYPE …>` or other declaration, whose internal subset in brackets
/// and quoted literals may hold `>`.
int? _xmlDeclaration(String text, _ProblemSink sink, int start) {
  var depth = 0;
  for (var i = start + 2; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (c == 0x22 || c == 0x27) {
      final close = text.indexOf(String.fromCharCode(c), i + 1);
      if (close < 0) break;
      i = close;
    } else if (c == 0x5b /* [ */ ) {
      depth++;
    } else if (c == 0x5d /* ] */ ) {
      depth--;
    } else if (c == 0x3e /* > */ && depth <= 0) {
      return i + 1;
    }
  }
  _xmlUnterminated(text, sink, start, 'unterminated declaration');
  return null;
}

int _xmlClosingTag(
  String text,
  _ProblemSink sink,
  int start,
  List<_XmlElement> open,
) {
  final nameStart = start + 2;
  final nameEnd = _xmlNameEnd(text, nameStart);
  final close = _xmlSkipSpace(text, nameEnd);
  if (nameEnd == nameStart ||
      close >= text.length ||
      text.codeUnitAt(close) != 0x3e /* > */ ) {
    sink.add(
      TextProblemKind.syntaxError,
      TextProblemSeverity.error,
      start,
      nameEnd,
      detail: "malformed closing tag, expected '>'",
    );
    return nameEnd;
  }
  final name = text.substring(nameStart, nameEnd);
  final match = open.lastIndexWhere((element) => element.name == name);
  if (match < 0) {
    final innermost = open.lastOrNull;
    if (innermost == null) {
      sink.add(
        TextProblemKind.unexpectedClosingTag,
        TextProblemSeverity.error,
        nameStart,
        nameEnd,
        subject: name,
      );
    } else {
      sink.add(
        TextProblemKind.mismatchedClosingTag,
        TextProblemSeverity.error,
        nameStart,
        nameEnd,
        subject: name,
        counterpart: innermost.name,
        relatedLine: innermost.line,
      );
    }
    return close + 1;
  }
  for (final element in open.sublist(match + 1)) {
    sink.add(
      TextProblemKind.unclosedElement,
      TextProblemSeverity.error,
      element.start,
      element.end,
      subject: element.name,
    );
  }
  open.length = match;
  return close + 1;
}

int? _xmlStartTag(
  String text,
  _ProblemSink sink,
  int start,
  List<_XmlElement> open,
) {
  final nameStart = start + 1;
  if (nameStart >= text.length ||
      !_isXmlNameStart(text.codeUnitAt(nameStart))) {
    sink.add(
      TextProblemKind.syntaxError,
      TextProblemSeverity.error,
      start,
      start + 1,
      detail: "'<' in text must be written as &lt;",
    );
    return start + 1;
  }
  final nameEnd = _xmlNameEnd(text, nameStart);
  final name = text.substring(nameStart, nameEnd);
  final attributes = <String>{};
  var pos = nameEnd;
  while (true) {
    pos = _xmlSkipSpace(text, pos);
    if (pos >= text.length) {
      _xmlUnterminated(text, sink, start, 'unterminated tag');
      return null;
    }
    final c = text.codeUnitAt(pos);
    if (c == 0x3e /* > */ ) {
      open.add((
        name: name,
        start: nameStart,
        end: nameEnd,
        line: sink.lineOf(start),
      ));
      return pos + 1;
    }
    if (text.startsWith('/>', pos)) return pos + 2;

    final int problemEnd;
    final String problem;
    if (_isXmlNameStart(c)) {
      final attributeEnd = _xmlNameEnd(text, pos);
      final attribute = text.substring(pos, attributeEnd);
      if (!attributes.add(attribute)) {
        sink.add(
          TextProblemKind.duplicateAttribute,
          TextProblemSeverity.error,
          pos,
          attributeEnd,
          subject: attribute,
        );
      }
      final value = _xmlAttributeValue(text, attributeEnd);
      if (value.problem == null) {
        pos = value.end;
        continue;
      }
      problemEnd = attributeEnd;
      problem = value.problem!;
    } else {
      problemEnd = pos + 1;
      problem = "unexpected character in tag, expected '>' or an attribute";
    }
    // Report once and resume after the tag, so one slip does not flag
    // everything that follows.
    sink.add(
      TextProblemKind.syntaxError,
      TextProblemSeverity.error,
      pos,
      problemEnd,
      detail: problem,
    );
    final close = text.indexOf('>', pos);
    if (close < 0) return null;
    if (text.codeUnitAt(close - 1) != 0x2f /* / */ ) {
      open.add((
        name: name,
        start: nameStart,
        end: nameEnd,
        line: sink.lineOf(start),
      ));
    }
    return close + 1;
  }
}

/// Where the `="value"` after an attribute name ends, or the problem that
/// makes it not one.
({int end, String? problem}) _xmlAttributeValue(String text, int from) {
  var pos = _xmlSkipSpace(text, from);
  if (pos >= text.length || text.codeUnitAt(pos) != 0x3d /* = */ ) {
    return (end: from, problem: 'attribute without a value');
  }
  pos = _xmlSkipSpace(text, pos + 1);
  final quote = pos < text.length ? text.codeUnitAt(pos) : 0;
  if (quote != 0x22 && quote != 0x27) {
    return (end: pos, problem: 'attribute value must be quoted');
  }
  final close = text.indexOf(String.fromCharCode(quote), pos + 1);
  if (close < 0) return (end: pos, problem: 'unterminated attribute value');
  return (end: close + 1, problem: null);
}

/// Flags a construct opening at [start] that runs to the end of the text,
/// underlining its first line.
void _xmlUnterminated(
  String text,
  _ProblemSink sink,
  int start,
  String detail,
) {
  var end = start;
  while (end < text.length && !_isLineBreak(text.codeUnitAt(end))) {
    end++;
  }
  sink.add(
    TextProblemKind.syntaxError,
    TextProblemSeverity.error,
    start,
    end,
    detail: detail,
  );
}

int _xmlNameEnd(String text, int pos) {
  while (pos < text.length && _isXmlNameChar(text.codeUnitAt(pos))) {
    pos++;
  }
  return pos;
}

int _xmlSkipSpace(String text, int pos) {
  while (pos < text.length && _isXmlSpace(text.codeUnitAt(pos))) {
    pos++;
  }
  return pos;
}

bool _isXmlSpace(int c) => _isBlank(c) || _isLineBreak(c);

/// Letters, `_`, `:` and anything outside ASCII, which names may use.
bool _isXmlNameStart(int c) =>
    (c >= 0x41 && c <= 0x5a) ||
    (c >= 0x61 && c <= 0x7a) ||
    c == 0x5f ||
    c == 0x3a ||
    c >= 0x80;

bool _isXmlNameChar(int c) =>
    _isXmlNameStart(c) || (c >= 0x30 && c <= 0x39) || c == 0x2d || c == 0x2e;
