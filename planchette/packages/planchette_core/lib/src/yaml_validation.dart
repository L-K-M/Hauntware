part of 'text_validation.dart';

/// A YAML template, such as a Helm chart, steers its output with lines that
/// start with `{{` or `{%`. Its branches may set the same key, so it is not
/// checked.
final _yamlTemplateLine = RegExp(r'^[ \t]*\{[{%]', multiLine: true);

/// Plain scalars that YAML reads as something other than a string, so that
/// `true:` and `"true":` are different keys. YAML 1.1's yes/no/on/off are
/// included, as many readers still resolve them.
final _yamlNonString = RegExp(
  r'^(?:~|null|Null|NULL|true|True|TRUE|false|False|FALSE'
  r'|yes|Yes|YES|no|No|NO|on|On|ON|off|Off|OFF'
  r'|[-+]?(?:\.[0-9]+|[0-9][0-9_]*(?:\.[0-9_]*)?)(?:[eE][-+]?[0-9]+)?'
  r'|0x[0-9a-fA-F_]+|0o[0-7_]+|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$',
);

/// A block scalar header after its indicator: an indentation digit and a
/// chomping sign in either order, then blanks and an optional comment.
final _yamlBlockScalarTail = RegExp(
  r'^(?:[1-9]?[+-]?|[+-]?[1-9]?)[ \t]*(?:#.*)?$',
);

/// Flags a key repeated in one block mapping, which the YAML specification
/// forbids and readers either reject or settle by keeping the last value, and
/// a line indented with a tab, which readers reject.
///
/// Block structure is read from indentation alone, the way YAML nests it:
///
/// ```text
///   services:          mapping at column 0   {services}
///     web:             mapping at column 2   {web}
///       image: a       mapping at column 4   {image}
///     db:              back at column 2      {web, db}
///       image: b       a new mapping at 4    {image}
///   steps:
///     - name: a        each sequence entry starts its own
///     - name: b        mapping, so these never collide
/// ```
///
/// Block scalars, quoted scalars and flow collections that span lines are
/// stepped over, not read. Keys written with an anchor, a tag or `?` are not
/// compared, nor are merge keys (`<<`), and a template is not checked.
void _validateYaml(String text, _ProblemSink sink) {
  if (_yamlTemplateLine.hasMatch(text)) return;
  final reader = _YamlReader(text, sink);
  for (final (start, end) in _lines(text)) {
    if (sink.isFull) return;
    reader.read(start, end);
  }
}

/// The keys of one block mapping and the line each was first set on.
final class _YamlMapping {
  _YamlMapping(this.column);

  final int column;
  final keys = <String, int>{};
}

/// A key at the start of a node: its range, how it compares and where the
/// value after its colon starts.
typedef _YamlKey = ({int end, String? identity, String name, int value});

final class _YamlReader {
  _YamlReader(this._text, this._sink);

  final String _text;
  final _ProblemSink _sink;

  /// Open block mappings, outermost first.
  final _mappings = <_YamlMapping>[];

  /// Inside a block scalar: the indentation its content lines exceed.
  int? _scalarParent;

  /// Inside a quoted scalar that spans lines: its quote.
  int? _quote;

  /// Brackets still open in a flow collection that spans lines.
  int _flowDepth = 0;

  /// Whether the document began with content on its `---` line, such as a
  /// top-level block scalar, so its lines are not read.
  bool _skipDocument = false;

  void read(int start, int end) {
    if (_continues(start, end)) return;

    if (_isDocumentMarker(start, end)) {
      _mappings.clear();
      final rest = _skipBlanks(start + 3, end);
      _skipDocument = rest < end && _text.codeUnitAt(rest) != 0x23 /* # */;
      return;
    }
    if (_skipDocument) return;

    var pos = start;
    while (pos < end && _text.codeUnitAt(pos) == 0x20) {
      pos++;
    }
    final content = _skipBlanks(pos, end);
    // Blank lines and comments may be indented any way, tabs included.
    if (content == end || _text.codeUnitAt(content) == 0x23 /* # */ ) return;
    if (content > pos) {
      _flagTab(pos, content, end);
      return;
    }
    if (pos == start && _text.codeUnitAt(pos) == 0x25 /* % */ ) return;
    _closeDeeper(pos - start);

    // Sequence entries: each `- ` closes the previous entry's mapping.
    int? entryColumn;
    while (pos < end &&
        _text.codeUnitAt(pos) == 0x2d /* - */ &&
        (pos + 1 == end || _isBlank(_text.codeUnitAt(pos + 1)))) {
      entryColumn = pos - start;
      _closeDeeper(entryColumn);
      pos = _skipBlanks(pos + 1, end);
    }
    if (pos == end || _text.codeUnitAt(pos) == 0x23 /* # */ ) return;

    // A node with no key here: a block scalar's content exceeds the
    // indentation of the entry or mapping that holds it.
    final parent = entryColumn ?? _mappings.lastOrNull?.column ?? -1;
    if (_opensMultilineNode(pos, end, parent)) return;

    final key = _keyAt(pos, end);
    if (key == null) return;
    final column = pos - start;
    var mapping = _mappings.lastOrNull;
    if (mapping == null || mapping.column != column) {
      mapping = _YamlMapping(column);
      _mappings.add(mapping);
    }
    _record(mapping, key, pos);
    _opensMultilineNode(_skipBlanks(key.value, end), end, column);
  }

