/// Quick format checks for the editor: the mistakes configuration files most
/// often carry, found without a full parser for each format.
///
/// Each check is one linear scan that reads only as much of its format as it
/// needs, and stays quiet where it cannot be sure: a YAML template whose
/// branches repeat keys, an INI dialect whose keys may repeat, an HTML page
/// that is not XML. Merge-conflict markers are looked for in every document;
/// while any remain they are the only problems reported, since a format check
/// would only trip over them.
///
/// ```text
///   text ──► conflict markers ──► found: report them
///                 │
///                 └─ none ──► TextFormat (from path and language)
///                               json · jsonWithComments · dotenv
///                               yaml · toml · xml · null: nothing more
/// ```
library;

import 'editor_syntax.dart'
    show SyntaxLanguage, SyntaxLanguages, SyntaxTokenType, tokenizeSyntax;
import 'text_json_tools.dart';
import 'text_metrics.dart' show lineStartOffsets;
import 'text_problem.dart';

part 'conflict_markers.dart';
part 'dotenv_validation.dart';
part 'toml_validation.dart';
part 'xml_validation.dart';
part 'yaml_validation.dart';

/// The format whose rules [validateText] checks a document against.
enum TextFormat {
  /// Strict JSON: syntax, repeated keys, comments and trailing commas.
  json,

  /// JSON with comments: syntax and repeated keys.
  jsonWithComments,

  /// Repeated keys and unclosed quoted values.
  dotenv,

  /// Repeated keys in block mappings and tab indentation.
  yaml,

  /// Repeated keys and tables.
  toml,

  /// Tag nesting and repeated attributes.
  xml,
}

/// The format a document at [path], highlighted as [language], is checked
/// as. Null leaves only conflict markers to look for: languages without a
/// dependable quick check, INI dialects such as systemd units and SSH
/// configuration that repeat keys by design, and HTML, which is not XML.
TextFormat? textFormatFor(String path, SyntaxLanguage? language) {
  // Remote paths use POSIX separators; local Windows paths use backslashes.
  final segments = path.toLowerCase().split(RegExp(r'[/\\]'));
  final basename = segments.last;
  final parent = segments.length > 1 ? segments[segments.length - 2] : '';
  final dot = basename.lastIndexOf('.');
  final extension = dot < 0 ? '' : basename.substring(dot + 1);
  return switch (language?.id) {
    'dotenv' => TextFormat.dotenv,
    'json' when _readsJsonComments(basename, parent, extension) =>
      TextFormat.jsonWithComments,
    'json' => TextFormat.json,
    'yaml' => TextFormat.yaml,
    'ini' when extension == 'toml' => TextFormat.toml,
    'xml' when _xmlExtensions.contains(extension) => TextFormat.xml,
    _ => null,
  };
}

/// Problems in [text] read as [format], in document order and at most
/// [textProblemLimit]. Conflict markers are looked for whatever the format.
List<TextProblem> validateText(String text, TextFormat? format) {
  final sink = _ProblemSink(text);
  _findConflictMarkers(text, sink);
  if (sink.problems.isNotEmpty) return sink.problems;

  switch (format) {
    case TextFormat.json:
      return validateJsonText(text, dialect: JsonDialect.strict);
    case TextFormat.jsonWithComments:
      return validateJsonText(text, dialect: JsonDialect.withComments);
    case TextFormat.dotenv:
      _validateDotenv(text, sink);
    case TextFormat.yaml:
      _validateYaml(text, sink);
    case TextFormat.toml:
      _validateToml(text, sink);
    case TextFormat.xml:
      _validateXml(text, sink);
    case null:
      break;
  }
  return sink.problems
    ..sort((a, b) => a.start != b.start ? a.start - b.start : a.end - b.end);
}

/// Extensions the XML language covers that really are XML. `.html` and
/// `.htm` highlight as XML too, but HTML leaves elements open by design.
const _xmlExtensions = {'xml', 'xhtml', 'svg', 'plist'};

/// JSON files that their readers parse with comments and trailing commas:
/// the TypeScript, Deno and Dev Containers configuration files among others.
/// Checked as strict JSON, each of their comments would be flagged.
const _jsonWithCommentsNames = {
  '.devcontainer.json',
  '.eslintrc.json',
  'api-extractor.json',
  'deno.json',
  'devcontainer.json',
  'jsconfig.json',
  'language-configuration.json',
  'tsconfig.json',
  'typedoc.json',
};

/// VS Code's own files, which read comments only in a project's `.vscode`
/// folder or the editor's `User` settings folder: a `settings.json`
/// elsewhere is some other program's.
const _vsCodeNames = {
  'argv.json',
  'extensions.json',
  'keybindings.json',
  'launch.json',
  'settings.json',
  'tasks.json',
};

bool _readsJsonComments(String basename, String parent, String extension) =>
    extension == 'jsonc' ||
    _jsonWithCommentsNames.contains(basename) ||
    // tsconfig.app.json, jsconfig.base.json and other extended configs.
    ((basename.startsWith('tsconfig.') || basename.startsWith('jsconfig.')) &&
        extension == 'json') ||
    (_vsCodeNames.contains(basename) &&
        (parent == '.vscode' || parent == 'user'));

/// Collects problems up to [textProblemLimit] and numbers lines the way the
/// editor's gutter does.
final class _ProblemSink {
  _ProblemSink(this._text);

  final String _text;
  final problems = <TextProblem>[];
  List<int>? _lineStarts;

  bool get isFull => problems.length >= textProblemLimit;

  void add(
    TextProblemKind kind,
    TextProblemSeverity severity,
    int start,
    int end, {
    String? subject,
    String? counterpart,
    int? relatedLine,
    String? detail,
  }) {
    if (isFull || _text.isEmpty) return;
    // Never empty and never past the text, so there is always a glyph to
    // underline and a place to move the caret to.
    final from = start.clamp(0, _text.length - 1);
    problems.add(
      TextProblem(
        kind: kind,
        severity: severity,
        start: from,
        end: end.clamp(from + 1, _text.length),
        subject: subject,
        counterpart: counterpart,
        relatedLine: relatedLine,
        detail: detail,
      ),
    );
  }

  /// The 1-based line holding [offset].
  int lineOf(int offset) {
    final starts = _lineStarts ??= lineStartOffsets(_text);
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

/// Each line of [text] as `(start, end)` offsets, `end` before its `\n` and
/// the `\r` of a CRLF.
Iterable<(int, int)> _lines(String text) sync* {
  var start = 0;
  while (start <= text.length) {
    var newline = text.indexOf('\n', start);
    if (newline < 0) newline = text.length;
    var end = newline;
    if (end > start && text.codeUnitAt(end - 1) == 0x0d) end--;
    yield (start, end);
    start = newline + 1;
  }
}

bool _isBlank(int c) => c == 0x20 || c == 0x09;
