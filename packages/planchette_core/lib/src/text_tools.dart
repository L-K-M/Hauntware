import 'dart:convert';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import 'editor_syntax.dart' show isWordRune;
import 'indentation.dart';
import 'line_operations.dart';

// Text-transform tools, the BBEdit-style "Text" menu: a catalog of pure
// functions over the buffer, generated into menu, palette and options-bar
// entries by the host. The design — scope rules, separator handling, the
// outcome contract — lives in docs/TEXT_TOOLS.md.

/// What a tool applies to when nothing is selected. A non-collapsed
/// selection is always the target instead.
enum TextToolScope {
  /// The whole document.
  document,

  /// The paragraph — the run of non-blank lines — holding the caret.
  paragraph,

  /// The word the caret is inside or touches.
  word,

  /// Nothing: the tool reports that it needs a selection.
  selection,

  /// The caret itself: an insertion tool writes there and a selection is
  /// replaced.
  insertion,
}

/// The submenu a tool lives under, in menu order.
enum TextToolGroup {
  lines,
  changeCase,
  whitespace,
  cleanUp,
  wrap,
  encode,
  insert,
}

/// What a run's range was resolved from. The result notice phrases scope
/// from it, and tools use it to keep a caret rather than reselect.
enum TextToolRanOn { selection, document, paragraph, word, caret }

/// Why a run did not apply.
enum TextToolRefusal {
  /// The tool needs a selection and there was none.
  nothingSelected,

  /// A word-scope tool found no word at the caret.
  noWordAtCaret,

  /// A decoder produced bytes that are not valid UTF-8 text.
  resultNotText,

  /// The result would exceed the document's size limit.
  tooLarge,

  /// The file format mandates tab indentation (Makefile, Go).
  requiresTabs,
}

/// What a run did. Only [TextToolChanged] touches the buffer; a tool that
/// found nothing or could not run says so rather than claiming an edit.
sealed class TextToolOutcome {
  const TextToolOutcome();
}

/// The run changed the buffer.
final class TextToolChanged extends TextToolOutcome {
  const TextToolChanged(
    this.edit, {
    required this.changed,
    required this.scope,
    this.indentation,
    this.detail,
  });

  /// The new buffer and the selection to put on it.
  final LineEdit edit;

  /// How many of the tool's units changed — lines moved, removed or
  /// rewritten, characters replaced, bytes inserted — for the notice.
  final int changed;

  /// How many units the run covered, in the same unit as [changed].
  final int scope;

  /// An indentation setting the run adopts for the document, beyond the
  /// edit itself. Undo does not restore it.
  final Indentation? indentation;

  /// A discriminator the notice can phrase on, such as the Zap Gremlins
  /// action taken.
  final String? detail;
}

/// The run found nothing to change. [scope] says how much it looked at.
final class TextToolUnchanged extends TextToolOutcome {
  const TextToolUnchanged({this.scope = 0, this.indentation});

  final int scope;

  /// An indentation setting the run adopts even without an edit; the
  /// conversion commands set the document's setting whether or not any
  /// line needed it.
  final Indentation? indentation;
}

/// The run did not apply; [reason] says why, in a way the notice can show.
final class TextToolRefused extends TextToolOutcome {
  const TextToolRefused(this.reason);

  final TextToolRefusal reason;
}

/// A finished run, kept by the editor for the result notice.
final class TextToolReport {
  const TextToolReport({
    required this.tool,
    required this.outcome,
    required this.ranOn,
  });

  final TextTool tool;
  final TextToolOutcome outcome;
  final TextToolRanOn ranOn;
}

/// A declared option. The options bar renders each kind from its type; the
/// label comes from the host's strings, keyed by option id.
sealed class TextToolOption {
  const TextToolOption(this.id, this.defaultValue);

  /// The option's key in a run's options map, stable across releases.
  final String id;

  /// The value a run gets when nothing overrides it.
  final Object defaultValue;
}

/// A checkbox option.
final class ToggleOption extends TextToolOption {
  const ToggleOption(String id, {bool value = false}) : super(id, value);
}

/// A single-choice option, rendered as a picker or a dropdown.
final class ChoiceOption extends TextToolOption {
  const ChoiceOption(String id, this.choices, {required String value})
    : super(id, value);

  /// The choice ids, in shown order.
  final List<String> choices;
}

/// A free-text option, rendered as a field.
final class TextOption extends TextToolOption {
  const TextOption(String id, {String value = ''}) : super(id, value);
}

/// A whole-number option, rendered as a field or stepper.
final class IntegerOption extends TextToolOption {
  const IntegerOption(String id, {int value = 0, this.min = 0})
    : super(id, value);

  /// The smallest accepted value.
  final int min;
}

/// What a tool needs from the host beyond the text.
final class TextToolContext {
  TextToolContext({
    required this.fold,
    required this.indentation,
    this.indentationPreference,
    this.displayPath = '',
    DateTime Function()? now,
    math.Random? random,
  }) : now = now ?? DateTime.now,
       random = random ?? _defaultRandom;

  /// The find bar's case folder: the shared one keeps a case-insensitive
  /// tool and a case-insensitive find on the same alphabet.
  final String Function(String) fold;

  /// The document's indentation, as Tab would use it.
  final Indentation indentation;

  /// The host's preference for files that have none: the width a
  /// tab-indented file converts to.
  final Indentation? indentationPreference;

  /// The document's display path, for formats that mandate indentation.
  final String displayPath;

  /// The clock insertions read; injectable for tests.
  final DateTime Function() now;

  /// The random source Shuffle reads; injectable for tests.
  final math.Random random;
}

final _defaultRandom = math.Random();

/// One invocation of a tool.
final class TextToolRun {
  const TextToolRun({
    required this.text,
    required this.base,
    required this.extent,
    required this.caret,
    required this.ranOn,
    required this.options,
    required this.context,
  });

  /// The whole buffer; [base] and [extent] index into it.
  final String text;

  /// The resolved range: the selection, or the tool's [TextToolScope]
  /// when the selection was collapsed. A line-oriented tool widens it to
  /// touched lines itself.
  final int base;
  final int extent;

  /// The original caret — the selection's extent — so a tool can keep it
  /// rather than select its result.
  final int caret;

  /// What the range was resolved from.
  final TextToolRanOn ranOn;

  /// Every declared option of the tool, the caller's values over the
  /// declared defaults.
  final Map<String, Object?> options;

  final TextToolContext context;

  /// Option [id], read as the declared type.
  T option<T>(String id) => options[id] as T;
}

/// A catalog entry: identity, grouping, scope and the transform itself.
/// Display names, keywords and option labels come from the host's strings,
/// keyed by [TextTool.id].
final class TextTool {
  const TextTool({
    required this.id,
    required this.group,
    required this.scope,
    this.options = const [],
    required this.run,
  });

  /// The stable identifier menus, palette entries, history and
  /// EditorStrings keys are built from.
  final String id;

  /// The submenu it lives under.
  final TextToolGroup group;

  /// What it applies to when nothing is selected.
  final TextToolScope scope;

  /// Declared options, in shown order.
  final List<TextToolOption> options;

  /// The transform. Returns an outcome rather than editing in place so the
  /// caller can preflight size, record the result and map the selection.
  final TextToolOutcome Function(TextToolRun run) run;
}

