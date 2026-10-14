import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_contract/l10n_contract.dart';

// Klabautermann's localization contract (03 §10.10, D35, A11Y-05): the
// suite's shared scanner (`tool/l10n_contract`, 03 §3.5 F1b) rejects every
// authored literal in lib/ outside the ARB catalogue and this reviewed
// allowlist, as in Poltergeist's localization_contract_test.dart. Two
// checks the scanner does not make stay from the app's interim test: every
// ARB key is referenced from lib/, and no literal fills a slot that
// _userFacingSlotLiteral lists, so a reviewed literal reused in such a slot
// of its own file fails too. Other parameters a surface shows, such as
// Tooltip's message or InputDecoration's labelText, are not checked.

const _generatedLocalizationPrefix = 'lib/l10n/app_localizations';
const _generatedLocalizationPaths = {
  '$_generatedLocalizationPrefix.dart',
  '${_generatedLocalizationPrefix}_en.dart',
};

// gen-l10n is the app's only code generator; one added later brings its
// file suffix here.
const _generatedDartSuffixes = <String>{};

// Technical literals are reviewed per file so an allowlist cannot hide UI copy.
const _allowedTechnicalLiterals = <String, Set<String>>{
  'lib/app.dart': {
    // The settings route's Navigator name.
    "'/settings'",
    // Error-report context; a window that fails to open falls back to the
    // settings route, which is what the user sees.
    "'while opening the settings window'",
  },
  'lib/main.dart': {
    // A file path inside the app's support directory.
    r"'${supportDirectory.path}${Platform.pathSeparator}$name'",
    // Startup debugPrint diagnostics; StartupIssueNotice tells the user
    // the same issues in ARB text.
    r"'settings.json: ${issue.kind.name} ${issue.error ?? ''}'",
    "''",
    r"'ssh_config_imports.json: ${importStoreIssue.kind.name} '",
    r"'${importStoreIssue.detail ?? ''}'",
    // Instance-lock debugPrint diagnostics; AlreadyRunningApp and
    // StartupIssueNotice tell the user in ARB text.
    "'Klabautermann is already running; this instance quits.'",
    r"'$instanceLockFileName: ${issue.error}'",
  },
  // The not-saved diagnostic; the Appearance tab prints it and shows its
  // own ARB text (themeNotSaved).
  'lib/controllers/appearance_controller.dart': {
    r"'The theme was not saved: $error'",
  },
  'lib/controllers/fleet_controller.dart': {
    // The row subtitle's address: host or user@host, with :port when the
    // port is not 22 and an IPv6 host then bracketed before it. Machine
    // data, not copy.
    "''",
    r"'${entry.user}@'",
    r"'$login${entry.host}'",
    "':'",
    r"'[${entry.host}]'",
    r"'$login$host:${entry.port}'",
    // A programmer error and import diagnostics: surfaces show ARB text
    // for a rejected import (sshConfigImportFailed), never its reason.
    "'this platform has no ssh_config to import'",
    "'the engine is not running'",
    "'the engine stopped'",
    "'the fleet controller was disposed'",
    // The rejected request's class name, which RequestRejected carries.
    r"'$ImportSshConfig'",
  },
  'lib/services/macos_titlebar.dart': {
    // The 04 §12.3 method channel name.
    "'klabautermann/window'",
    // debugPrint diagnostics of a failed titlebar install or reset, and of
    // an unavailable toolbar band state.
    r"'Integrated titlebar install failed: $error'",
    r"'Standard titlebar reset failed: $error'",
    r"'Toolbar band state unavailable: $error'",
  },
  // The settings window's wire: channel names, the argument its engine
  // starts with, an error's text as the link carries it, an unknown
  // method's diagnostic and the lost link's diagnostic. Plumbing between
  // two engines; the window shows ARB text for every failure.
  'lib/services/settings_window/settings_window_link.dart': {
    "'klabautermann/settings_window'",
    "'klabautermann/settings_link'",
    "'--klabautermann-settings-window'",
    r"'$error'",
  },
  'lib/services/settings_window/settings_window_host.dart': {
    r"'No settings window method $name'",
  },
  'lib/services/settings_window/remote_settings.dart': {
    "'Settings link closed'",
  },
  // The environment variable the Windows home directory is read from, and
  // the file path the import expands.
  'lib/services/ssh_config_source.dart': {"'USERPROFILE'", "'~/.ssh/config'"},
  'lib/services/window_state.dart': {
    // The state file's name in the support directory (03 §4.10).
    "'window_state.json'",
    // debugPrint diagnostic of a failed restore or save.
    r"'Window state: $error'",
  },
  'lib/theme/app_theme.dart': {
    // The brand preset's stored name, English across the family like the
    // siblings' preset names; no surface shows it yet.
    "'Klabautermann'",
    // The siblings' monospace font stack.
    "'JetBrains Mono'",
    "'SF Mono'",
    "'Menlo'",
    "'Consolas'",
    "'DejaVu Sans Mono'",
    "'monospace'",
  },
  // Chart assert messages, a RangeError's argument name and the read-only
  // ring view's UnsupportedError: programmer diagnostics, never rendered.
  'lib/ui/charts/chart_style.dart': {"'warning must not exceed critical'"},
  'lib/ui/charts/chart_values.dart': {"'samples are finite'"},
  'lib/ui/charts/series_ring.dart': {
    "'a series needs two slots to draw a line'",
    "'index'",
    "'A series ring changes only through add'",
    "'a column holds at least one sample'",
  },
  'lib/ui/charts/sparkline.dart': {"'the scale needs a positive top'"},
  // The command registry's ids, keys of the menus and shortcuts.
  'lib/ui/menus/app_commands.dart': {
    "'app.settings'",
    "'fleet.importSshConfig'",
    "'app.quit'",
  },
  'lib/ui/menus/app_menu_host.dart': {
    // A FocusNode debug label.
    "'AppMenuHost'",
    // Error-report context of a failed command.
    r"'while running ${command.id}'",
  },
  // Menu-model assert messages and the slot key the duplicate check
  // compares; programmer diagnostics, never rendered.
  'lib/ui/menus/app_menus.dart': {
    "'commands reach the macOS application menu through appMenuOnMac'",
    r"'${placement.group}:${placement.order}'",
    r"'${command.id} shares menu slot ${placement.group}:${placement.order}'",
  },
  // debugPrint of a failed theme change; the toast is ARB text.
  'lib/ui/settings_page.dart': {r"'$error'"},
  'lib/ui/sortable_table.dart': {
    // FocusNode debug labels.
    "'SortableTable'",
    "'SortableTable menu'",
    // Widget keys built from the caller's table, column and row ids.
    r"'${widget.tableId}.columns'",
    r"'${widget.tableId}.column.${column.id}'",
    r"'${widget.tableId}.rowActions.$key'",
    r"'${widget.tableId}.row.$key'",
  },
};

