import '../masking.dart';

/// Which rules [maskStackFile] reads a stack file by (03 §8.9, M11).
enum StackFileKind {
  /// A compose file: the values of `KEY: value` and `- KEY=value` lines
  /// whose key matches [secretKeyPattern], and a block scalar under such
  /// a key.
  compose,

  /// An environment file: every value.
  environment,
}

/// [text] as spans whose concatenated [MaskedValue.display] is the file
/// with its secrets masked (03 §7.16 STK-04, §8.9): the masked spans keep
/// the real text behind [MaskedValue.reveal] for the 30 s reveal, and
/// every line ending stays in a plain span, so the lines still line up.
/// URL credentials (`scheme://user:pass@`) are masked in both kinds.
///
/// Read line by line, not as YAML, so a broken file masks too. Not
/// masked: a secret key's plain scalar continued on the next lines, flow
/// mappings (`{DB_PASSWORD: x}`) and a key in `KEY=value` form inside a
/// value of another key; each is rare in compose files.
List<MaskedValue> maskStackFile(String text, StackFileKind kind) {
  final out = _Spans();
  final masker = switch (kind) {
    StackFileKind.compose => _ComposeLines(),
    StackFileKind.environment => _EnvLines(),
  };
  var at = 0;
  while (at < text.length) {
    final newline = text.indexOf('\n', at);
    final next = newline < 0 ? text.length : newline + 1;
    var body = newline < 0 ? text.length : newline;
    // A CR before the newline stays with the line ending.
    if (body > at && text.codeUnitAt(body - 1) == 0x0D) body--;
    masker.line(text.substring(at, body), out);
    out.plain(text.substring(body, next));
    at = next;
  }
  return out.spans;
}

/// Collects spans, joining neighbouring plain text into one.
final class _Spans {
  final _spans = <MaskedValue>[];
  final _pending = StringBuffer();

  /// Every span, the trailing plain text included.
  List<MaskedValue> get spans {
    _flush();
    return _spans;
  }

  void plain(String text) => _pending.write(text);

  /// [text] with its URL credentials masked.
  void checked(String text) {
    var copied = 0;
    for (final (start, end) in urlCredentialSpans(text)) {
      plain(text.substring(copied, start));
      secret(text.substring(start, end));
      copied = end;
    }
    plain(text.substring(copied));
  }

  void secret(String text) {
    if (text.isEmpty) return;
    _flush();
    _spans.add(MaskedValue.secret(text));
  }

  void _flush() {
    if (_pending.isEmpty) return;
    _spans.add(MaskedValue.plain(_pending.toString()));
    _pending.clear();
  }
}

sealed class _Lines {
  void line(String line, _Spans out);
}

/// `KEY=value`, with an optional `export`; a quoted value may run over
/// several lines until its closing quote.
final class _EnvLines extends _Lines {
  static final _assignment = RegExp(
    r'^(\s*(?:export\s+)?[A-Za-z_][A-Za-z0-9_.-]*\s*=\s*)(.*)$',
  );

  /// The quote an open value waits for, or null.
  String? _open;

  @override
  void line(String line, _Spans out) {
    if (_open case final quote?) {
      out.secret(line);
      if (_closes(line, quote, 0)) _open = null;
      return;
    }

    final match = _assignment.firstMatch(line);
    if (match == null) return out.checked(line);
    final value = match[2]!;
    out
      ..plain(match[1]!)
      ..secret(value);
    if (value.startsWith('"') || value.startsWith("'")) {
      final quote = value[0];
      if (!_closes(value, quote, 1)) _open = quote;
    }
  }

  /// Whether [text] holds an unescaped [quote] at [from] or later.
  static bool _closes(String text, String quote, int from) {
    for (var i = from; i < text.length; i++) {
      if (text[i] == r'\' && quote == '"') {
        i++;
      } else if (text[i] == quote) {
        return true;
      }
    }
    return false;
  }
}

/// A compose file's lines, with the indentation of an open block scalar
/// under a secret key.
final class _ComposeLines extends _Lines {
  /// `- KEY=value`, optionally quoted.
  static final _listEntry = RegExp(
    r'''^(\s*-\s+)(["']?)([A-Za-z_][A-Za-z0-9_.-]*)=(.*)$''',
  );

  /// `KEY: value`, optionally a list item and a quoted key.
  static final _mapEntry = RegExp(
    r'''^(\s*(?:-\s+)?)(["']?)([A-Za-z_][A-Za-z0-9_.-]*)\2(\s*:\s+)(\S.*)$''',
  );

  /// `|` or `>` with chomping and indentation indicators.
  static final _blockIndicator = RegExp(r'^[|>][0-9+-]*\s*(#.*)?$');

  /// The indentation of the key whose block scalar is open, or null.
  int? _block;

  @override
  void line(String line, _Spans out) {
    if (_block case final indent?) {
      final content = line.trimLeft();
      final own = line.length - content.length;
      if (content.isEmpty || own > indent) {
        out
          ..plain(line.substring(0, own))
          ..secret(content);
        return;
      }
      _block = null;
    }

    if (_listEntry.firstMatch(line) case final m? when isSecretKey(m[3]!)) {
      final quote = m[2]!;
      final value = m[4]!;
      final closed = quote.isNotEmpty && value.endsWith(quote);
      out
        ..plain('${m[1]}$quote${m[3]}=')
        ..secret(closed ? value.substring(0, value.length - 1) : value)
        ..plain(closed ? quote : '');
      return;
    }

    if (_mapEntry.firstMatch(line) case final m? when isSecretKey(m[3]!)) {
      final value = m[5]!;
      out.plain('${m[1]}${m[2]}${m[3]}${m[2]}${m[4]}');
      if (_blockIndicator.hasMatch(value)) {
        _block = line.length - line.trimLeft().length;
        return out.plain(value);
      }
      if (value.startsWith('#')) return out.plain(value);
      final quote = value[0];
      final quoted =
          (quote == '"' || quote == "'") &&
          value.length > 1 &&
          value.endsWith(quote);
      if (!quoted) return out.secret(value);
      out
        ..plain(quote)
        ..secret(value.substring(1, value.length - 1))
        ..plain(quote);
      return;
    }

    out.checked(line);
  }
}