/// The catalog, in menu order. Menus, the palette and the options bar are
/// generated from this list; nothing else decides what exists.
const textToolCatalog = <TextTool>[
  // Lines
  TextTool(
    id: 'sortLines',
    group: TextToolGroup.lines,
    scope: TextToolScope.document,
    options: [
      ChoiceOption('order', ['ascending', 'descending'], value: 'ascending'),
      ToggleOption('ignoreCase', value: true),
      ToggleOption('numbersByValue'),
      ToggleOption('byLength'),
      ToggleOption('ignoreLeadingWhitespace'),
      ToggleOption('keepFirstLine'),
    ],
    run: _sortLines,
  ),
  TextTool(
    id: 'reverseLines',
    group: TextToolGroup.lines,
    scope: TextToolScope.document,
    run: _reverseLines,
  ),
  TextTool(
    id: 'shuffleLines',
    group: TextToolGroup.lines,
    scope: TextToolScope.document,
    run: _shuffleLines,
  ),
  TextTool(
    id: 'removeDuplicateLines',
    group: TextToolGroup.lines,
    scope: TextToolScope.document,
    options: [
      ToggleOption('adjacentOnly'),
      ToggleOption('ignoreCase'),
      ToggleOption('ignoreSurroundingWhitespace'),
      ToggleOption('keepBlankLines', value: true),
      ToggleOption('removeEveryCopy'),
    ],
    run: _removeDuplicateLines,
  ),
  TextTool(
    id: 'removeBlankLines',
    group: TextToolGroup.lines,
    scope: TextToolScope.document,
    run: _removeBlankLines,
  ),
  TextTool(
    id: 'collapseBlankLines',
    group: TextToolGroup.lines,
    scope: TextToolScope.document,
    run: _collapseBlankLines,
  ),
  TextTool(
    id: 'prefixSuffixLines',
    group: TextToolGroup.lines,
    scope: TextToolScope.document,
    options: [
      ChoiceOption('mode', ['insert', 'remove'], value: 'insert'),
      ChoiceOption('where', ['prefix', 'suffix'], value: 'prefix'),
      TextOption('text'),
      ToggleOption('skipBlankLines', value: true),
    ],
    run: _prefixSuffixLines,
  ),
  TextTool(
    id: 'numberLines',
    group: TextToolGroup.lines,
    scope: TextToolScope.document,
    options: [
      ChoiceOption('mode', ['add', 'remove'], value: 'add'),
      IntegerOption('start', value: 1),
      IntegerOption('step', value: 1, min: 1),
      TextOption('separator', value: '. '),
      ChoiceOption('padding', ['none', 'spaces', 'zeros'], value: 'none'),
    ],
    run: _numberLines,
  ),

  // Case
  TextTool(
    id: 'uppercase',
    group: TextToolGroup.changeCase,
    scope: TextToolScope.word,
    run: _toUppercase,
  ),
  TextTool(
    id: 'lowercase',
    group: TextToolGroup.changeCase,
    scope: TextToolScope.word,
    run: _toLowercase,
  ),
  TextTool(
    id: 'titleCase',
    group: TextToolGroup.changeCase,
    scope: TextToolScope.word,
    run: _toTitleCase,
  ),
  TextTool(
    id: 'sentenceCase',
    group: TextToolGroup.changeCase,
    scope: TextToolScope.word,
    run: _toSentenceCase,
  ),
  TextTool(
    id: 'camelCase',
    group: TextToolGroup.changeCase,
    scope: TextToolScope.word,
    run: _toCamelCase,
  ),
  TextTool(
    id: 'pascalCase',
    group: TextToolGroup.changeCase,
    scope: TextToolScope.word,
    run: _toPascalCase,
  ),
  TextTool(
    id: 'snakeCase',
    group: TextToolGroup.changeCase,
    scope: TextToolScope.word,
    run: _toSnakeCase,
  ),
  TextTool(
    id: 'kebabCase',
    group: TextToolGroup.changeCase,
    scope: TextToolScope.word,
    run: _toKebabCase,
  ),
  TextTool(
    id: 'constantCase',
    group: TextToolGroup.changeCase,
    scope: TextToolScope.word,
    run: _toConstantCase,
  ),

  // Whitespace
  TextTool(
    id: 'trimTrailingWhitespace',
    group: TextToolGroup.whitespace,
    scope: TextToolScope.document,
    run: _trimTrailingWhitespace,
  ),
  TextTool(
    id: 'trimLeadingWhitespace',
    group: TextToolGroup.whitespace,
    scope: TextToolScope.document,
    run: _trimLeadingWhitespace,
  ),
  TextTool(
    id: 'normalizeSpaces',
    group: TextToolGroup.whitespace,
    scope: TextToolScope.document,
    run: _normalizeSpaces,
  ),
  TextTool(
    id: 'convertIndentationToSpaces',
    group: TextToolGroup.whitespace,
    scope: TextToolScope.document,
    run: _indentationToSpaces,
  ),
  TextTool(
    id: 'convertIndentationToTabs',
    group: TextToolGroup.whitespace,
    scope: TextToolScope.document,
    run: _indentationToTabs,
  ),

  // Clean Up
  TextTool(
    id: 'zapGremlins',
    group: TextToolGroup.cleanUp,
    scope: TextToolScope.document,
    options: [
      ToggleOption('controls', value: true),
      ToggleOption('invisible', value: true),
      ToggleOption('bidi', value: true),
      ToggleOption('damaged'),
      ToggleOption('nonAscii'),
      ChoiceOption('action', [
        'delete',
        'escape',
        'replace',
        'entity',
      ], value: 'delete'),
      TextOption('character', value: '?'),
    ],
    run: _zapGremlins,
  ),
  TextTool(
    id: 'straightenQuotes',
    group: TextToolGroup.cleanUp,
    scope: TextToolScope.document,
    run: _straightenQuotes,
  ),
  TextTool(
    id: 'removeAnsiEscapes',
    group: TextToolGroup.cleanUp,
    scope: TextToolScope.document,
    run: _removeAnsiEscapes,
  ),

  // Wrap
  TextTool(
    id: 'unwrapParagraphs',
    group: TextToolGroup.wrap,
    scope: TextToolScope.paragraph,
    run: _unwrapParagraphs,
  ),
  TextTool(
    id: 'joinLinesWith',
    group: TextToolGroup.wrap,
    scope: TextToolScope.selection,
    options: [
      TextOption('separator', value: ', '),
      ToggleOption('trim', value: true),
      ToggleOption('skipBlankLines', value: true),
    ],
    run: _joinLinesWith,
  ),

  // Encode
  TextTool(
    id: 'urlEncode',
    group: TextToolGroup.encode,
    scope: TextToolScope.selection,
    run: _urlEncode,
  ),
  TextTool(
    id: 'urlDecode',
    group: TextToolGroup.encode,
    scope: TextToolScope.selection,
    run: _urlDecode,
  ),
  TextTool(
    id: 'base64Encode',
    group: TextToolGroup.encode,
    scope: TextToolScope.selection,
    run: _base64Encode,
  ),
  TextTool(
    id: 'base64Decode',
    group: TextToolGroup.encode,
    scope: TextToolScope.selection,
    run: _base64Decode,
  ),
  TextTool(
    id: 'htmlEntityEncode',
    group: TextToolGroup.encode,
    scope: TextToolScope.selection,
    run: _htmlEntityEncode,
  ),
  TextTool(
    id: 'htmlEntityDecode',
    group: TextToolGroup.encode,
    scope: TextToolScope.selection,
    run: _htmlEntityDecode,
  ),
  TextTool(
    id: 'escapeJsonString',
    group: TextToolGroup.encode,
    scope: TextToolScope.selection,
    run: _escapeJsonString,
  ),
  TextTool(
    id: 'unescapeBackslashSequences',
    group: TextToolGroup.encode,
    scope: TextToolScope.selection,
    run: _unescapeBackslashSequences,
  ),

  // Insert
  TextTool(
    id: 'insertDate',
    group: TextToolGroup.insert,
    scope: TextToolScope.insertion,
    run: _insertDate,
  ),
  TextTool(
    id: 'insertDateTime',
    group: TextToolGroup.insert,
    scope: TextToolScope.insertion,
    run: _insertDateTime,
  ),
  TextTool(
    id: 'insertUtcTimestamp',
    group: TextToolGroup.insert,
    scope: TextToolScope.insertion,
    run: _insertUtcTimestamp,
  ),
  TextTool(
    id: 'insertUuid',
    group: TextToolGroup.insert,
    scope: TextToolScope.insertion,
    run: _insertUuid,
  ),
];

/// The catalog entry for [id], or null.
TextTool? textToolById(String id) {
  for (final tool in textToolCatalog) {
    if (tool.id == id) return tool;
  }
  return null;
}

/// The range a run of [tool] on `[base, extent)` acts on, and what it was
/// resolved from: the selection when there is one, else the tool's
/// [TextToolScope]. When that scope's target does not exist — no word at
/// the caret, nothing selected — [refusal] is set and the other fields
/// point at the caret.
({
  int base,
  int extent,
  int caret,
  TextToolRanOn ranOn,
  TextToolRefusal? refusal,
})
resolveTextToolRange(
  TextTool tool,
  String text,
  int base,
  int extent, {
  bool wholeDocument = false,
}) {
  RangeError.checkValueInInterval(base, 0, text.length, 'base');
  RangeError.checkValueInInterval(extent, 0, text.length, 'extent');
  if (base != extent && !wholeDocument) {
    return (
      base: base,
      extent: extent,
      caret: extent,
      ranOn: TextToolRanOn.selection,
      refusal: null,
    );
  }
  return switch (wholeDocument ? TextToolScope.document : tool.scope) {
    TextToolScope.document => (
      base: 0,
      extent: text.length,
      caret: extent,
      ranOn: TextToolRanOn.document,
      refusal: null,
    ),
    TextToolScope.paragraph => () {
      final paragraph = paragraphRange(text, extent);
      return (
        base: paragraph.start,
        extent: paragraph.end,
        caret: extent,
        ranOn: TextToolRanOn.paragraph,
        refusal: null,
      );
    }(),
    TextToolScope.word => () {
      final word = wordRange(text, extent);
      return (
        base: word?.start ?? extent,
        extent: word?.end ?? extent,
        caret: extent,
        ranOn: TextToolRanOn.word,
        refusal: word == null ? TextToolRefusal.noWordAtCaret : null,
      );
    }(),
    TextToolScope.selection => (
      base: extent,
      extent: extent,
      caret: extent,
      ranOn: TextToolRanOn.selection,
      refusal: TextToolRefusal.nothingSelected,
    ),
    TextToolScope.insertion => (
      base: extent,
      extent: extent,
      caret: extent,
      ranOn: TextToolRanOn.caret,
      refusal: null,
    ),
  };
}

