part of 'editor_syntax.dart';

const _diffHeaders = [
  'diff ',
  'index ',
  '--- ',
  '+++ ',
  'new file mode',
  'deleted file mode',
  'old mode',
  'new mode',
  'similarity index',
  'dissimilarity index',
  'rename from',
  'rename to',
  'copy from',
  'copy to',
  'Binary files',
];

/// Unified diffs: file headers as keywords, `@@` hunk headers as meta, added
/// lines as strings and removed lines as numbers, so themes give them
/// distinct colors. Inside a hunk every `+`/`-` line is content, even one
/// that looks like a `+++`/`---` header, until a line that cannot belong to
/// the hunk. Outside hunks, loose `+`/`-` lines still count as changes so
/// pasted fragments without a hunk header read well.
List<SyntaxToken> _tokenizeDiff(String text) {
  final tokens = <SyntaxToken>[];
  var inHunk = false;
  var start = 0;
  while (start < text.length) {
    var end = text.indexOf('\n', start);
    if (end < 0) end = text.length;
    final first = start < end ? text.codeUnitAt(start) : null;
    SyntaxTokenType? type;
    if (text.startsWith('@@', start)) {
      inHunk = true;
      type = SyntaxTokenType.meta;
    } else if (inHunk &&
        (first == null ||
            first == 0x20 ||
            first == 0x2b ||
            first == 0x2d ||
            first == 0x5c)) {
      type = _diffChange(first);
    } else {
      inHunk = false;
      if (_diffHeaders.any((header) => text.startsWith(header, start))) {
        type = SyntaxTokenType.keyword;
      } else {
        type = _diffChange(first);
      }
    }
    if (type != null && end > start) {
      tokens.add(SyntaxToken(start, end, type));
    }
    start = end + 1;
  }
  return tokens;
}

SyntaxTokenType? _diffChange(int? first) => switch (first) {
  0x2b /* + */ => SyntaxTokenType.string,
  0x2d /* - */ => SyntaxTokenType.number,
  0x5c /* \ */ => SyntaxTokenType.comment,
  _ => null,
};