const _config = L10nContractConfig(
  generatedLocalizationPrefix: _generatedLocalizationPrefix,
  generatedDartSuffixes: _generatedDartSuffixes,
  scannedDirectories: ['lib'],
);

/// Text and some of the parameters a screen reader or the paint path
/// reaches; not every user-facing parameter (see above).
final _userFacingSlotLiteral = RegExp(
  r'''\b(Text|text|title|subtitle|label|tooltip|hintText|semanticLabel)\s*[(=:]\s*['"][^'"]''',
);

void main() {
  final contract = LocalizationContract(
    appRoot: Directory.current.path,
    config: _config,
    allowedTechnicalLiterals: _allowedTechnicalLiterals,
  );

  /// The authored sources the contract covers, by app-root-relative path.
  Map<String, String> authoredSources() => {
    for (final entity in Directory('lib').listSync(recursive: true))
      if (entity is File && entity.path.endsWith('.dart'))
        if (entity.path.replaceAll('\\', '/') case final path
            when !contract.isGeneratedPath(path))
          path: entity.readAsStringSync(),
  };

  test('limits technical exceptions to their reviewed file', () {
    const source = "const String kSettingsRoute = '/settings';";

    expect(
      contract.findDisallowedLiterals(path: 'lib/app.dart', source: source),
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

  test('keeps every technical exception live', () {
    final dead = contract.scan().whereType<DeadAllowlistEntry>().toList();

    expect(dead, isEmpty, reason: dead.join('\n'));
  });

  test('authors user-facing strings only in ARB', () {
    final findings = contract.scan();

    expect(findings, isEmpty, reason: findings.join('\n'));
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

  test('every ARB key is used by lib/', () {
    final arb =
        jsonDecode(File('lib/l10n/app_en.arb').readAsStringSync())
            as Map<String, Object?>;
    final keys = [
      for (final key in arb.keys)
        if (!key.startsWith('@')) key,
    ];
    // gen-l10n output names every key by construction, so it is left out.
    final sources = authoredSources().values.join('\n');

    expect(keys, isNotEmpty);
    for (final key in keys) {
      expect(
        RegExp('\\b$key\\b').hasMatch(sources),
        isTrue,
        reason: 'ARB key "$key" is never referenced in lib/',
      );
    }
  });

  test('no listed user-facing slot takes a string literal', () {
    for (final MapEntry(key: path, value: source)
        in authoredSources().entries) {
      final match = _userFacingSlotLiteral.firstMatch(source);
      expect(
        match,
        isNull,
        reason: '$path carries a literal into a user-facing slot: ${match?[0]}',
      );
    }
  });
}