// ── Range resolution ──────────────────────────────────────────────────

/// The paragraph at [offset]: the run of non-blank lines around it, as a
/// line-aligned range. A paragraph is bounded by blank lines (empty or
/// spaces and tabs only) or the buffer's ends.
({int start, int end}) paragraphRange(String text, int offset) {
  RangeError.checkValueInInterval(offset, 0, text.length, 'offset');
  var start = lineStart(text, offset);
  var end = lineContentEnd(text, offset);
  while (start > 0) {
    final previousEnd = start - lineSeparatorBefore(text, start).length;
    final previousStart = lineStart(text, previousEnd);
    if (_isBlankRange(text, previousStart, previousEnd)) break;
    start = previousStart;
  }
  while (end < text.length) {
    final nextStart = end + lineSeparatorAt(text, end).length;
    final nextEnd = lineContentEnd(text, nextStart);
    if (_isBlankRange(text, nextStart, nextEnd)) break;
    end = nextEnd;
  }
  return (start: start, end: end);
}

/// The word the caret is inside or touches, or null when neither neighbour
/// is a word character. The word before the caret wins, so a caret right
/// after a word still acts on it.
({int start, int end})? wordRange(String text, int offset) {
  RangeError.checkValueInInterval(offset, 0, text.length, 'offset');
  if (offset > 0 && isWordRune(_runeBefore(text, offset))) {
    var start = _runeStartBefore(text, offset);
    var end = offset;
    while (start > 0 && isWordRune(_runeBefore(text, start))) {
      start = _runeStartBefore(text, start);
    }
    while (end < text.length && isWordRune(_runeAt(text, end))) {
      end += _runeLength(text.codeUnitAt(end));
    }
    return (start: start, end: end);
  }
  if (offset < text.length && isWordRune(_runeAt(text, offset))) {
    var end = offset + _runeLength(text.codeUnitAt(offset));
    while (end < text.length && isWordRune(_runeAt(text, end))) {
      end += _runeLength(text.codeUnitAt(end));
    }
    return (start: offset, end: end);
  }
  return null;
}

// ── Outcome plumbing ──────────────────────────────────────────────────

/// One replacement of `[start, end)` with [insert], applied in a batch.
typedef _Edit = ({int start, int end, String insert});

/// Applies sorted, non-overlapping [edits] and returns the new text plus a
/// mapper carrying offsets from old to new: an offset inside an edit lands
/// at the end of its replacement, an offset after it shifts by the delta.
(String, int Function(int offset)) _applyEdits(String text, List<_Edit> edits) {
  final result = StringBuffer();
  var copied = 0;
  for (final edit in edits) {
    result
      ..write(text.substring(copied, edit.start))
      ..write(edit.insert);
    copied = edit.end;
  }
  result.write(text.substring(copied));
  final newText = result.toString();

  int map(int offset) {
    var shift = 0;
    for (final edit in edits) {
      if (offset <= edit.start) break;
      if (offset < edit.end) {
        return edit.start + shift + edit.insert.length;
      }
      shift += edit.insert.length - (edit.end - edit.start);
    }
    return offset + shift;
  }

  return (newText, map);
}

/// The outcome for a batch of small replacements: a selection is mapped
/// through so it still covers what it selected; a caret inside an edit
/// lands at the replacement's end.
TextToolOutcome _spanEdit(
  TextToolRun run,
  List<_Edit> edits, {
  required int changed,
  required int scope,
  Indentation? indentation,
  String? detail,
}) {
  // A zero-width empty replacement writes nothing — deleting the last
  // blank line of an empty buffer leaves it, for instance.
  edits.removeWhere((e) => e.end == e.start && e.insert.isEmpty);
  if (edits.isEmpty) {
    return TextToolUnchanged(scope: scope, indentation: indentation);
  }
  final (newText, map) = _applyEdits(run.text, edits);
  final LineEdit edit;
  if (run.ranOn == TextToolRanOn.selection) {
    edit = LineEdit(newText, map(run.base), map(run.extent));
  } else {
    final caret = map(run.caret);
    edit = LineEdit(newText, caret, caret);
  }
  return TextToolChanged(
    edit,
    changed: changed,
    scope: scope,
    indentation: indentation,
    detail: detail,
  );
}

/// The outcome for replacing a whole line-aligned block: a selection grows
/// to cover the result, direction kept; a caret keeps its place in the
/// block or shifts with the length delta.
TextToolOutcome _blockEdit(
  TextToolRun run,
  int start,
  int end,
  String replacement, {
  required int changed,
  required int scope,
  Indentation? indentation,
  String? detail,
}) {
  final newText = run.text.replaceRange(start, end, replacement);
  if (run.ranOn == TextToolRanOn.selection) {
    final blockEnd = start + replacement.length;
    return TextToolChanged(
      LineEdit(
        newText,
        run.base < run.extent ? start : blockEnd,
        run.base < run.extent ? blockEnd : start,
      ),
      changed: changed,
      scope: scope,
      indentation: indentation,
      detail: detail,
    );
  }
  final delta = replacement.length - (end - start);
  final int mapped;
  if (run.caret <= start) {
    mapped = run.caret;
  } else if (run.caret >= end) {
    mapped = run.caret + delta;
  } else {
    final inside = run.caret - start;
    mapped =
        start + (inside > replacement.length ? replacement.length : inside);
  }
  var caret = mapped;
  if (caret > 0 &&
      caret < newText.length &&
      _isLowSurrogate(newText.codeUnitAt(caret))) {
    caret--;
  }
  return TextToolChanged(
    LineEdit(newText, caret, caret),
    changed: changed,
    scope: scope,
    indentation: indentation,
    detail: detail,
  );
}

// ── Line-range plumbing ───────────────────────────────────────────────

/// A line-aligned slice of the buffer, split into contents and breaks.
final class _Lines {
  const _Lines._(
    this.starts,
    this.contents,
    this.breaks,
    this.end,
    this.breakAfter,
  );

  /// The offset where each line starts.
  final List<int> starts;
  final List<String> contents;

  /// The break after each line except the range's last, which keeps its
  /// break outside the range.
  final List<String> breaks;

  /// The content end of the last line.
  final int end;

  /// The break right after [end], empty at the end of the buffer.
  final String breakAfter;

  int get start => starts.first;
}

/// Splits the line-aligned range `[start, end)` into per-line starts and
/// contents plus the breaks between them.
_Lines _linesOf(String text, int start, int end) {
  final starts = <int>[], contents = <String>[], breaks = <String>[];
  var at = start;
  while (true) {
    final e = lineContentEnd(text, at);
    starts.add(at);
    contents.add(text.substring(at, e));
    if (e >= end) break;
    final separator = lineSeparatorAt(text, e);
    breaks.add(separator);
    at = e + separator.length;
  }
  return _Lines._(starts, contents, breaks, end, lineSeparatorAt(text, end));
}

/// Reassembles a block from contents on the break slots — ordering tools
/// permute contents, so breaks stay where they were.
String _joinLines(List<String> contents, List<String> breaks) {
  final result = StringBuffer();
  for (var i = 0; i < contents.length; i++) {
    result.write(contents[i]);
    if (i < breaks.length) result.write(breaks[i]);
  }
  return result.toString();
}

/// The edits deleting the lines [remove] marks.
///
/// Each removed line takes the break that ends it. The range's last line
/// has no break inside the range, so it takes the break after the range,
/// or — at the end of the buffer — the one before it, the same rule
/// [deleteLines] follows.
List<_Edit> _lineDeletions(_Lines block, List<bool> remove) {
  final edits = <_Edit>[];
  final n = block.contents.length;
  var i = 0;
  while (i < n) {
    if (!remove[i]) {
      i++;
      continue;
    }
    var j = i;
    while (j + 1 < n && remove[j + 1]) {
      j++;
    }
    final int from;
    final int to;
    if (j < n - 1) {
      (from, to) = (block.starts[i], block.starts[j + 1]);
    } else if (block.breakAfter.isNotEmpty) {
      (from, to) = (block.starts[i], block.end + block.breakAfter.length);
    } else if (i > 0) {
      (from, to) = (block.starts[i] - block.breaks[i - 1].length, block.end);
    } else {
      (from, to) = (block.start, block.end);
    }
    edits.add((start: from, end: to, insert: ''));
    i = j + 1;
  }
  return edits;
}

