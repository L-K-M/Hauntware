/// How much a [TextProblem] matters.
enum TextProblemSeverity {
  /// The file does not load as its format: a syntax error, or a repeat that
  /// a strict format rejects.
  error,

  /// The file loads, but probably not as meant: a key set twice that most
  /// readers settle by keeping the last, or a construct only lenient readers
  /// accept.
  warning,
}

/// What a [TextProblem] reports. Hosts word each kind in their own language.
enum TextProblemKind {
  /// The text does not parse. [TextProblem.detail] is the parser's English
  /// explanation, such as "expected ',' or '}'".
  syntaxError,

  /// A key set again in one object, mapping, table or file. [TextProblem.subject]
  /// is the key and [TextProblem.relatedLine] the line that set it first.
  duplicateKey,

  /// A TOML table declared again. [TextProblem.subject] is the table and
  /// [TextProblem.relatedLine] the line that declared it first.
  duplicateTable,

  /// An XML attribute given twice in one tag. [TextProblem.subject] is the
  /// attribute.
  duplicateAttribute,

  /// A comment in a JSON file whose readers may not accept comments.
  jsonComment,

  /// A comma before a closing bracket in a JSON file whose readers may not
  /// accept one.
  jsonTrailingComma,

  /// A quoted value whose closing quote never comes, so it runs to the end
  /// of the file.
  unterminatedQuote,

  /// A YAML line indented with a tab, which YAML forbids.
  tabIndentation,

  /// An XML closing tag that does not close the element open there.
  /// [TextProblem.subject] is the closing tag's name, [TextProblem.counterpart]
  /// the open element's and [TextProblem.relatedLine] the line it opened on.
  mismatchedClosingTag,

  /// An XML element that is never closed. [TextProblem.subject] is its name.
  unclosedElement,

  /// An XML closing tag with no element open. [TextProblem.subject] is its
  /// name.
  unexpectedClosingTag,

  /// Version-control conflict markers left in the file: `<<<<<<<`, `=======`
  /// and `>>>>>>>`.
  mergeConflict,
}

/// Validation stops counting here, so a file broken on every line costs a
/// bounded scan and a bounded set of underlines.
const int textProblemLimit = 100;

/// One problem found in a document, for the editor to underline, count and
/// describe.
final class TextProblem {
  const TextProblem({
    required this.kind,
    required this.severity,
    required this.start,
    required this.end,
    this.subject,
    this.counterpart,
    this.relatedLine,
    this.detail,
  });

  final TextProblemKind kind;
  final TextProblemSeverity severity;

  /// The flagged text, `[start, end)` in UTF-16 offsets; never empty.
  final int start;
  final int end;

  /// The key, table, attribute or element the problem is about.
  final String? subject;

  /// The element a mismatched closing tag should have closed.
  final String? counterpart;

  /// The 1-based line of the earlier definition or the opening tag.
  final int? relatedLine;

  /// A parser's English explanation of a syntax error.
  final String? detail;

  /// The same problem [delta] code units further on, for text an edit moved.
  TextProblem moved(int delta) => TextProblem(
    kind: kind,
    severity: severity,
    start: start + delta,
    end: end + delta,
    subject: subject,
    counterpart: counterpart,
    relatedLine: relatedLine,
    detail: detail,
  );

  @override
  bool operator ==(Object other) =>
      other is TextProblem &&
      other.kind == kind &&
      other.severity == severity &&
      other.start == start &&
      other.end == end &&
      other.subject == subject &&
      other.counterpart == counterpart &&
      other.relatedLine == relatedLine &&
      other.detail == detail;

  @override
  int get hashCode => Object.hash(
    kind,
    severity,
    start,
    end,
    subject,
    counterpart,
    relatedLine,
    detail,
  );

  @override
  String toString() =>
      'TextProblem(${kind.name}, ${severity.name}, $start, $end'
      '${subject == null ? '' : ', $subject'}'
      '${counterpart == null ? '' : ', $counterpart'}'
      '${relatedLine == null ? '' : ', line $relatedLine'}'
      '${detail == null ? '' : ', $detail'})';
}
