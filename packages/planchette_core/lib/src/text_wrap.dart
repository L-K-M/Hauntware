import 'text_columns.dart';
import 'text_document.dart' show LineEnding, textDocumentMaximumBytes;
import 'text_metrics.dart';

const defaultHardWrapColumns = 80;

/// Expansion stopped before exceeding its byte budget; no partial edit escapes.
final class TextWrapLimitExceeded implements Exception {
  const TextWrapLimitExceeded();

  @override
  String toString() => 'Wrapped text exceeds the output limit.';
}

/// Wrap words at text-cell boundaries. Long words are kept intact; a width is
/// a target, not permission to split Unicode clusters or code identifiers.
String hardWrapText(
  String source, {
  required int width,
  required int tabWidth,
  required LineEnding lineEnding,
  required ParagraphWrapMode mode,
  List<String> commentMarkers = const [],
  int maximumBytes = textDocumentMaximumBytes,
}) {
  if (width < 1) throw ArgumentError.value(width, 'width');
  if (tabWidth < 1) throw ArgumentError.value(tabWidth, 'tabWidth');
  if (maximumBytes < 0) throw ArgumentError.value(maximumBytes, 'maximumBytes');
  final insertedBreak = lineEnding == LineEnding.crlf ? '\r\n' : '\n';

  final lines = <({String body, String separator})>[];
  var start = 0;
  for (final match in RegExp(r'\r\n|\n').allMatches(source)) {
    lines.add((
      body: source.substring(start, match.start),
      separator: match.group(0)!,
    ));
    start = match.end;
  }
  lines.add((body: source.substring(start), separator: ''));
  final output = StringBuffer();
  var bytes = 0;
  void write(String value) {
    bytes += utf8EncodedLength(value);
    if (bytes > maximumBytes) throw const TextWrapLimitExceeded();
    output.write(value);
  }

  var pending = <String>[];
  var prefix = '';
  var lastSeparator = '';

  void flush() {
    if (pending.isEmpty) return;
    var first = true;
    for (final line in _wrapWords(pending.join(' '), prefix, width, tabWidth)) {
      if (!first) write(insertedBreak);
      write(line);
      first = false;
    }
    write(lastSeparator);
    pending = [];
  }

  // A list's continuation lines are ambiguous without parsing its language.
  // Leave the entire nonblank run intact rather than flattening list structure.
  var at = 0;
  while (at < lines.length) {
    if (lines[at].body.trim().isEmpty) {
      flush();
      write(lines[at].body);
      write(lines[at++].separator);
      continue;
    }
    var end = at;
    while (end < lines.length && lines[end].body.trim().isNotEmpty) {
      end++;
    }
    if (lines
        .sublist(at, end)
        .any(
          (line) => _listLine.hasMatch(_prefix(line.body, commentMarkers).body),
        )) {
      flush();
      for (final line in lines.sublist(at, end)) {
        write(line.body);
        write(line.separator);
      }
      at = end;
      continue;
    }

    for (; at < end; at++) {
      final parsed = _prefix(lines[at].body, commentMarkers);
      if (mode == ParagraphWrapMode.lines ||
          (pending.isNotEmpty && parsed.prefix != prefix)) {
        flush();
      }
      prefix = parsed.prefix;
      pending.add(parsed.body);
      lastSeparator = lines[at].separator;
      if (mode == ParagraphWrapMode.lines) flush();
    }
    flush();
  }
  flush();
  return output.toString();
}

enum ParagraphWrapMode { fill, lines }

final _listLine = RegExp(r'^\s*(?:[-+*]|\d+[.)])\s+');

({String prefix, String body}) _prefix(String line, List<String> markers) {
  var end = RegExp(r'^[ \t]*').firstMatch(line)!.end;
  while (end < line.length && line[end] == '>') {
    end++;
    while (end < line.length && (line[end] == ' ' || line[end] == '\t')) {
      end++;
    }
  }
  for (final marker in markers) {
    if (!line.startsWith(marker, end)) continue;
    end += marker.length;
    while (end < line.length && (line[end] == ' ' || line[end] == '\t')) {
      end++;
    }
    break;
  }
  return (prefix: line.substring(0, end), body: line.substring(end));
}

Iterable<String> _wrapWords(
  String body,
  String prefix,
  int width,
  int tabWidth,
) sync* {
  final words = body.split(RegExp(r'[ \t]+')).where((word) => word.isNotEmpty);
  final prefixWidth = textColumnAfter(prefix, tabWidth: tabWidth);
  var line = StringBuffer(prefix);
  var column = prefixWidth;
  var hasWord = false;
  for (final word in words) {
    final next = textColumnAfter(
      word,
      initialColumn: column + (hasWord ? 1 : 0),
      tabWidth: tabWidth,
    );
    if (hasWord && next > width) {
      yield line.toString();
      line = StringBuffer(prefix);
      column = prefixWidth;
      hasWord = false;
    }
    if (hasWord) {
      line.write(' ');
      column++;
    }
    line.write(word);
    column = textColumnAfter(word, initialColumn: column, tabWidth: tabWidth);
    hasWord = true;
  }
  yield line.toString();
}