// ── Character helpers ─────────────────────────────────────────────────

const int _tabUnit = 0x09;
const int _spaceUnit = 0x20;
const int _newlineUnit = 0x0a;
const int _returnUnit = 0x0d;

/// Whether the range's units are only spaces and tabs — a blank line.
bool _isBlankRange(String text, int start, int end) {
  for (var i = start; i < end; i++) {
    final unit = text.codeUnitAt(i);
    if (unit != _spaceUnit && unit != _tabUnit) return false;
  }
  return true;
}

/// Whether [unit] is a space or a tab: indentation and trailing
/// whitespace are these, no wider whitespace class.
bool _isSpaceOrTab(int unit) => unit == _spaceUnit || unit == _tabUnit;

int _runeAt(String text, int index) {
  final unit = text.codeUnitAt(index);
  if (_isHighSurrogate(unit) && index + 1 < text.length) {
    final low = text.codeUnitAt(index + 1);
    if (_isLowSurrogate(low)) return _combine(unit, low);
  }
  return unit;
}

int _runeBefore(String text, int index) {
  final unit = text.codeUnitAt(index - 1);
  if (_isLowSurrogate(unit) && index >= 2) {
    final high = text.codeUnitAt(index - 2);
    if (_isHighSurrogate(high)) return _combine(high, unit);
  }
  return unit;
}

/// The offset where the rune ending at [index] starts: two back for a
/// surrogate pair, one otherwise.
int _runeStartBefore(String text, int index) {
  if (index >= 2 &&
      _isLowSurrogate(text.codeUnitAt(index - 1)) &&
      _isHighSurrogate(text.codeUnitAt(index - 2))) {
    return index - 2;
  }
  return index - 1;
}

int _combine(int high, int low) =>
    0x10000 + ((high - 0xd800) << 10) + (low - 0xdc00);

/// The code units a rune takes from its lead unit.
int _runeLength(int unit) => unit >= 0xd800 && unit <= 0xdbff ? 2 : 1;

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;
bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

// ── Comparators ───────────────────────────────────────────────────────

/// Orders two strings by code point, so `Ä` sorts after `Z` the way a
/// bytewise UTF-8 comparison would — the plan's documented quirk.
int _compareCodePoints(String a, String b) {
  final runesA = a.runes.iterator;
  final runesB = b.runes.iterator;
  while (true) {
    final hasA = runesA.moveNext();
    final hasB = runesB.moveNext();
    if (!hasA) return hasB ? -1 : 0;
    if (!hasB) return 1;
    if (runesA.current != runesB.current) {
      return runesA.current.compareTo(runesB.current);
    }
  }
}

/// Orders two strings like [_compareCodePoints], except runs of ASCII
/// digits compare by value — `file2` before `file10`. Equal-valued runs
/// fall back to their literal order, so `01` and `1` are stable.
int _compareNatural(String a, String b) {
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    final unitA = a.codeUnitAt(i);
    final unitB = b.codeUnitAt(j);
    if (_isDigit(unitA) && _isDigit(unitB)) {
      var digitsA = i;
      var digitsB = j;
      while (digitsA < a.length && _isDigit(a.codeUnitAt(digitsA))) {
        digitsA++;
      }
      while (digitsB < b.length && _isDigit(b.codeUnitAt(digitsB))) {
        digitsB++;
      }
      var valueA = i;
      var valueB = j;
      while (valueA < digitsA && a.codeUnitAt(valueA) == 0x30) {
        valueA++;
      }
      while (valueB < digitsB && b.codeUnitAt(valueB) == 0x30) {
        valueB++;
      }
      final lengthA = digitsA - valueA;
      final lengthB = digitsB - valueB;
      if (lengthA != lengthB) return lengthA.compareTo(lengthB);
      for (var k = 0; k < lengthA; k++) {
        final digit = a
            .codeUnitAt(valueA + k)
            .compareTo(b.codeUnitAt(valueB + k));
        if (digit != 0) return digit;
      }
      i = digitsA;
      j = digitsB;
      continue;
    }
    final runeA = _runeAt(a, i);
    final runeB = _runeAt(b, j);
    if (runeA != runeB) return runeA.compareTo(runeB);
    i += _runeLength(unitA);
    j += _runeLength(unitB);
  }
  return (a.length - i).compareTo(b.length - j);
}

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

// ── Lines ─────────────────────────────────────────────────────────────

/// The lines' comparison keys after the declared sort options.
List<String> _sortKeys(TextToolRun run, List<String> lines) {
  final ignoreLeading = run.option<bool>('ignoreLeadingWhitespace');
  final ignoreCase = run.option<bool>('ignoreCase');
  return [
    for (final line in lines)
      ignoreCase
          ? run.context.fold(ignoreLeading ? _withoutIndent(line) : line)
          : ignoreLeading
          ? _withoutIndent(line)
          : line,
  ];
}

/// [line] without its leading spaces and tabs.
String _withoutIndent(String line) {
  var at = 0;
  while (at < line.length && _isSpaceOrTab(line.codeUnitAt(at))) {
    at++;
  }
  return line.substring(at);
}

TextToolOutcome _sortLines(TextToolRun run) {
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final lines = block.contents;
  final n = lines.length;
  final keys = _sortKeys(run, lines);
  final descending = run.option<String>('order') == 'descending';
  final byLength = run.option<bool>('byLength');
  final numeric = run.option<bool>('numbersByValue');
  final keepFirst = run.option<bool>('keepFirstLine') && n > 1;

  final order = [for (var i = keepFirst ? 1 : 0; i < n; i++) i];
  // List.sort is not stable, so equal keys decide by position: even a
  // descending sort leaves equal lines in the order they had.
  order.sort((a, b) {
    var c = 0;
    if (byLength) {
      c = lines[a].length.compareTo(lines[b].length);
    }
    if (c == 0) {
      c = numeric
          ? _compareNatural(keys[a], keys[b])
          : _compareCodePoints(keys[a], keys[b]);
    }
    if (c == 0) return a.compareTo(b);
    return descending ? -c : c;
  });
  final sorted = [if (keepFirst) 0, ...order];

  var moved = 0;
  for (var i = 0; i < n; i++) {
    if (lines[sorted[i]] != lines[i]) moved++;
  }
  if (moved == 0) return TextToolUnchanged(scope: n);

  final replacement = _joinLines([
    for (final index in sorted) lines[index],
  ], block.breaks);
  return _blockEdit(
    run,
    range.start,
    range.end,
    replacement,
    changed: moved,
    scope: n,
  );
}

TextToolOutcome _removeDuplicateLines(TextToolRun run) {
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final lines = block.contents;
  final n = lines.length;
  final adjacent = run.option<bool>('adjacentOnly');
  final ignoreCase = run.option<bool>('ignoreCase');
  final trim = run.option<bool>('ignoreSurroundingWhitespace');
  final keepBlank = run.option<bool>('keepBlankLines');
  final everyCopy = run.option<bool>('removeEveryCopy');

  String keyOf(int i) {
    var line = lines[i];
    if (trim) line = _trimIndent(line);
    return ignoreCase ? run.context.fold(line) : line;
  }

  final remove = List<bool>.filled(n, false);
  var removed = 0;
  if (everyCopy) {
    final counts = <String, int>{};
    for (var i = 0; i < n; i++) {
      if (keepBlank && _isBlankRange(lines[i], 0, lines[i].length)) continue;
      counts[keyOf(i)] = (counts[keyOf(i)] ?? 0) + 1;
    }
    for (var i = 0; i < n; i++) {
      if ((counts[keyOf(i)] ?? 0) > 1) {
        remove[i] = true;
        removed++;
      }
    }
  } else if (adjacent) {
    for (var i = 1; i < n; i++) {
      if (keepBlank && _isBlankRange(lines[i], 0, lines[i].length)) continue;
      if (keyOf(i) == keyOf(i - 1)) {
        remove[i] = true;
        removed++;
      }
    }
  } else {
    final seen = <String>{};
    for (var i = 0; i < n; i++) {
      if (keepBlank && _isBlankRange(lines[i], 0, lines[i].length)) continue;
      if (!seen.add(keyOf(i))) {
        remove[i] = true;
        removed++;
      }
    }
  }
  return _spanEdit(
    run,
    _lineDeletions(block, remove),
    changed: removed,
    scope: n,
  );
}

TextToolOutcome _removeBlankLines(TextToolRun run) {
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final lines = block.contents;
  final remove = [
    for (final line in lines) _isBlankRange(line, 0, line.length),
  ];
  final removed = remove.where((r) => r).length;
  return _spanEdit(
    run,
    _lineDeletions(block, remove),
    changed: removed,
    scope: lines.length,
  );
}

