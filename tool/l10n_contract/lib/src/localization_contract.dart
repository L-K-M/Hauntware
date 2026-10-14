import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

/// One app's localization contract configuration.
///
/// All paths are app-root relative and use `/` separators, matching the
/// allowlist keys.
final class L10nContractConfig {
  const L10nContractConfig({
    required this.generatedLocalizationPrefix,
    required this.generatedDartSuffixes,
    required this.scannedDirectories,
  });

  /// Prefix of the generated `gen-l10n` output (for example
  /// `lib/l10n/app_localizations`). Every file whose path starts with it
  /// is excluded from the scan.
  final String generatedLocalizationPrefix;

  /// File-name suffixes of generated Dart sources (for example
  /// `.g.dart`) excluded from the scan.
  final Set<String> generatedDartSuffixes;

  /// App-root-relative directories scanned for authored literals.
  final List<String> scannedDirectories;
}

/// A typed finding from a localization contract scan.
sealed class L10nFinding {
  const L10nFinding();

  /// App-root-relative path the finding belongs to.
  String get path;
}

/// An authored string literal outside the per-file technical allowlist.
final class DisallowedLiteral extends L10nFinding {
  const DisallowedLiteral({
    required this.path,
    required this.line,
    required this.lexeme,
  });

  @override
  final String path;

  /// One-based line of [lexeme] in its file.
  final int line;

  /// The literal exactly as authored, quotes included.
  final String lexeme;

  @override
  String toString() => '$path:$line: $lexeme';
}

/// A source file that failed to parse.
///
/// The gate fails instead of scanning a partial tree, so a syntax error
/// cannot hide literals.
final class UnparseableSource extends L10nFinding {
  const UnparseableSource({required this.path, required this.message});

  @override
  final String path;

  /// A short description of why the source was refused.
  final String message;

  @override
  String toString() => '$path: cannot be parsed: $message';
}

/// An allowlist entry whose literal no longer occurs in its file.
final class DeadAllowlistEntry extends L10nFinding {
  const DeadAllowlistEntry({required this.path, required this.literal});

  @override
  final String path;

  /// The reviewed literal that is no longer present.
  final String literal;

  @override
  String toString() => '$path: allowlisted literal is gone: $literal';
}

/// One string literal located in a source string.
typedef ScannedLiteral = ({int offset, String lexeme});

/// Raised when a source has parser diagnostics and cannot be scanned.
final class LocalizationParseException implements Exception {
  const LocalizationParseException(this.message);

  /// A short description of why the source was refused.
  final String message;

  @override
  String toString() => 'LocalizationParseException: $message';
}

/// Scans one app for authored user-facing literals.
///
/// [appRoot] is the directory the config paths and allowlist keys resolve
/// against; it is usually `Directory.current.path`.
final class LocalizationContract {
  const LocalizationContract({
    required this.appRoot,
    required this.config,
    required this.allowedTechnicalLiterals,
  });

  /// App root the relative paths resolve against.
  final String appRoot;

  /// Generated-output and scan-scope configuration.
  final L10nContractConfig config;

  /// Reviewed technical literals keyed by app-root-relative file path.
  final Map<String, Set<String>> allowedTechnicalLiterals;

  /// Whether [path] names generated output excluded from the contract.
  bool isGeneratedPath(String path) {
    if (path.startsWith(config.generatedLocalizationPrefix)) return true;

    return config.generatedDartSuffixes.any(path.endsWith);
  }

  /// Findings for one already-loaded source, without reading the tree.
  ///
  /// Generated paths yield nothing. Throws [LocalizationParseException]
  /// when [source] has parser diagnostics.
  List<DisallowedLiteral> findDisallowedLiterals({
    required String path,
    required String source,
  }) {
    if (isGeneratedPath(path)) return const [];

    final allowed = allowedTechnicalLiterals[path] ?? const <String>{};
    return [
      for (final literal in scanStringLiterals(source))
        if (!allowed.contains(literal.lexeme))
          DisallowedLiteral(
            path: path,
            line: _lineOf(source, literal.offset),
            lexeme: literal.lexeme,
          ),
    ];
  }

