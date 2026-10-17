import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:l10n_contract/l10n_contract.dart';

// Klabautermann's localization contract (03 §10.10, D35, A11Y-05): the
// suite's shared scanner (`tool/l10n_contract`, 03 §3.5 F1b) rejects every
// authored literal in lib/ outside the ARB catalogue and this reviewed
// allowlist, as in Poltergeist's localization_contract_test.dart. The
// allowlist holds technical literals only. Two
// checks the scanner does not make stay from the app's interim test: every
// ARB key is referenced from lib/, and no literal fills a slot that
// _userFacingSlotLiteral lists, so a reviewed literal reused in such a slot
// of its own file fails too. Other parameters a surface shows, such as
// Tooltip's message or InputDecoration's labelText, are not checked, and
// neither is a literal routed through a variable before a listed slot
// (`final words = '...'; Text(words)`): the slot check reads the slot's
// own argument, so the allowlist review is what keeps such a literal out.

const _generatedLocalizationPrefix = 'lib/l10n/app_localizations';
const _generatedLocalizationPaths = {
  '$_generatedLocalizationPrefix.dart',
  '${_generatedLocalizationPrefix}_en.dart',
};

// gen-l10n is the app's only code generator; one added later brings its
// file suffix here.
const _generatedDartSuffixes = <String>{};