/// [line] without its leading and trailing spaces and tabs.
String _trimIndent(String line) {
  var start = 0;
  var end = line.length;
  while (start < end && _isSpaceOrTab(line.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isSpaceOrTab(line.codeUnitAt(end - 1))) {
    end--;
  }
  return line.substring(start, end);
}

// ── Case ──────────────────────────────────────────────────────────────

/// A character-class rewrite of the resolved range, so a caret keeps its
/// place — case mapping never changes a string's UTF-16 length.
TextToolOutcome _caseChange(TextToolRun run, String Function(String) map) {
  final slice = run.text.substring(
    math.min(run.base, run.extent),
    math.max(run.base, run.extent),
  );
  final mapped = map(slice);
  var changed = 0;
  for (var i = 0; i < slice.length; i++) {
    if (slice.codeUnitAt(i) != mapped.codeUnitAt(i)) changed++;
  }
  if (changed == 0) return TextToolUnchanged(scope: slice.length);
  final newText = run.text.replaceRange(
    math.min(run.base, run.extent),
    math.max(run.base, run.extent),
    mapped,
  );
  final LineEdit edit;
  if (run.ranOn == TextToolRanOn.selection) {
    // The length never changes, so the selection still covers its result.
    edit = LineEdit(newText, run.base, run.extent);
  } else {
    edit = LineEdit(newText, run.caret, run.caret);
  }
  return TextToolChanged(edit, changed: changed, scope: slice.length);
}

TextToolOutcome _toUppercase(TextToolRun run) =>
    _caseChange(run, (s) => s.toUpperCase());

TextToolOutcome _toLowercase(TextToolRun run) =>
    _caseChange(run, (s) => s.toLowerCase());

// ── Whitespace ────────────────────────────────────────────────────────

TextToolOutcome _trimTrailingWhitespace(TextToolRun run) {
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final edits = <_Edit>[];
  var changed = 0;
  for (var i = 0; i < block.contents.length; i++) {
    final content = block.contents[i];
    var end = content.length;
    while (end > 0 && _isSpaceOrTab(content.codeUnitAt(end - 1))) {
      end--;
    }
    if (end < content.length) {
      edits.add((
        start: block.starts[i] + end,
        end: block.starts[i] + content.length,
        insert: '',
      ));
      changed++;
    }
  }
  return _spanEdit(run, edits, changed: changed, scope: block.contents.length);
}

/// The tab stop a conversion uses: the document's own width, or for a
/// tab-indented file the width the host prefers spaces at.
int _indentWidth(TextToolRun run) {
  final indentation = run.context.indentation;
  return indentation.style == IndentStyle.tabs
      ? (run.context.indentationPreference?.width ?? indentation.width)
      : indentation.width;
}

/// The length of [line]'s leading run of spaces and tabs.
int _indentEnd(String line) {
  var at = 0;
  while (at < line.length && _isSpaceOrTab(line.codeUnitAt(at))) {
    at++;
  }
  return at;
}

TextToolOutcome _indentationToSpaces(TextToolRun run) {
  if (requiredIndentationFor(run.context.displayPath)?.style ==
      IndentStyle.tabs) {
    return const TextToolRefused(TextToolRefusal.requiresTabs);
  }
  final width = _indentWidth(run);
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final edits = <_Edit>[];
  for (var i = 0; i < block.contents.length; i++) {
    final content = block.contents[i];
    final end = _indentEnd(content);
    if (end == 0) continue;
    final replacement = ' ' * _indentColumnsTo(content, end, width);
    if (content.substring(0, end) != replacement) {
      edits.add((
        start: block.starts[i],
        end: block.starts[i] + end,
        insert: replacement,
      ));
    }
  }
  return _spanEdit(
    run,
    edits,
    changed: edits.length,
    scope: block.contents.length,
    indentation: Indentation.spaces(width),
  );
}

TextToolOutcome _indentationToTabs(TextToolRun run) {
  final width = _indentWidth(run);
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final edits = <_Edit>[];
  for (var i = 0; i < block.contents.length; i++) {
    final content = block.contents[i];
    final end = _indentEnd(content);
    if (end == 0) continue;
    final column = _indentColumnsTo(content, end, width);
    final replacement = '\t' * (column ~/ width) + ' ' * (column % width);
    if (content.substring(0, end) != replacement) {
      edits.add((
        start: block.starts[i],
        end: block.starts[i] + end,
        insert: replacement,
      ));
    }
  }
  return _spanEdit(
    run,
    edits,
    changed: edits.length,
    scope: block.contents.length,
    indentation: Indentation.tabs(width: width),
  );
}

/// The visual column the leading run [line] units 0..[end] reaches — the
/// same walk [_indentColumn] makes, returning the column instead of the
/// run length.
int _indentColumnsTo(String line, int end, int width) {
  var column = 0;
  for (var i = 0; i < end; i++) {
    column = line.codeUnitAt(i) == _tabUnit
        ? column + width - column % width
        : column + 1;
  }
  return column;
}

// ── Clean Up ──────────────────────────────────────────────────────────

/// The curly quotes Straighten Quotes knows: apostrophes, singles and
/// doubles, including the low variants, to their ASCII forms.
const _curlyQuotes = {
  0x2018: "'",
  0x2019: "'",
  0x201a: "'",
  0x201b: "'",
  0x201c: '"',
  0x201d: '"',
  0x201e: '"',
  0x201f: '"',
};

TextToolOutcome _straightenQuotes(TextToolRun run) {
  final start = math.min(run.base, run.extent);
  final end = math.max(run.base, run.extent);
  final edits = <_Edit>[];
  var i = start;
  while (i < end) {
    final unit = run.text.codeUnitAt(i);
    if (_isHighSurrogate(unit) && i + 1 < end) {
      final low = run.text.codeUnitAt(i + 1);
      if (_isLowSurrogate(low)) {
        i += 2;
        continue;
      }
    }
    final quote = _curlyQuotes[unit];
    if (quote != null) {
      edits.add((start: i, end: i + 1, insert: quote));
    }
    i++;
  }
  return _spanEdit(run, edits, changed: edits.length, scope: end - start);
}

/// The gremlin classes Zap Gremlins covers, as documented in
/// docs/TEXT_TOOLS.md: C0 controls apart from the whitespace a text file
/// uses, DEL, the C1 range, invisible formatters, bidirectional controls,
/// damaged characters, and optionally everything non-ASCII.
enum _GremlinClass { controls, invisible, bidi, damaged, nonAscii }

_GremlinClass? _gremlinClass(int rune) {
  if (rune < 0x20 &&
      rune != _tabUnit &&
      rune != _newlineUnit &&
      rune != _returnUnit) {
    return _GremlinClass.controls;
  }
  if (rune == 0x7f || (rune >= 0x80 && rune <= 0x9f)) {
    return _GremlinClass.controls;
  }
  if (rune == 0x00ad || rune == 0x200b || rune == 0x2060 || rune == 0xfeff) {
    return _GremlinClass.invisible;
  }
  if ((rune >= 0x202a && rune <= 0x202e) ||
      (rune >= 0x2066 && rune <= 0x2069)) {
    return _GremlinClass.bidi;
  }
  if (rune == 0xfffd || (rune >= 0xd800 && rune <= 0xdfff)) {
    return _GremlinClass.damaged;
  }
  if (rune > 0x7f) return _GremlinClass.nonAscii;
  return null;
}

TextToolOutcome _zapGremlins(TextToolRun run) {
  final start = math.min(run.base, run.extent);
  final end = math.max(run.base, run.extent);
  final enabled = {
    for (final c in _GremlinClass.values)
      if (run.option<bool>(c.name)) c,
  };
  final action = run.option<String>('action');
  final character = run.option<String>('character');

  String replacement(int rune) => switch (action) {
    'escape' => '\\u{${rune.toRadixString(16)}}',
    'replace' => character,
    'entity' => '&#x${rune.toRadixString(16)};',
    _ => '',
  };

  final edits = <_Edit>[];
  var i = start;
  while (i < end) {
    final unit = run.text.codeUnitAt(i);
    var rune = unit;
    var width = 1;
    if (_isHighSurrogate(unit) && i + 1 < end) {
      final low = run.text.codeUnitAt(i + 1);
      if (_isLowSurrogate(low)) {
        rune = _combine(unit, low);
        width = 2;
      }
    }
    final found = _gremlinClass(rune);
    // "All non-ASCII" is an extra predicate, not a competitor: a control
    // is still non-ASCII.
    final zapped =
        (found != null && enabled.contains(found)) ||
        (enabled.contains(_GremlinClass.nonAscii) && rune > 0x7f);
    if (zapped) {
      edits.add((start: i, end: i + width, insert: replacement(rune)));
    }
    i += width;
  }
  return _spanEdit(
    run,
    edits,
    changed: edits.length,
    scope: end - start,
    detail: action == 'delete' ? null : action,
  );
}

TextToolOutcome _prefixSuffixLines(TextToolRun run) {
  final insert = run.option<String>('mode') == 'insert';
  final prefix = run.option<String>('where') == 'prefix';
  final affix = run.option<String>('text');
  final skipBlank = run.option<bool>('skipBlankLines');
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  if (affix.isEmpty) return TextToolUnchanged(scope: block.contents.length);

  final edits = <_Edit>[];
  var changed = 0;
  for (var i = 0; i < block.contents.length; i++) {
    final line = block.contents[i];
    if (skipBlank && _isBlankRange(line, 0, line.length)) continue;
    if (insert) {
      edits.add((
        start: prefix ? block.starts[i] : block.starts[i] + line.length,
        end: prefix ? block.starts[i] : block.starts[i] + line.length,
        insert: affix,
      ));
      changed++;
    } else {
      final matches = prefix ? line.startsWith(affix) : line.endsWith(affix);
      if (!matches) continue;
      edits.add((
        start: prefix
            ? block.starts[i]
            : block.starts[i] + line.length - affix.length,
        end: prefix
            ? block.starts[i] + affix.length
            : block.starts[i] + line.length,
        insert: '',
      ));
      changed++;
    }
  }
  return _spanEdit(
    run,
    edits,
    changed: changed,
    scope: block.contents.length,
    detail: insert ? null : 'remove',
  );
}

TextToolOutcome _numberLines(TextToolRun run) {
  final add = run.option<String>('mode') == 'add';
  final separator = run.option<String>('separator');
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final n = block.contents.length;

  if (!add) {
    // Removal only strips a number that is followed by the declared
    // separator, so prose that merely starts with digits survives.
    final pattern = RegExp(
      separator.isEmpty ? '^\\s*\\d+' : '^\\s*\\d+${RegExp.escape(separator)}',
    );
    final edits = <_Edit>[];
    var changed = 0;
    for (var i = 0; i < n; i++) {
      final match = pattern.firstMatch(block.contents[i]);
      if (match == null) continue;
      edits.add((
        start: block.starts[i],
        end: block.starts[i] + match.end,
        insert: '',
      ));
      changed++;
    }
    return _spanEdit(run, edits, changed: changed, scope: n, detail: 'remove');
  }

  final start = run.option<int>('start');
  final step = run.option<int>('step');
  final last = start + (n - 1) * step;
  final width = switch (run.option<String>('padding')) {
    'spaces' || 'zeros' => last.toString().length,
    _ => 0,
  };
  final pad = switch (run.option<String>('padding')) {
    'zeros' => '0',
    _ => ' ',
  };

  final contents = <String>[
    for (var i = 0; i < n; i++)
      '${(start + i * step).toString().padLeft(width, pad)}$separator'
          '${block.contents[i]}',
  ];
  return _blockEdit(
    run,
    range.start,
    range.end,
    _joinLines(contents, block.breaks),
    changed: n,
    scope: n,
  );
}

TextToolOutcome _joinLinesWith(TextToolRun run) {
  final separator = run.option<String>('separator');
  final trim = run.option<bool>('trim');
  final skipBlank = run.option<bool>('skipBlankLines');
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);

  final lines = <String>[];
  for (final line in block.contents) {
    final trimmed = trim ? line.trim() : line;
    if (skipBlank && trimmed.isEmpty) continue;
    lines.add(trimmed);
  }
  if (lines.length <= 1) {
    return TextToolUnchanged(scope: block.contents.length);
  }
  return _blockEdit(
    run,
    range.start,
    range.end,
    lines.join(separator),
    changed: lines.length,
    scope: block.contents.length,
  );
}

