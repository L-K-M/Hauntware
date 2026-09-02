import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _generatedLocalizationPaths = {
  'lib/l10n/app_localizations.dart',
  'lib/l10n/app_localizations_en.dart',
};

const _generatedDartSuffixes = {'.freezed.dart', '.g.dart', '.mocks.dart'};

// Technical literals are reviewed per file so an allowlist cannot hide UI copy.
const _allowedTechnicalLiterals = <String, Set<String>>{
  'lib/main.dart': {
    r"'${supportDirectory.path}${Platform.pathSeparator}settings.json'",
  },
  'lib/services/app_preferences.dart': {
    "'layout.paneRatio'",
    "'window.left'",
    "'window.top'",
    "'window.width'",
    "'window.height'",
  },
  'lib/services/atomic_file.dart': {r"'.poltergeist-${uuidV4()}.tmp'"},
  'lib/services/settings_store.dart': {
    "'settings root'",
    "'settings key'",
    r"'$path.corrupt-$stamp'",
    "'.'",
    "'-'",
    "''",
    "':'",
  },
  'lib/theme/app_theme.dart': {
    "'JetBrains Mono'",
    "'SF Mono'",
    "'Menlo'",
    "'Consolas'",
    "'DejaVu Sans Mono'",
    "'monospace'",
  },
  'lib/ui/adaptive_shell.dart': {
    "'primary-pane'",
    "'secondary-pane'",
    "'pane-splitter'",
  },
  'lib/ui/layout/pane_allocation.dart': {
    "'width'",
    "'must be finite and non-negative'",
    "'ratio'",
    "'must be finite'",
  },
};

void main() {
  test('rejects representative authored user-facing literals', () {
    const unlocalizedSources = <({String path, String source})>[
      (path: 'lib/ui/example.dart', source: "const Text('Disconnected');"),
      (
        path: 'lib/ui/example.dart',
        source: "const SelectableText('Server disconnected');",
      ),
      (
        path: 'lib/ui/example.dart',
        source: "const TextSpan(text: 'Transfer failed');",
      ),
      (
        path: 'lib/ui/example.dart',
        source: "const InputDecoration(hintText: 'Remote path');",
      ),
      (
        path: 'lib/services/example.dart',
        source: "String failureSummary() => 'Connection failed';",
      ),
    ];

    for (final fixture in unlocalizedSources) {
      final offenders = _findDisallowedLiterals(
        path: fixture.path,
        source: fixture.source,
      );

      expect(
        offenders,
        isNotEmpty,
        reason: 'missed literal: ${fixture.source}',
      );
    }
  });

  test('limits technical exceptions to their reviewed file', () {
    const source = "const paneRatioKey = 'layout.paneRatio';";

    expect(
      _findDisallowedLiterals(
        path: 'lib/services/app_preferences.dart',
        source: source,
      ),
      isEmpty,
    );
    expect(
      _findDisallowedLiterals(path: 'lib/ui/example.dart', source: source),
      isNotEmpty,
    );
  });

  test('keeps every technical exception live', () {
    for (final entry in _allowedTechnicalLiterals.entries) {
      final literals = _scanStringLiterals(
        File(entry.key).readAsStringSync(),
      ).map((literal) => literal.lexeme);

      expect(literals, containsAll(entry.value), reason: entry.key);
    }
  });

  test('ignores directives, comments, and generated files', () {
    const source = """
import 'package:flutter/widgets.dart';
// Text('Comment only')
/* SelectableText('Also a comment') */
""";

    expect(
      _findDisallowedLiterals(path: 'lib/example.dart', source: source),
      isEmpty,
    );
    expect(
      _findDisallowedLiterals(path: 'lib/example.g.dart', source: "'copy'"),
      isEmpty,
    );
  });

  test('authors user-facing strings only in ARB', () {
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final relativePath = entity.path.replaceAll('\\', '/');
      final violations = _findDisallowedLiterals(
        path: relativePath,
        source: entity.readAsStringSync(),
      );
      offenders.addAll(
        violations.map(
          (violation) => '$relativePath:${violation.line}: ${violation.lexeme}',
        ),
      );
    }

    expect(offenders, isEmpty, reason: offenders.join('\n'));
  });

  test('generated localization exclusions are present', () {
    for (final path in _generatedLocalizationPaths) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'generated localization output is missing: $path',
      );
    }
  });
}

