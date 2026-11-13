import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_contract/l10n_contract.dart';

// Planchette's localization contract (s07 F7), on the suite's shared
// scanner (`tool/l10n_contract`) as in Poltergeist and Klabautermann. It
// covers the directories already routed through the ARB catalog; the shell,
// the workspace services, the dialogs service and the widgets still hold
// English literals and join [_scannedDirectories] as they move to the
// catalog. The allowlist holds technical literals only, reviewed per file.

const _generatedLocalizationPrefix = 'lib/l10n/app_localizations';
const _generatedLocalizationPaths = {
  '$_generatedLocalizationPrefix.dart',
  '${_generatedLocalizationPrefix}_en.dart',
};

const _scannedDirectories = ['lib/ui'];

const _allowedTechnicalLiterals = <String, Set<String>>{
  // The login home, the default remote folder a path field starts at.
  'lib/ui/workspace_remote_folder_dialog.dart': {"'~'"},
  'lib/ui/workspace_servers_dialog.dart': {
    // An empty filter and empty form fields.
    "''",
    // The text a server filter matches against, never shown.
    r"'${server.label}\n${server.host}\n${server.username}'",
    // An SSH address in user@host:port notation.
    r"'${server.username}@${server.host}:${server.port}'",
  },
};

const _config = L10nContractConfig(
  generatedLocalizationPrefix: _generatedLocalizationPrefix,
  generatedDartSuffixes: {},
  scannedDirectories: _scannedDirectories,
);

void main() {
  final contract = LocalizationContract(
    appRoot: Directory.current.path,
    config: _config,
    allowedTechnicalLiterals: _allowedTechnicalLiterals,
  );

  test('keeps every technical exception live', () {
    final dead = contract.scan().whereType<DeadAllowlistEntry>().toList();

    expect(dead, isEmpty, reason: dead.join('\n'));
  });

  test('authors user-facing strings only in ARB', () {
    final findings = contract.scan();

    expect(findings, isEmpty, reason: findings.join('\n'));
  });

  test('generated localization output is present', () {
    for (final path in _generatedLocalizationPaths) {
      expect(
        File(path).existsSync(),
        isTrue,
        reason: 'generated localization output is missing: $path',
      );
    }
  });

  test('every ARB key is used by lib/', () {
    final arb =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
            as Map<String, Object?>;
    final sources = [
      for (final entity in Directory('lib').listSync(recursive: true))
        if (entity is File &&
            entity.path.endsWith('.dart') &&
            !contract.isGeneratedPath(entity.path.replaceAll('\\', '/')))
          entity.readAsStringSync(),
    ].join('\n');
    final keys = [
      for (final key in arb.keys)
        if (!key.startsWith('@')) key,
    ];

    expect(keys, isNotEmpty);
    for (final key in keys) {
      expect(
        RegExp('\\b$key\\b').hasMatch(sources),
        isTrue,
        reason: 'ARB key "$key" is never referenced in lib/',
      );
    }
  });
}