// ── Slice replacement ─────────────────────────────────────────────────

/// The outcome for replacing `[base, extent)` with [mapped]: a selection
/// keeps covering its result, direction kept; a caret before the slice is
/// untouched, a caret after it shifts with the length delta, and a caret
/// inside lands at the result's end.
TextToolOutcome _replaceSlice(
  TextToolRun run,
  String mapped, {
  required int changed,
  required int scope,
}) {
  final start = math.min(run.base, run.extent);
  final end = math.max(run.base, run.extent);
  final newText = run.text.replaceRange(start, end, mapped);
  final LineEdit edit;
  if (run.ranOn == TextToolRanOn.selection) {
    final blockEnd = start + mapped.length;
    edit = LineEdit(
      newText,
      run.base < run.extent ? start : blockEnd,
      run.base < run.extent ? blockEnd : start,
    );
  } else {
    final int caret;
    if (run.caret <= start) {
      caret = run.caret;
    } else if (run.caret >= end) {
      caret = run.caret + mapped.length - (end - start);
    } else {
      // Inside the slice: keep the offset when the length holds, land at
      // the result's end when it shrank or grew.
      final inside = run.caret - start;
      caret = start + (inside > mapped.length ? mapped.length : inside);
    }
    edit = LineEdit(newText, caret, caret);
  }
  return TextToolChanged(edit, changed: changed, scope: scope);
}

/// Runs [map] over the resolved slice — a word or a selection — and
/// replaces it when it changed. Returns null when it did not, letting
/// tools compose `?? unchanged` fallbacks.
TextToolOutcome? _mapSlice(TextToolRun run, String Function(String) map) {
  final start = math.min(run.base, run.extent);
  final end = math.max(run.base, run.extent);
  final slice = run.text.substring(start, end);
  final mapped = map(slice);
  if (mapped == slice) return null;
  return _replaceSlice(run, mapped, changed: slice.length, scope: slice.length);
}

// ── Line ordering ─────────────────────────────────────────────────────

TextToolOutcome _reverseLines(TextToolRun run) {
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final n = block.contents.length;
  if (n < 2) return TextToolUnchanged(scope: n);
  return _blockEdit(
    run,
    range.start,
    range.end,
    _joinLines(block.contents.reversed.toList(), block.breaks),
    changed: n,
    scope: n,
  );
}

TextToolOutcome _shuffleLines(TextToolRun run) {
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final n = block.contents.length;
  if (n < 2) return TextToolUnchanged(scope: n);
  final shuffled = [...block.contents]..shuffle(run.context.random);
  var moved = 0;
  for (var i = 0; i < n; i++) {
    if (shuffled[i] != block.contents[i]) moved++;
  }
  if (moved == 0) return TextToolUnchanged(scope: n);
  return _blockEdit(
    run,
    range.start,
    range.end,
    _joinLines(shuffled, block.breaks),
    changed: moved,
    scope: n,
  );
}

/// Collapses every run of blank lines to a single blank line.
TextToolOutcome _collapseBlankLines(TextToolRun run) {
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final n = block.contents.length;
  final remove = List.filled(n, false);
  var collapsed = 0;
  var inRun = false;
  for (var i = 0; i < n; i++) {
    final line = block.contents[i];
    if (!_isBlankRange(line, 0, line.length)) {
      inRun = false;
      continue;
    }
    if (inRun) {
      remove[i] = true;
      collapsed++;
    } else {
      inRun = true;
    }
  }
  return _spanEdit(
    run,
    _lineDeletions(block, remove),
    changed: collapsed,
    scope: n,
  );
}

// ── Case ──────────────────────────────────────────────────────────────

/// Whether [ch] is a cased letter in the given direction.
bool _isLowerLetter(String ch) =>
    ch.toLowerCase() == ch && ch.toUpperCase() != ch;
bool _isUpperLetter(String ch) =>
    ch.toUpperCase() == ch && ch.toLowerCase() != ch;

/// The first rune of [word] uppercased, the rest as given.
String _capitalize(String word) {
  if (word.isEmpty) return word;
  final first = _runeLength(word.codeUnitAt(0));
  return word.substring(0, first).toUpperCase() + word.substring(first);
}

/// Splits [text] into identifier words: boundaries at non-alphanumerics,
/// a lower-case-to-upper camel hump, and an acronym tail — 'XMLHttp'
/// splits into 'XML' and 'Http'. Digits stay with their word.
List<String> _identifierWords(String text) {
  final runes = text.runes.toList();
  final words = <String>[];
  final current = StringBuffer();
  var prevWasUpper = false;
  var prevWasAlnum = false;

  void flush() {
    if (current.isNotEmpty) {
      words.add(current.toString());
      current.clear();
    }
  }

  for (var i = 0; i < runes.length; i++) {
    final ch = String.fromCharCode(runes[i]);
    final upper = _isUpperLetter(ch);
    final alnum = upper || _isLowerLetter(ch) || _isDigit(runes[i]);
    if (!alnum) {
      flush();
      prevWasUpper = false;
      prevWasAlnum = false;
      continue;
    }
    if (upper &&
        prevWasAlnum &&
        (!prevWasUpper ||
            (i + 1 < runes.length &&
                _isLowerLetter(String.fromCharCode(runes[i + 1]))))) {
      flush();
    }
    current.write(ch);
    prevWasUpper = upper;
    prevWasAlnum = true;
  }
  flush();
  return words;
}