List<({int line, String lexeme})> _findDisallowedLiterals({
  required String path,
  required String source,
}) {
  if (_isGeneratedPath(path)) return const [];

  final allowed = _allowedTechnicalLiterals[path] ?? const <String>{};
  return [
    for (final literal in _scanStringLiterals(source))
      if (!_isDirectiveLiteral(source, literal.offset) &&
          !allowed.contains(literal.lexeme))
        (
          line: '\n'.allMatches(source.substring(0, literal.offset)).length + 1,
          lexeme: literal.lexeme,
        ),
  ];
}

bool _isGeneratedPath(String path) {
  if (_generatedLocalizationPaths.contains(path)) return true;

  return _generatedDartSuffixes.any(path.endsWith);
}

bool _isDirectiveLiteral(String source, int offset) {
  final lineStart = source.lastIndexOf('\n', offset - 1) + 1;
  final prefix = source.substring(lineStart, offset).trimLeft();

  return prefix.startsWith('import ') ||
      prefix.startsWith('export ') ||
      prefix.startsWith('part ');
}

Iterable<({int offset, String lexeme})> _scanStringLiterals(
  String source,
) sync* {
  var offset = 0;
  while (offset < source.length) {
    if (source.startsWith('//', offset)) {
      final newline = source.indexOf('\n', offset + 2);
      offset = newline < 0 ? source.length : newline + 1;
      continue;
    }
    if (source.startsWith('/*', offset)) {
      offset = _skipBlockComment(source, offset);
      continue;
    }

    final literal = _readStringLiteral(source, offset);
    if (literal == null) {
      offset++;
      continue;
    }

    yield (offset: offset, lexeme: source.substring(offset, literal.end));
    offset = literal.end;
  }
}

({int end})? _readStringLiteral(String source, int offset) {
  var quoteOffset = offset;
  var isRaw = false;
  final character = source.codeUnitAt(offset);
  if ((character == _lowercaseR || character == _uppercaseR) &&
      _canStartRawString(source, offset)) {
    isRaw = true;
    quoteOffset++;
  }

  if (quoteOffset >= source.length) return null;

  final quote = source.codeUnitAt(quoteOffset);
  if (quote != _singleQuote && quote != _doubleQuote) return null;

  final triple =
      quoteOffset + 2 < source.length &&
      source.codeUnitAt(quoteOffset + 1) == quote &&
      source.codeUnitAt(quoteOffset + 2) == quote;
  final delimiterLength = triple ? 3 : 1;
  var cursor = quoteOffset + delimiterLength;
  while (cursor < source.length) {
    if (!isRaw && source.codeUnitAt(cursor) == _backslash) {
      cursor += 2;
      continue;
    }
    if (_hasClosingDelimiter(source, cursor, quote, delimiterLength)) {
      return (end: cursor + delimiterLength);
    }
    cursor++;
  }

  return (end: source.length);
}

int _skipBlockComment(String source, int offset) {
  var depth = 1;
  var cursor = offset + 2;
  while (cursor < source.length && depth > 0) {
    if (source.startsWith('/*', cursor)) {
      depth++;
      cursor += 2;
      continue;
    }
    if (source.startsWith('*/', cursor)) {
      depth--;
      cursor += 2;
      continue;
    }
    cursor++;
  }

  return cursor;
}

bool _canStartRawString(String source, int offset) {
  final quoteOffset = offset + 1;
  if (quoteOffset >= source.length) return false;

  final quote = source.codeUnitAt(quoteOffset);
  if (quote != _singleQuote && quote != _doubleQuote) return false;
  if (offset == 0) return true;

  return !_isIdentifierCharacter(source.codeUnitAt(offset - 1));
}

bool _isIdentifierCharacter(int character) {
  return character == _underscore ||
      character == _dollar ||
      character >= _zero && character <= _nine ||
      character >= _uppercaseA && character <= _uppercaseZ ||
      character >= _lowercaseA && character <= _lowercaseZ;
}

bool _hasClosingDelimiter(
  String source,
  int offset,
  int quote,
  int delimiterLength,
) {
  if (offset + delimiterLength > source.length) return false;

  for (var index = 0; index < delimiterLength; index++) {
    if (source.codeUnitAt(offset + index) != quote) return false;
  }

  return true;
}

const _singleQuote = 0x27;
const _doubleQuote = 0x22;
const _backslash = 0x5c;
const _dollar = 0x24;
const _zero = 0x30;
const _nine = 0x39;
const _uppercaseA = 0x41;
const _uppercaseR = 0x52;
const _uppercaseZ = 0x5a;
const _underscore = 0x5f;
const _lowercaseA = 0x61;
const _lowercaseR = 0x72;
const _lowercaseZ = 0x7a;
