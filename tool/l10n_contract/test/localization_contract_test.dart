import 'dart:io';

import 'package:l10n_contract/l10n_contract.dart';
import 'package:test/test.dart';

const _config = L10nContractConfig(
  generatedLocalizationPrefix: 'lib/l10n/app_localizations',
  generatedDartSuffixes: {'.g.dart'},
  scannedDirectories: ['lib'],
);

LocalizationContract _contract({
  String appRoot = 'test/fixtures/mini_app',
  Map<String, Set<String>> allowed = const {},
}) => LocalizationContract(
  appRoot: appRoot,
  config: _config,
  allowedTechnicalLiterals: allowed,
);

void main() {
  test('rejects representative authored user-facing literals', () {
    const unlocalizedSources = <({String path, String source})>[
      (
        path: 'lib/ui/example.dart',
        source: "void fixture() { const Text('Disconnected'); }",
      ),
      (
        path: 'lib/ui/example.dart',
        source:
            "void fixture() { const SelectableText('Server disconnected'); }",
      ),
      (
        path: 'lib/ui/example.dart',
        source: "void fixture() { const TextSpan(text: 'Transfer failed'); }",
      ),
      (
        path: 'lib/ui/example.dart',
        source:
            "void fixture() { const InputDecoration(hintText: 'Remote path'); }",
      ),
      (
        path: 'lib/services/example.dart',
        source: "String failureSummary() => 'Connection failed';",
      ),
    ];

    for (final fixture in unlocalizedSources) {
      final offenders = _contract().findDisallowedLiterals(
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

  test('detects user-facing literals nested in interpolation', () {
    const source = "void fixture() { Text('\${wrap('Disconnected')}'); }";

    final offenders = _contract().findDisallowedLiterals(
      path: 'lib/ui/example.dart',
      source: source,
    );

    expect(
      offenders.map((literal) => literal.lexeme),
      contains("'Disconnected'"),
    );
  });

  test('does not let interpolation syntax hide following literals', () {
    const source = '''
void fixture(String path) {
  '\${path.replaceAll('//', '/')}';
  Text('After');
}
''';

    final offenders = _contract().findDisallowedLiterals(
      path: 'lib/ui/example.dart',
      source: source,
    );

    expect(offenders.map((literal) => literal.lexeme), contains("'After'"));
  });

  test('limits technical exceptions to their reviewed file', () {
    const source = "const paneRatioKey = 'layout.paneRatio';";
    final contract = _contract(
      allowed: {
        'lib/services/app_preferences.dart': {"'layout.paneRatio'"},
      },
    );

    expect(
      contract.findDisallowedLiterals(
        path: 'lib/services/app_preferences.dart',
        source: source,
      ),
      isEmpty,
    );
    expect(
      contract.findDisallowedLiterals(
        path: 'lib/ui/example.dart',
        source: source,
      ),
      isNotEmpty,
    );
  });

  test('ignores directives, comments, and generated files', () {
    const source = """
import 'package:flutter/widgets.dart';
import 'default.dart'
    if (dart.library.io) 'native.dart';
// Text('Comment only')
/* SelectableText('Also a comment') */
""";

    final contract = _contract();
    expect(
      contract.findDisallowedLiterals(path: 'lib/example.dart', source: source),
      isEmpty,
    );
    expect(
      contract.findDisallowedLiterals(
        path: 'lib/example.g.dart',
        source: "'copy'",
      ),
      isEmpty,
    );
  });

  test('ignores generated output for every locale', () {
    const source = "String get actionLabel => 'Copier';";

    expect(
      _contract().findDisallowedLiterals(
        path: 'lib/l10n/app_localizations_fr.dart',
        source: source,
      ),
      isEmpty,
    );
  });

  test('rejects source with parser diagnostics', () {
    const malformedSource = "void fixture() { Text('Hidden');";

    expect(
      () => _contract().scanStringLiterals(malformedSource),
      throwsA(isA<LocalizationParseException>()),
    );
  });

  test('reports the planted literal and skips generated output', () {
    final findings = _contract(
      allowed: {
        'lib/technical.dart': {"'layout.paneRatio'"},
      },
    ).scan();

    expect(
      findings.whereType<DisallowedLiteral>().map((finding) => finding.lexeme),
      equals(["'Disconnected'"]),
    );
    expect(findings.whereType<DeadAllowlistEntry>(), isEmpty);
    expect(findings.whereType<UnparseableSource>(), isEmpty);
  });

  test('reports a dead allowlist entry', () {
    final findings = _contract(
      allowed: {
        'lib/technical.dart': {"'layout.paneRatio'", "'gone'"},
      },
    ).scan();

    expect(
      findings.whereType<DeadAllowlistEntry>().map(
        (finding) => finding.literal,
      ),
      equals(["'gone'"]),
    );
  });

  test('reports an unparseable source', () {
    final findings = _contract(appRoot: 'test/fixtures/broken_app').scan();

    expect(findings.whereType<UnparseableSource>(), hasLength(1));
  });

  test('reports an unparseable allowlisted file outside the scan', () {
    final contract = LocalizationContract(
      appRoot: 'test/fixtures/broken_app',
      config: const L10nContractConfig(
        generatedLocalizationPrefix: 'lib/l10n/app_localizations',
        generatedDartSuffixes: {'.g.dart'},
        scannedDirectories: ['bin'],
      ),
      allowedTechnicalLiterals: const {
        'lib/broken.dart': {"'Hidden'"},
      },
    );

    expect(
      contract.scan().whereType<UnparseableSource>().map(
        (finding) => finding.path,
      ),
      equals(['lib/broken.dart']),
    );
  });

  test('reports an unparseable allowlisted file only once', () {
    // Non-canonical spellings of the scanned directory must still count
    // as covering the file.
    for (final directory in ['lib', 'lib/', './lib']) {
      final findings = LocalizationContract(
        appRoot: 'test/fixtures/broken_app',
        config: L10nContractConfig(
          generatedLocalizationPrefix: 'lib/l10n/app_localizations',
          generatedDartSuffixes: const {'.g.dart'},
          scannedDirectories: [directory],
        ),
        allowedTechnicalLiterals: const {
          'lib/broken.dart': {"'Hidden'"},
        },
      ).scan();

      expect(
        findings.whereType<UnparseableSource>(),
        hasLength(1),
        reason: 'scanned directory: $directory',
      );
      expect(findings.whereType<DeadAllowlistEntry>(), isEmpty);
    }
  });

  test('reports an unreadable allowlisted file instead of throwing', () {
    final appRoot = Directory.systemTemp.createTempSync('l10n_contract_');
    addTearDown(() => appRoot.deleteSync(recursive: true));
    // Bytes that are not valid UTF-8, inside and outside the scan.
    for (final path in ['lib/bad.dart', 'tool/bad.dart']) {
      File('${appRoot.path}/$path')
        ..createSync(recursive: true)
        ..writeAsBytesSync([0xff, 0xfe]);
    }

    final findings = _contract(
      appRoot: appRoot.path,
      allowed: {
        'lib/bad.dart': {"'x'"},
        'tool/bad.dart': {"'y'"},
      },
    ).scan();

    expect(
      findings.whereType<UnparseableSource>().map((finding) => finding.path),
      equals(['lib/bad.dart', 'tool/bad.dart']),
    );
    expect(findings.whereType<DeadAllowlistEntry>(), isEmpty);
  });

  test('fails closed when a scanned directory is missing', () {
    final contract = LocalizationContract(
      appRoot: 'test/fixtures/mini_app',
      config: const L10nContractConfig(
        generatedLocalizationPrefix: 'lib/l10n/app_localizations',
        generatedDartSuffixes: {'.g.dart'},
        scannedDirectories: ['lib', 'packages'],
      ),
      allowedTechnicalLiterals: const {},
    );

    expect(
      contract.scan().whereType<UnparseableSource>().map(
        (finding) => finding.path,
      ),
      contains('packages'),
    );
  });

  test('fails closed when a scanned directory has nothing to scan', () {
    final emptyRoot = Directory.systemTemp.createTempSync('l10n_contract_');
    addTearDown(() => emptyRoot.deleteSync(recursive: true));
    Directory('${emptyRoot.path}/lib').createSync();

    final contracts = [
      _contract(appRoot: emptyRoot.path),
      // A suffix that marks every file under lib/ as generated output.
      LocalizationContract(
        appRoot: 'test/fixtures/mini_app',
        config: const L10nContractConfig(
          generatedLocalizationPrefix: 'lib/l10n/app_localizations',
          generatedDartSuffixes: {'.dart'},
          scannedDirectories: ['lib'],
        ),
        allowedTechnicalLiterals: const {},
      ),
    ];

    for (final contract in contracts) {
      expect(
        contract.scan().whereType<UnparseableSource>().map(
          (finding) => finding.path,
        ),
        equals(['lib']),
      );
    }
  });

  test('rejects a configuration that cannot scan anything', () {
    const configs = [
      L10nContractConfig(
        generatedLocalizationPrefix: 'lib/l10n/app_localizations',
        generatedDartSuffixes: {'.g.dart'},
        scannedDirectories: [],
      ),
      L10nContractConfig(
        generatedLocalizationPrefix: '',
        generatedDartSuffixes: {'.g.dart'},
        scannedDirectories: ['lib'],
      ),
      L10nContractConfig(
        generatedLocalizationPrefix: 'lib/l10n/app_localizations',
        generatedDartSuffixes: {''},
        scannedDirectories: ['lib'],
      ),
    ];

    for (final config in configs) {
      final contract = LocalizationContract(
        appRoot: 'test/fixtures/mini_app',
        config: config,
        allowedTechnicalLiterals: const {},
      );

      expect(contract.scan, throwsArgumentError);
    }
  });
}