/// Uppercases the first letter of each whitespace-separated word and
/// lowercases the rest.
TextToolOutcome _toTitleCase(TextToolRun run) =>
    _mapSlice(
      run,
      (slice) => slice.splitMapJoin(
        RegExp(r'\s+'),
        onNonMatch: (word) => _capitalize(word.toLowerCase()),
      ),
    ) ??
    TextToolUnchanged(scope: (run.extent - run.base).abs());

/// Lowercases the slice, then uppercases the first letter after the start
/// and after each '.', '!', '?' or line break.
TextToolOutcome _toSentenceCase(TextToolRun run) =>
    _mapSlice(run, (slice) {
      final out = StringBuffer();
      var capitalizeNext = true;
      for (final r in slice.toLowerCase().runes) {
        final ch = String.fromCharCode(r);
        if (capitalizeNext && _isLowerLetter(ch)) {
          out.write(ch.toUpperCase());
          capitalizeNext = false;
        } else {
          out.write(ch);
          if (ch == '.' || ch == '!' || ch == '?' || ch == '\n' || ch == '\r') {
            capitalizeNext = true;
          }
        }
      }
      return out.toString();
    }) ??
    TextToolUnchanged(scope: (run.extent - run.base).abs());

TextToolOutcome _identifierCase(
  TextToolRun run,
  String Function(List<String>) combine,
) =>
    _mapSlice(run, (slice) {
      final words = _identifierWords(slice);
      return words.isEmpty ? slice : combine(words);
    }) ??
    TextToolUnchanged(scope: (run.extent - run.base).abs());

TextToolOutcome _toCamelCase(TextToolRun run) => _identifierCase(run, (words) {
  final lower = [for (final w in words) w.toLowerCase()];
  return lower.first + lower.skip(1).map(_capitalize).join();
});

TextToolOutcome _toPascalCase(TextToolRun run) => _identifierCase(
  run,
  (words) => [for (final w in words) _capitalize(w.toLowerCase())].join(),
);

TextToolOutcome _toSnakeCase(TextToolRun run) => _identifierCase(
  run,
  (words) => [for (final w in words) w.toLowerCase()].join('_'),
);

TextToolOutcome _toKebabCase(TextToolRun run) => _identifierCase(
  run,
  (words) => [for (final w in words) w.toLowerCase()].join('-'),
);

TextToolOutcome _toConstantCase(TextToolRun run) => _identifierCase(
  run,
  (words) => [for (final w in words) w.toUpperCase()].join('_'),
);

// ── Whitespace ────────────────────────────────────────────────────────

TextToolOutcome _trimLeadingWhitespace(TextToolRun run) {
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final edits = <_Edit>[];
  for (var i = 0; i < block.contents.length; i++) {
    final end = _indentEnd(block.contents[i]);
    if (end > 0) {
      edits.add((
        start: block.starts[i],
        end: block.starts[i] + end,
        insert: '',
      ));
    }
  }
  return _spanEdit(
    run,
    edits,
    changed: edits.length,
    scope: block.contents.length,
  );
}

/// Unicode space characters that [normalizeSpaces] folds to U+0020:
/// no-break, ogham, the U+2000 block, narrow/medium/ideographic. Line
/// separators (NEL, U+2028, U+2029) are line structure, not spaces.
bool _isUnicodeSpace(int unit) =>
    unit == 0x00a0 ||
    unit == 0x1680 ||
    (unit >= 0x2000 && unit <= 0x200a) ||
    unit == 0x202f ||
    unit == 0x205f ||
    unit == 0x3000;

TextToolOutcome _normalizeSpaces(TextToolRun run) {
  final start = math.min(run.base, run.extent);
  final end = math.max(run.base, run.extent);
  final slice = run.text.substring(start, end);
  var changed = 0;
  final out = StringBuffer();
  for (var i = 0; i < slice.length; i++) {
    if (_isUnicodeSpace(slice.codeUnitAt(i))) {
      out.write(' ');
      changed++;
    } else {
      out.write(slice[i]);
    }
  }
  if (changed == 0) return TextToolUnchanged(scope: slice.length);
  return _replaceSlice(
    run,
    out.toString(),
    changed: changed,
    scope: slice.length,
  );
}

// ── Clean Up ──────────────────────────────────────────────────────────

/// ANSI escape sequences: OSC (ESC ] … BEL or ST), string sequences
/// (DCS, SOS, PM, APC — ESC P/X/^/_ … ST), CSI (ESC [ params final) and
/// the remaining two-or-more-byte escape forms.
final _ansiPattern = RegExp(
  '\x1B\\][^\x07\x1B]*(?:\x07|\x1B\\\\)'
  '|\x1B[PX^_][^\x1B]*\x1B\\\\'
  '|\x1B\\[[\\x30-\\x3F]*[\\x20-\\x2F]*[\\x40-\\x7E]'
  '|\x1B[\\x20-\\x2F]*[\\x30-\\x7E]',
);

TextToolOutcome _removeAnsiEscapes(TextToolRun run) {
  final start = math.min(run.base, run.extent);
  final end = math.max(run.base, run.extent);
  final slice = run.text.substring(start, end);
  final removed = _ansiPattern.allMatches(slice).length;
  if (removed == 0) return TextToolUnchanged(scope: slice.length);
  return _replaceSlice(
    run,
    slice.replaceAll(_ansiPattern, ''),
    changed: removed,
    scope: slice.length,
  );
}

// ── Wrap ──────────────────────────────────────────────────────────────

/// Joins each run of non-blank lines into one line; blank lines stay as
/// separators between paragraphs.
TextToolOutcome _unwrapParagraphs(TextToolRun run) {
  final range = touchedLineRange(run.text, run.base, run.extent);
  final block = _linesOf(run.text, range.start, range.end);
  final n = block.contents.length;
  final contents = <String>[];
  final breaks = <String>[];
  var joins = 0;
  var i = 0;
  while (i < n) {
    final line = block.contents[i];
    if (_isBlankRange(line, 0, line.length)) {
      contents.add(line);
      if (i < n - 1) breaks.add(block.breaks[i]);
      i++;
      continue;
    }
    var j = i;
    while (j + 1 < n) {
      final next = block.contents[j + 1];
      if (_isBlankRange(next, 0, next.length)) break;
      j++;
    }
    joins += j - i;
    contents.add(
      [for (var k = i; k <= j; k++) block.contents[k].trim()].join(' '),
    );
    if (j < n - 1) breaks.add(block.breaks[j]);
    i = j + 1;
  }
  if (joins == 0) return TextToolUnchanged(scope: n);
  return _blockEdit(
    run,
    range.start,
    range.end,
    _joinLines(contents, breaks),
    changed: joins,
    scope: n,
  );
}

// ── Encode ────────────────────────────────────────────────────────────

/// The resolved slice — encoders all require a selection.
String _sliceOf(TextToolRun run) {
  final start = math.min(run.base, run.extent);
  final end = math.max(run.base, run.extent);
  return run.text.substring(start, end);
}

TextToolOutcome _urlEncode(TextToolRun run) =>
    _mapSlice(run, Uri.encodeComponent) ??
    TextToolUnchanged(scope: _sliceOf(run).length);

bool _isHexDigit(int unit) =>
    _isDigit(unit) ||
    (unit >= 0x61 && unit <= 0x66) ||
    (unit >= 0x41 && unit <= 0x46);

/// Percent-decodes valid '%XX' runs and leaves the rest literal — a
/// malformed '%' or bytes that do not form UTF-8 stay as they were.
TextToolOutcome _urlDecode(TextToolRun run) {
  final slice = _sliceOf(run);
  final out = StringBuffer();
  final bytes = <int>[];
  var decoded = 0;

  void flushBytes() {
    if (bytes.isEmpty) return;
    try {
      out.write(utf8.decode(bytes));
      decoded += bytes.length;
    } catch (_) {
      // Not valid UTF-8 — write the escapes back literally.
      for (final b in bytes) {
        out.write('%');
        out.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
      }
    }
    bytes.clear();
  }

  var i = 0;
  while (i < slice.length) {
    if (slice.codeUnitAt(i) == 0x25 &&
        i + 2 < slice.length &&
        _isHexDigit(slice.codeUnitAt(i + 1)) &&
        _isHexDigit(slice.codeUnitAt(i + 2))) {
      bytes.add(int.parse(slice.substring(i + 1, i + 3), radix: 16));
      i += 3;
      continue;
    }
    flushBytes();
    out.write(slice[i]);
    i++;
  }
  flushBytes();
  if (decoded == 0) return TextToolUnchanged(scope: slice.length);
  return _replaceSlice(
    run,
    out.toString(),
    changed: decoded,
    scope: slice.length,
  );
}