// Literals are reviewed per file so an allowlist cannot hide UI copy. Every
// entry is technical.
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
  // The not-saved diagnostic; the General tab prints it and shows its own
  // ARB text (settingsAnnounceNotSaved).
  'lib/controllers/announcement_controller.dart': {
    r"'The announcement setting was not saved: $error'",
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
  'lib/controllers/log_streams.dart': {
    // A log stream id the engine keys a stream's events by (03 §10.1), and
    // the rejected request's class name, which RequestRejected carries.
    r"'log-${_count++}'",
    r"'$OpenLogStream'",
  },
  'lib/controllers/monitoring_controller.dart': {
    // Assert messages; programmer diagnostics, never rendered.
    r"'$stream carries no metrics'",
    "'unsubscribe instead of naming no stream'",
    r"'leaveServer without openServer for $serverId'",
    // A subscription id the engine keys a surface's streams by (D45).
    r"'$surface-${_subscriptionCount++}'",
  },
  // Services panel (SVC-01 to SVC-04, CN-10).
  'lib/controllers/log_reads.dart': {
    // An assert message; programmer diagnostic, never rendered.
    "'a follow is not a bounded read'",
  },
  // The coverage card's one `units` read: a subscription surface kind the
  // engine keys its streams by (D45).
  'lib/ui/server_coverage.dart': {"'coverage'"},
  'lib/ui/services_view.dart': {
    // systemd's spelling of load and sub states and the dot before a unit
    // type, matched against server data; the panel shows ARB text for
    // what does not match (chartUnknownValue).
    "'[A-Z]'",
    r"'-${capital[0]!.toLowerCase()}'",
    r"r'^[a-z][a-z0-9]*(-[a-z0-9]+)*$'",
    "'.'",
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
  'lib/services/ssh_config_source.dart': {
    // The environment variable the Windows home directory is read from, and
    // the file path the import expands.
    "'USERPROFILE'",
    "'~/.ssh/config'",
    // The config text with the byte-order mark the decoder dropped, which
    // the engine must see as ssh does.
    r"'\u{FEFF}$text'",
  },
  'lib/services/window_state.dart': {
    // The state file's name in the support directory (03 §4.10).
    "'window_state.json'",
    // debugPrint diagnostic of a failed restore or save.
    r"'Window state: $error'",
  },
  // The brand preset's stored name, English across the family like the
  // siblings' preset names; no surface shows it yet.
  'lib/theme/app_theme.dart': {"'Klabautermann'"},
  // The Access tab's copied fix command: the pattern of a shell word that
  // needs no quoting, and the space between the command's words.
  'lib/ui/access/access_panel.dart': {r"r'^[A-Za-z0-9_./:@+,-]+$'", "' '"},
  // Chart assert messages, RangeError argument names and the read-only
  // ring view's UnsupportedError: programmer diagnostics, never rendered.
  'lib/ui/charts/bars.dart': {
    "'a stacked bar needs a segment'",
    "'a colour per segment'",
    "'a pressure bar needs a cell'",
    "'a colour per cell'",
    "'a bar has a cell'",
  },
  'lib/ui/charts/chart_style.dart': {"'warning must not exceed critical'"},
  'lib/ui/charts/chart_values.dart': {"'samples are finite'"},
  'lib/ui/charts/series_ring.dart': {
    "'a series needs two slots to draw a line'",
    "'index'",
    "'A series ring changes only through add'",
    "'a column holds at least one sample'",
  },
  'lib/ui/charts/sparkline.dart': {"'the scale needs a positive top'"},
  'lib/ui/charts/time_series.dart': {
    "'a series needs two slots to draw a line'",
    r"'a chart draws 1 to $_maxLanes series'",
    "'lane'",
    "'one value per lane'",
    "'index'",
    "'a column spans time'",
  },
  'lib/ui/charts/time_series_chart.dart': {
    "'one label per lane'",
    "'the window spans time'",
    "'the scale needs a positive top'",
  },
  // debugPrint of a dismissal that was not saved; the toast is ARB text.
  'lib/ui/coverage.dart': {r"'$error'"},
  'lib/ui/fleet_row_state.dart': {
    // The root mount point whose use the pressure bar shows.
    "'/'",
    // The filter's term separator, and the name-and-address haystack that
    // stands in for the engine's search text.
    r"r'\s+'",
    r"'${server.displayName} ${server.address ?? ''}'",
    "''",
  },
  'lib/ui/fleet_rows.dart': {
    // The filter's empty query.
    "''",
    // A FocusNode debug label.
    "'Fleet filter'",
    // The key tests find a row's age by.
    "'fleetRowAge'",
    // The line break between the row tooltip's facts, each ARB text.
    r"'\n'",
    // An assert message; programmer diagnostic, never rendered.
    "'new controllers come with a new tree (KlabautermannApp, D44)'",
  },
  // The probe's tool name for crontab, looked up in its answer; never
  // rendered.
  'lib/ui/jobs_panel.dart': {"'crontab'"},
  'lib/ui/logs/log_query.dart': {
    // The path rule's separators and dot parts (03 §8.8), and the empty
    // defaults of the text filters.
    "'/'",
    "'..'",
    "'/.'",
    "'/./'",
    "''",
    // LOG-22's common paths: paths on the server, shown verbatim as
    // server data (03 §10.10).
    "'/var/log/syslog'",
    "'/var/log/messages'",
    "'/var/log/auth.log'",
    "'/var/log/secure'",
    "'/var/log/nginx/access.log'",
    "'/var/log/nginx/error.log'",
    "'/var/log/apache2/access.log'",
    "'/var/log/apache2/error.log'",
    "'/var/log/httpd/access_log'",
    "'/var/log/httpd/error_log'",
  },
  // The search's initial empty query.
  'lib/ui/logs/log_search.dart': {"''"},
  'lib/ui/logs/log_text.dart': {
    // A row's unit and PID prefix in classic syslog notation, as
    // journalctl's short format prints it, or none.
    "''",
    r"'[${journal.pid}]'",
    r"'${journal.source ?? ''}$pid'",
    r"'$source: '",
    // The newline a journal MESSAGE's return mark and line separator
    // replace, the mark itself (a symbol, not words) and the space before
    // a cut line's note, whose words are ARB text (logLineCut).
    r"'\n'",
    r"'\u23ce\u2028'",
    "' '",
  },
  'lib/ui/logs/log_view.dart': {
    // A FocusNode debug label.
    "'LogView'",
    // A journal field in journald's NAME=value notation, with newlines and
    // line or paragraph separators flattened to spaces to keep one row.
    r"'$name=$value'",
    r"'\n'",
    "' '",
    r"'[\u2028\u2029]'",
    // Glyph probes that measure the line height (the space above) and the
    // advance, never shown.
    "'W'",
  },
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
  'lib/ui/processes_panel.dart': {
    // The key tests find a phone row by, in the table rows' form, and the
    // line break between its cells in its screen-reader label, each ARB
    // text.
    r"'${SampleStream.procs.name}.row.${row.pid}'",
    r"'\n'",
  },
  'lib/ui/processes_view.dart': {
    // The ellipsis ending a cut command line, the space between its
    // arguments, and the filter's term separator and the line break
    // between the fields it searches. The plus sign GNU ps ends a cut
    // user name with, which is matched, never shown.
    r"'${text.substring(0, end)}…'",
    "' '",
    r"r'\s+'",
    r"'\n'",
    "'+'",
  },
  // An assert message; programmer diagnostic, never rendered.
  'lib/ui/server_surfaces.dart': {
    "'new controllers come with a new tree (KlabautermannApp, D44)'",
  },
  // The trailing core number of a /proc/stat name such as cpu12, which
  // orders the per-core figures; the names themselves are server data.
  'lib/ui/overview_panel.dart': {r"r'\d+$'"},
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
  // What systemd-detect-virt prints for no virtualization, compared with
  // the probe's answer; the System tab shows ARB text for it
  // (systemVirtualizationNone).
  'lib/ui/system_view.dart': {"'none'"},
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