  /// Scans the configured directories and the allowlist itself.
  ///
  /// Returns disallowed literals, unparseable sources and dead allowlist
  /// entries; an empty list is the contract's success verdict.
  List<L10nFinding> scan() {
    final findings = <L10nFinding>[];
    for (final directory in config.scannedDirectories) {
      findings.addAll(_scanDirectory(directory));
    }
    findings.addAll(_deadAllowlistEntries());

    return findings;
  }

  /// Collects every string literal in [source].
  ///
  /// Throws [LocalizationParseException] when [source] has parser
  /// diagnostics.
  List<ScannedLiteral> scanStringLiterals(String source) {
    final collector = _StringLiteralCollector();
    final result = parseString(content: source, throwIfDiagnostics: false);
    // Malformed code must fail the gate instead of hiding literals.
    if (result.errors.isNotEmpty) {
      throw const LocalizationParseException(
        'source has parse errors; refusing to scan it',
      );
    }

    result.unit.accept(collector);
    return collector.literals;
  }

  List<L10nFinding> _scanDirectory(String directory) {
    final scanned = Directory(p.join(_absoluteRoot, directory));
    if (!scanned.existsSync()) {
      return [
        UnparseableSource(
          path: directory,
          message: 'scanned directory is missing',
        ),
      ];
    }

    final findings = <L10nFinding>[];
    for (final entity in scanned.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;

      final relativePath = p
          .relative(entity.path, from: _absoluteRoot)
          .replaceAll('\\', '/');
      if (isGeneratedPath(relativePath)) continue;

      final String source;
      try {
        source = entity.readAsStringSync();
      } on FileSystemException catch (error) {
        findings.add(
          UnparseableSource(path: relativePath, message: error.message),
        );
        continue;
      }

      try {
        findings.addAll(
          findDisallowedLiterals(path: relativePath, source: source),
        );
      } on LocalizationParseException catch (error) {
        findings.add(
          UnparseableSource(path: relativePath, message: error.message),
        );
      }
    }

    return findings;
  }

  Iterable<L10nFinding> _deadAllowlistEntries() {
    final findings = <L10nFinding>[];
    for (final entry in allowedTechnicalLiterals.entries) {
      Set<String>? present;
      final file = File(p.join(_absoluteRoot, entry.key));
      if (file.existsSync()) {
        String? failure;
        try {
          present = scanStringLiterals(
            file.readAsStringSync(),
          ).map((literal) => literal.lexeme).toSet();
        } on FileSystemException catch (error) {
          failure = error.message;
        } on LocalizationParseException catch (error) {
          failure = error.message;
        }

        if (failure != null) {
          // Do not declare every entry in an unreadable or unparseable file
          // dead. Report the file itself unless the tree scan already does.
          if (!_coveredByTreeScan(entry.key)) {
            findings.add(UnparseableSource(path: entry.key, message: failure));
          }
          continue;
        }
      }

      for (final literal in entry.value) {
        if (present == null || !present.contains(literal)) {
          findings.add(DeadAllowlistEntry(path: entry.key, literal: literal));
        }
      }
    }

    return findings;
  }

  bool _coveredByTreeScan(String path) {
    if (isGeneratedPath(path)) return false;

    // The tree scan reports normalized paths, so a spelling such as `lib/`
    // or `./lib` must still cover `lib/...`.
    return config.scannedDirectories.any(
      (directory) => p.posix.isWithin(p.posix.normalize(directory), path),
    );
  }

  String get _absoluteRoot => p.absolute(appRoot);
}

int _lineOf(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

final class _StringLiteralCollector extends RecursiveAstVisitor<void> {
  final literals = <ScannedLiteral>[];

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _record(node);
    super.visitSimpleStringLiteral(node);
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _record(node);
    super.visitStringInterpolation(node);
  }

  void _record(StringLiteral node) {
    if (_belongsToDirective(node)) return;

    literals.add((offset: node.offset, lexeme: node.toSource()));
  }
}

bool _belongsToDirective(AstNode node) {
  AstNode? ancestor = node.parent;
  while (ancestor != null) {
    if (ancestor is Directive) return true;
    ancestor = ancestor.parent;
  }

  return false;
}