TextToolOutcome _base64Encode(TextToolRun run) {
  final slice = _sliceOf(run);
  return _replaceSlice(
    run,
    base64.encode(utf8.encode(slice)),
    changed: slice.length,
    scope: slice.length,
  );
}

TextToolOutcome _base64Decode(TextToolRun run) {
  final slice = _sliceOf(run);
  final cleaned = slice.replaceAll(RegExp(r'\s+'), '');
  if (cleaned.isEmpty) return TextToolUnchanged(scope: slice.length);
  final List<int> bytes;
  try {
    bytes = base64.decode(cleaned);
  } on FormatException {
    return TextToolUnchanged(scope: slice.length);
  }
  final String decoded;
  try {
    decoded = utf8.decode(bytes);
  } on FormatException {
    // Decodes to bytes that are not text — leave the buffer alone.
    return TextToolRefused(TextToolRefusal.resultNotText);
  }
  if (decoded.contains('\x00')) {
    return TextToolRefused(TextToolRefusal.resultNotText);
  }
  return _replaceSlice(
    run,
    decoded,
    changed: cleaned.length,
    scope: slice.length,
  );
}

/// The named HTML entities a decode recognizes; encode writes &amp;, &lt;,
/// &gt;, &quot; and numeric references only.
const _namedEntities = {
  'amp': 0x26,
  'lt': 0x3c,
  'gt': 0x3e,
  'quot': 0x22,
  'apos': 0x27,
  'nbsp': 0xa0,
  'copy': 0xa9,
  'reg': 0xae,
  'trade': 0x2122,
  'hellip': 0x2026,
  'mdash': 0x2014,
  'ndash': 0x2013,
  'lsquo': 0x2018,
  'rsquo': 0x2019,
  'ldquo': 0x201c,
  'rdquo': 0x201d,
  'laquo': 0xab,
  'raquo': 0xbb,
  'deg': 0xb0,
  'plusmn': 0xb1,
  'middot': 0xb7,
  'para': 0xb6,
  'sect': 0xa7,
  'cent': 0xa2,
  'pound': 0xa3,
  'yen': 0xa5,
  'euro': 0x20ac,
  'times': 0xd7,
  'divide': 0xf7,
  'bull': 0x2022,
  'dagger': 0x2020,
  'Dagger': 0x2021,
};

final _entityPattern = RegExp(r'&(#x?[0-9a-zA-Z]+|\w+);');

TextToolOutcome _htmlEntityEncode(TextToolRun run) {
  final slice = _sliceOf(run);
  var changed = 0;
  final out = StringBuffer();
  for (final r in slice.runes) {
    final escaped = switch (r) {
      0x26 => '&amp;',
      0x3c => '&lt;',
      0x3e => '&gt;',
      0x22 => '&quot;',
      0x27 => '&#39;',
      _ => null,
    };
    if (escaped != null) {
      out.write(escaped);
      changed++;
    } else if (r > 0x7f) {
      out.write('&#$r;');
      changed++;
    } else {
      out.writeCharCode(r);
    }
  }
  if (changed == 0) return TextToolUnchanged(scope: slice.length);
  return _replaceSlice(
    run,
    out.toString(),
    changed: changed,
    scope: slice.length,
  );
}

/// Decodes numeric and named entities; an entity that does not resolve —
/// or resolves to NUL or a surrogate half — stays literal.
TextToolOutcome _htmlEntityDecode(TextToolRun run) {
  final slice = _sliceOf(run);
  var changed = 0;
  final decoded = slice.replaceAllMapped(_entityPattern, (m) {
    final body = m.group(1)!;
    int? rune;
    if (body.startsWith('#x') || body.startsWith('#X')) {
      rune = int.tryParse(body.substring(2), radix: 16);
    } else if (body.startsWith('#')) {
      rune = int.tryParse(body.substring(1));
    } else {
      rune = _namedEntities[body];
    }
    if (rune == null ||
        rune == 0 ||
        rune > 0x10ffff ||
        (rune >= 0xd800 && rune <= 0xdfff)) {
      return m.group(0)!;
    }
    changed++;
    return String.fromCharCode(rune);
  });
  if (changed == 0) return TextToolUnchanged(scope: slice.length);
  return _replaceSlice(run, decoded, changed: changed, scope: slice.length);
}

/// Escapes the slice as the body of a JSON string: quotes, backslashes
/// and control characters, no surrounding quotes.
TextToolOutcome _escapeJsonString(TextToolRun run) {
  final slice = _sliceOf(run);
  var changed = 0;
  final out = StringBuffer();
  for (final r in slice.runes) {
    final escaped = switch (r) {
      0x22 => '\\"',
      0x5c => '\\\\',
      0x0a => '\\n',
      0x09 => '\\t',
      0x0d => '\\r',
      0x08 => '\\b',
      0x0c => '\\f',
      _ => null,
    };
    if (escaped != null) {
      out.write(escaped);
      changed++;
    } else if (r < 0x20) {
      out.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
      changed++;
    } else {
      out.writeCharCode(r);
    }
  }
  if (changed == 0) return TextToolUnchanged(scope: slice.length);
  return _replaceSlice(
    run,
    out.toString(),
    changed: changed,
    scope: slice.length,
  );
}

/// Decodes backslash escapes — \n \t \r \b \f \v \a \\ \" \' \xNN \uXXXX
/// — and leaves anything else, including a NUL-producing \0 or \x00,
/// literal.
TextToolOutcome _unescapeBackslashSequences(TextToolRun run) {
  final slice = _sliceOf(run);
  var changed = 0;
  final out = StringBuffer();
  var i = 0;
  while (i < slice.length) {
    if (slice[i] != '\\' || i + 1 >= slice.length) {
      out.write(slice[i]);
      i++;
      continue;
    }
    final next = slice[i + 1];
    final simple = switch (next) {
      'n' => '\n',
      't' => '\t',
      'r' => '\r',
      'b' => '\b',
      'f' => '\f',
      'v' => '\x0b',
      'a' => '\x07',
      '\\' => '\\',
      '"' => '"',
      "'" => "'",
      _ => null,
    };
    if (simple != null) {
      out.write(simple);
      changed++;
      i += 2;
      continue;
    }
    final hexCount = next == 'x' ? 2 : (next == 'u' ? 4 : 0);
    if (hexCount > 0 &&
        i + 1 + hexCount < slice.length &&
        [
          for (var k = 0; k < hexCount; k++)
            _isHexDigit(slice.codeUnitAt(i + 2 + k)),
        ].every((ok) => ok)) {
      final rune = int.parse(
        slice.substring(i + 2, i + 2 + hexCount),
        radix: 16,
      );
      if (rune != 0 && !(rune >= 0xd800 && rune <= 0xdfff)) {
        out.write(String.fromCharCode(rune));
        changed++;
        i += 2 + hexCount;
        continue;
      }
    }
    // Not a recognized escape — keep it literal.
    out.write(slice[i]);
    i++;
  }
  if (changed == 0) return TextToolUnchanged(scope: slice.length);
  return _replaceSlice(
    run,
    out.toString(),
    changed: changed,
    scope: slice.length,
  );
}

// ── Insert ────────────────────────────────────────────────────────────

/// Inserts [text] at the caret, or over the selection when there is one,
/// and leaves the caret after it.
TextToolOutcome _insertText(TextToolRun run, String text) {
  final start = math.min(run.base, run.extent);
  final end = math.max(run.base, run.extent);
  final caret = start + text.length;
  return TextToolChanged(
    LineEdit(run.text.replaceRange(start, end, text), caret, caret),
    changed: text.length,
    scope: 1,
  );
}

String _two(int value) => value.toString().padLeft(2, '0');

TextToolOutcome _insertDate(TextToolRun run) {
  final now = run.context.now();
  return _insertText(run, '${now.year}-${_two(now.month)}-${_two(now.day)}');
}

TextToolOutcome _insertDateTime(TextToolRun run) {
  final now = run.context.now();
  return _insertText(
    run,
    '${now.year}-${_two(now.month)}-${_two(now.day)}'
    'T${_two(now.hour)}:${_two(now.minute)}:${_two(now.second)}',
  );
}

TextToolOutcome _insertUtcTimestamp(TextToolRun run) {
  final utc = run.context.now().toUtc();
  return _insertText(
    run,
    '${utc.year}-${_two(utc.month)}-${_two(utc.day)}'
    'T${_two(utc.hour)}:${_two(utc.minute)}:${_two(utc.second)}Z',
  );
}

TextToolOutcome _insertUuid(TextToolRun run) =>
    _insertText(run, const Uuid().v4());