  /// Whether the line belongs to a node an earlier line opened, updating
  /// that node's state.
  bool _continues(int start, int end) {
    if (_scalarParent case final parent?) {
      if (_skipBlanks(start, end) == end || _indent(start, end) > parent) {
        return true;
      }
      _scalarParent = null;
    }
    if (_quote case final quote?) {
      if (_closingQuote(start, end, quote) >= 0) _quote = null;
      return true;
    }
    if (_flowDepth > 0) {
      _flowDepth = _flowDepthAfter(start, end, _flowDepth);
      return true;
    }
    return false;
  }

  /// Notes a block scalar, quoted scalar or flow collection that starts at
  /// [pos] and continues on later lines; [parent] is the indentation a block
  /// scalar's content exceeds. Returns whether one starts there.
  bool _opensMultilineNode(int pos, int end, int parent) {
    pos = _skipProperties(pos, end);
    if (pos >= end) return false;
    final c = _text.codeUnitAt(pos);
    if (c == 0x7c /* | */ || c == 0x3e /* > */ ) {
      if (!_yamlBlockScalarTail.hasMatch(_text.substring(pos + 1, end))) {
        return false;
      }
      _scalarParent = parent;
      return true;
    }
    if (c == 0x22 /* " */ || c == 0x27 /* ' */ ) {
      if (_closingQuote(pos + 1, end, c) >= 0) return false;
      _quote = c;
      return true;
    }
    if (c == 0x5b /* [ */ || c == 0x7b /* { */ ) {
      _flowDepth = _flowDepthAfter(pos, end, 0);
      return true;
    }
    return false;
  }

  /// The key a node at [pos] starts with, or null for a scalar, a complex
  /// key, an alias or a key with an anchor or tag.
  _YamlKey? _keyAt(int pos, int end) {
    final c = _text.codeUnitAt(pos);
    if (c == 0x22 /* " */ || c == 0x27 /* ' */ ) {
      final close = _closingQuote(pos + 1, end, c);
      if (close < 0) return null;
      final value = _keyAfterQuote(close, end);
      if (value == null) return null;
      final name = _unquote(pos, close, c);
      return (end: close + 1, identity: 's:$name', name: name, value: value);
    }
    // Indicators that cannot start a plain key this check compares: `? `
    // and `: ` of complex keys, anchors, aliases, tags, flow and reserved
    // characters.
    if (c == 0x3f /* ? */ || c == 0x3a /* : */ ) {
      if (pos + 1 == end || _isBlank(_text.codeUnitAt(pos + 1))) return null;
    } else if ('&*![]{},|>@`%'.contains(String.fromCharCode(c))) {
      return null;
    }
    for (var i = pos; i < end; i++) {
      final at = _text.codeUnitAt(i);
      if (at == 0x23 /* # */ && _isBlank(_text.codeUnitAt(i - 1))) return null;
      if (at != 0x3a /* : */ ) continue;
      if (i + 1 < end && !_isBlank(_text.codeUnitAt(i + 1))) continue;
      var keyEnd = i;
      while (keyEnd > pos && _isBlank(_text.codeUnitAt(keyEnd - 1))) {
        keyEnd--;
      }
      final name = _text.substring(pos, keyEnd);
      if (name.isEmpty) return null;
      final identity = name == '<<'
          ? null
          : _yamlNonString.hasMatch(name)
          ? 'p:$name'
          : 's:$name';
      return (end: keyEnd, identity: identity, name: name, value: i + 1);
    }
    return null;
  }

  /// Where the value starts when a quoted scalar closing at [close] is a key:
  /// just after a colon followed by a blank or the line's end.
  int? _keyAfterQuote(int close, int end) {
    final colon = _skipBlanks(close + 1, end);
    if (colon >= end || _text.codeUnitAt(colon) != 0x3a /* : */ ) return null;
    if (colon + 1 < end && !_isBlank(_text.codeUnitAt(colon + 1))) return null;
    return colon + 1;
  }

