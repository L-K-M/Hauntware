import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_contract/l10n_contract.dart';

// Planchette's localization contract (s07 F7), on the suite's shared
// scanner (`tool/l10n_contract`) as in Poltergeist and Klabautermann. It
// covers the directories, the shell and the service files already routed
// through the ARB catalog. The remaining workspace services still hold
// English literals and join the scan as they move to the catalog. The
// allowlist holds technical literals only, reviewed per file.

const _generatedLocalizationPrefix = 'lib/l10n/app_localizations';
const _generatedLocalizationPaths = {
  '$_generatedLocalizationPrefix.dart',
  '${_generatedLocalizationPrefix}_en.dart',
};

const _scannedDirectories = ['lib/ui', 'lib/widgets'];

/// Files routed through the catalog in directories that are not yet whole.
const _scannedFiles = [
  'lib/planchette_app.dart',
  'lib/services/document_dialogs.dart',
  'lib/services/settings_dialog.dart',
];

const _allowedTechnicalLiterals = <String, Set<String>>{
  // The shared-editor strings adapter: the text-tool, option and choice
  // ids it switches on (the shared catalog's stable machine identifiers),
  // the ARB list joiners and detail tokens it decomposes, the menu-label
  // ellipsis composition, and the brace-bearing regex tokens that ride
  // through gen-l10n as placeholder values because ICU messages cannot
  // hold literal braces. Every rendered word comes from the ARB catalog.
  'lib/ui/editor_strings.dart': {
    '\'  \'',
    '\'{2,4}\'',
    '\'{1}\'',
    '\'{name}\'',
    '\'\\n\'',
    '\'{NNNN}\'',
    '\'sortLines\'',
    '\'reverseLines\'',
    '\'shuffleLines\'',
    '\'removeDuplicateLines\'',
    '\'removeBlankLines\'',
    '\'collapseBlankLines\'',
    '\'uppercase\'',
    '\'lowercase\'',
    '\'titleCase\'',
    '\'sentenceCase\'',
    '\'camelCase\'',
    '\'pascalCase\'',
    '\'snakeCase\'',
    '\'kebabCase\'',
    '\'constantCase\'',
    '\'trimTrailingWhitespace\'',
    '\'trimLeadingWhitespace\'',
    '\'normalizeSpaces\'',
    '\'normalizeLineEndings\'',
    '\'convertIndentationToSpaces\'',
    '\'convertIndentationToTabs\'',
    '\'convertTabsToSpaces\'',
    '\'hardWrap\'',
    '\'straightenQuotes\'',
    '\'zapGremlins\'',
    '\'removeAnsiEscapes\'',
    '\'convertToAscii\'',
    '\'stripDiacritics\'',
    '\'composeAccents\'',
    '\'decomposeAccents\'',
    '\'prefixSuffixLines\'',
    '\'numberLines\'',
    '\'unwrapParagraphs\'',
    '\'joinLinesWith\'',
    '\'urlEncode\'',
    '\'urlDecode\'',
    '\'base64Encode\'',
    '\'base64Decode\'',
    '\'htmlEntityEncode\'',
    '\'htmlEntityDecode\'',
    '\'escapeJsonString\'',
    '\'unescapeBackslashSequences\'',
    '\'formatJson\'',
    '\'minifyJson\'',
    '\'insertDate\'',
    '\'insertDateTime\'',
    '\'insertUtcTimestamp\'',
    '\'insertUuid\'',
    '\'keepLinesMatching\'',
    '\'deleteLinesMatching\'',
    '\'extractMatches\'',
    '\'\$name…\'',
    '\'order\'',
    '\'ignoreCase\'',
    '\'numbersByValue\'',
    '\'byLength\'',
    '\'ignoreLeadingWhitespace\'',
    '\'keepFirstLine\'',
    '\'adjacentOnly\'',
    '\'ignoreSurroundingWhitespace\'',
    '\'keepBlankLines\'',
    '\'removeEveryCopy\'',
    '\'controls\'',
    '\'invisible\'',
    '\'bidi\'',
    '\'damaged\'',
    '\'nonAscii\'',
    '\'action\'',
    '\'character\'',
    '\'mode\'',
    '\'where\'',
    '\'text\'',
    '\'skipBlankLines\'',
    '\'start\'',
    '\'step\'',
    '\'separator\'',
    '\'padding\'',
    '\'trim\'',
    '\'width\'',
    '\'fill\'',
    '\'ascending\'',
    '\'descending\'',
    '\'insert\'',
    '\'remove\'',
    '\'add\'',
    '\'prefix\'',
    '\'suffix\'',
    '\'none\'',
    '\'spaces\'',
    '\'zeros\'',
    '\'delete\'',
    '\'escape\'',
    '\'replace\'',
    '\'entity\'',
    '\'inPlace\'',
    '\'clipboard\'',
    '\'newDocument\'',
    '\'\'',
    '\', \'',
    '\':\'',
    '\'lines\'',
    '\'unmapped:\'',
    'r\'\\u{…}\'',
  },
  'lib/planchette_app.dart': {
    // The product name: window title, application menu, app bar.
    "'Planchette'",
    // Menu command ids the palette resolves commands by, never shown.
    "'browseTextTools'",
    "'clearRecentDocuments'",
    "'closeFolderWorkspace'",
    "'closeTab'",
    "'closeWindow'",
    "'commandPalette'",
    "'compareWithSaved'",
    "'copy'",
    "'copyLine'",
    "'copyPath'",
    "'cut'",
    "'cutLine'",
    "'decrementNumber'",
    "'deleteLines'",
    "'duplicateLines'",
    "'exportHtml'",
    "'extractMatches'",
    "'find'",
    "'findInSelection'",
    "'findNext'",
    "'findPrevious'",
    "'goToLine'",
    "'goToMatchingBracket'",
    "'incrementNumber'",
    "'insertLineAbove'",
    "'insertLineBelow'",
    "'joinLines'",
    "'moveLinesDown'",
    "'moveLinesUp'",
    "'new'",
    "'newWindow'",
    "'nextProblem'",
    "'nextTab'",
    "'noRecentDocuments'",
    "'noRecentRuns'",
    "'open'",
    "'openContainingFolder'",
    "'openFolder'",
    "'openServer'",
    "'paste'",
    "'pasteMatchIndentation'",
    "'previousProblem'",
    "'previousTab'",
    "'quit'",
    "'recoverRemoteEdits'",
    "'redo'",
    "'reopenClosedTab'",
    "'repeatTextTool'",
    "'replace'",
    "'revertToSaved'",
    "'save'",
    "'saveAll'",
    "'saveAs'",
    "'selectAll'",
    "'selectEnclosingBrackets'",
    "'selectLine'",
    "'selectParagraph'",
    "'selectToMatchingBracket'",
    "'settings'",
    "'toggleComment'",
    "'toggleSidebar'",
    "'undo'",
    r"'openRecent:$index'",
    r"'recentTextTool:$index'",
    r"'window:${other.serial}'",
    // Alt mnemonic letters, matched against the localized label; a label
    // without the letter shows unmarked.
    "'a'",
    "'b'",
    "'c'",
    "'d'",
    "'e'",
    "'f'",
    "'g'",
    "'i'",
    "'j'",
    "'l'",
    "'n'",
    "'o'",
    "'p'",
    "'q'",
    "'r'",
    "'s'",
    "'t'",
    "'u'",
    "'v'",
    "'w'",
    "'x'",
    // Widget keys, an Expando's debug name and a connection's window id.
    "'reopen-with-encoding'",
    "'settings-error-banner'",
    "'workspace-error-banner'",
    "'window-drop-highlight'",
    r"'disk-notice-${tab.id}'",
    "'recorded path'",
    r"'window-${window?.serial ?? identityHashCode(workspace)}'",
    // A CSS hex color for the HTML export, and its zero padding.
    r"'#${(color.toARGB32() & 0xffffff).toRadixString(16).padLeft(6, '0')}'",
    "'0'",
    // The palette's menu-path joiner and an empty tool description.
    r"'$path > $label'",
    "''",
  },
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
