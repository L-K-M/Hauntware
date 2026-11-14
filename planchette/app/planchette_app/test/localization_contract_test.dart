import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_contract/l10n_contract.dart';

// Planchette's localization contract (s07 F7), on the suite's shared
// scanner (`tool/l10n_contract`) as in Poltergeist and Klabautermann. It
// covers the directories and the service files already routed through the
// ARB catalog. The shell, the workspace services and the editor's
// `EditorStrings` feed still hold English literals and join the scan as
// they move to the catalog. The allowlist holds technical literals only,
// reviewed per file.

const _generatedLocalizationPrefix = 'lib/l10n/app_localizations';
const _generatedLocalizationPaths = {
  '$_generatedLocalizationPrefix.dart',
  '${_generatedLocalizationPrefix}_en.dart',
};

const _scannedDirectories = ['lib/ui', 'lib/widgets'];

/// Files routed through the catalog in directories that are not yet whole.
const _scannedFiles = [
  'lib/services/document_dialogs.dart',
  'lib/services/settings_dialog.dart',
];

const _allowedTechnicalLiterals = <String, Set<String>>{
  // The login home, the default remote folder a path field starts at.
  'lib/ui/workspace_remote_folder_dialog.dart': {"'~'"},
  'lib/services/document_dialogs.dart': {
    // The assertion message of an internal invariant, never shown.
    "'the bulk close question covers several files'",
    // File names, one per line.
    r"'\n'",
    // The template locale, for a picker opened before any window context.
    "'en'",
  },
  'lib/services/settings_dialog.dart': {
    // The product name the license page shows above the notices.
    "'Planchette'",
    // Widget keys.
    "'settings.licenses'",
    "'settings.font'",
    // An empty family stands for the default font.
    "''",
    // A slider's value as a number.
    r"'$value'",
  },
  'lib/widgets/disk_notice.dart': {
    // A programming error: no notice is built for a current file.
    r"'Nothing to tell about $name.'",
  },
  'lib/widgets/document_status_bar.dart': {
    // Text tool identifiers.
    "'convertIndentationToSpaces'",
    "'convertIndentationToTabs'",
  },
  'lib/widgets/folder_browser.dart': {
    // A focus node's debug label and widget keys.
    "'Workspace files'",
    "'folder-browser'",
    "'workspace-divider'",
  },
  'lib/widgets/tab_strip.dart': {
    // Widget keys.
    r"'tab-${tab.id}'",
    r"'close-${item.id}'",
    r"'dirty-${item.id}'",
  },
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
    final findings = [
      ...contract.scan(),
      for (final path in _scannedFiles)
        ...contract.findDisallowedLiterals(
          path: path,
          source: File(path).readAsStringSync(),
        ),
    ];

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