  void _record(_YamlMapping mapping, _YamlKey key, int start) {
    final identity = key.identity;
    if (identity == null) return;
    final first = mapping.keys[identity];
    if (first == null) {
      mapping.keys[identity] = _sink.lineOf(start);
      return;
    }
    _sink.add(
      TextProblemKind.duplicateKey,
      TextProblemSeverity.warning,
      start,
      key.end,
      subject: key.name,
      relatedLine: first,
    );
  }

  /// Flags the indentation from [tab], its first tab, through the first word
  /// of [content], so the mark is visible.
  void _flagTab(int tab, int content, int end) {
    var wordEnd = content;
    while (wordEnd < end && !_isBlank(_text.codeUnitAt(wordEnd))) {
      wordEnd++;
    }
    _sink.add(
      TextProblemKind.tabIndentation,
      TextProblemSeverity.error,
      tab,
      wordEnd,
    );
  }

  void _closeDeeper(int column) {
    while (_mappings.isNotEmpty && _mappings.last.column > column) {
      _mappings.removeLast();
    }
  }

  bool _isDocumentMarker(int start, int end) =>
      end - start >= 3 &&
      (_text.startsWith('---', start) || _text.startsWith('...', start)) &&
      (end - start == 3 || _isBlank(_text.codeUnitAt(start + 3)));

  /// Steps over anchors (`&name`) and tags (`!tag`, `!!str`) before a node.
  int _skipProperties(int pos, int end) {
    while (pos < end) {
      final c = _text.codeUnitAt(pos);
      if (c != 0x26 /* & */ && c != 0x21 /* ! */ ) return pos;
      while (pos < end && !_isBlank(_text.codeUnitAt(pos))) {
        pos++;
      }
      pos = _skipBlanks(pos, end);
    }
    return pos;
  }

  /// The closing [quote] at or after [from] on the line, or -1. Double
  /// quotes take backslash escapes; single quotes are escaped by doubling.
  int _closingQuote(int from, int end, int quote) {
    for (var i = from; i < end; i++) {
      final c = _text.codeUnitAt(i);
      if (quote == 0x22 && c == 0x5c /* backslash */ ) {
        i++;
        continue;
      }
      if (c != quote) continue;
      if (quote == 0x27 && i + 1 < end && _text.codeUnitAt(i + 1) == 0x27) {
        i++;
        continue;
      }
      return i;
    }
    return -1;
  }

  /// The text of the quoted scalar between [open] and [close], with the
  /// common escapes resolved, so `"a\"b"` and `'a"b'` compare equal. Rarer
  /// ones such as `\u0041` stay as written, which can only miss a repeat.
  String _unquote(int open, int close, int quote) {
    final raw = _text.substring(open + 1, close);
    if (quote == 0x27) return raw.replaceAll("''", "'");
    if (!raw.contains(r'\')) return raw;
    final out = StringBuffer();
    for (var i = 0; i < raw.length; i++) {
      final c = raw[i];
      if (c != r'\' || i + 1 == raw.length) {
        out.write(c);
        continue;
      }
      final escaped = raw[++i];
      out.write(switch (escaped) {
        'n' => '\n',
        't' => '\t',
        '"' || r'\' || '/' => escaped,
        _ => '\\$escaped',
      });
    }
    return out.toString();
  }

  /// [depth] after the brackets between [from] and [end], ignoring quoted
  /// text and a comment.
  int _flowDepthAfter(int from, int end, int depth) {
    for (var i = from; i < end; i++) {
      final c = _text.codeUnitAt(i);
      if (c == 0x22 || c == 0x27) {
        final close = _closingQuote(i + 1, end, c);
        if (close < 0) return depth;
        i = close;
      } else if (c == 0x23 &&
          (i == from || _isBlank(_text.codeUnitAt(i - 1)))) {
        return depth;
      } else if (c == 0x5b || c == 0x7b) {
        depth++;
      } else if ((c == 0x5d || c == 0x7d) && --depth == 0) {
        return 0;
      }
    }
    return depth;
  }

  int _indent(int start, int end) {
    var pos = start;
    while (pos < end && _text.codeUnitAt(pos) == 0x20) {
      pos++;
    }
    return pos - start;
  }

  int _skipBlanks(int pos, int end) {
    while (pos < end && _isBlank(_text.codeUnitAt(pos))) {
      pos++;
    }
    return pos;
  }
}
