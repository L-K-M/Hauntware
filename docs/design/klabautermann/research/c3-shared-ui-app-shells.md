# C3: Shared UI packages and app-shell architecture for a fourth Hauntware app

Research input for the server app plan, captured 2026-10-10 (codebase reports at commit bf1da58). Not maintained; see [../README.md](../README.md).

Read-only investigation of the Hauntware repository at `bf1da58` (main, 2026-10-10).
All paths are repo-relative. Line numbers were read from this checkout. No repo
file was modified. "Fourth app" below means the planned server management,
observability and Docker tool; `<app>` is a placeholder for its name.

Sources read first: root `AGENTS.md`, `planchette/AGENTS.md`, `seance/AGENTS.md`
(sections 2 and 7), `poltergeist/AGENTS.md`, `docs/design/*.md`,
`poltergeist/docs/PORTS.md`, `poltergeist/docs/plan/10-WORKSPACE-REDESIGN.md`
(sections 3, 10, 11), `seance/docs/POLTERGEIST.md`. Every claim was then checked
against code.

---

## 0. Summary

- Five shared Flutter/Dart packages live under `planchette/packages/`:
  `ghost_ui` (leaf widgets, sidebar kit, menus, toasts, colour picker, file rows),
  `ghost_marks` (server badges, accents, mark and colour pickers over
  `seance_protocol`), `ghost_desktop` (window lifecycle, macOS toolbar band,
  Settings-window link engine), `planchette_editor` (editor surface) and
  `planchette_core` (pure Dart syntax, validation, diff, search). A fourth app
  can consume all five unchanged by relative path, as Séance and Poltergeist do
  (`seance/app/seance_app/pubspec.yaml:11-20`,
  `poltergeist/app/poltergeist_app/pubspec.yaml:14-15,44-51`).
- The server-list surface is only partly shared. Shared today: the sidebar kit
  rows/headers/filter/bottom bar (`ghost_ui`), badges/accents/pickers
  (`ghost_marks`), and pure helpers in `seance_protocol` (group normalization,
  search haystack, duplication). Still duplicated per app: the server rail
  section composition, the status-dot vocabulary, the server editor form
  (~84% line-identical after whitespace normalization), the TOFU,
  keyboard-interactive and missing-credential dialogs, connection log/test
  report, theme palette/presets/appearance stack, splitter, keystore manager,
  file stores, and the sync enrollment UI.
- The two apps use different state architectures: Séance has one 3,027-line
  `AppState extends ChangeNotifier` exposed through an `AppScope`
  InheritedWidget over an `AppServices` bag; Poltergeist composes ~40
  narrow controllers in `main.dart` and runs SSH in an engine isolate. Neither
  uses provider/riverpod/bloc. Poltergeist's composition-root + narrow-seam
  style (e.g. `ServerEditorDelegate`) is the better template for a third
  server-list consumer.
- Localization: only Poltergeist has ARB (`gen-l10n`, ~1,870 keys) and an
  analyzer-based localization contract test; Séance and Planchette author
  English literals. Shared packages take strings through string bags, so they
  work for both.
- No chart, sparkline or table/virtualized-log component exists anywhere in the
  repo or its 13 lockfiles. The only `CustomPainter`s are two leaf painters in
  shared packages. Recommended: an in-house zero-dependency painter package for
  sparklines/gauges/time series; consider `fl_chart` 1.2.0 (MIT) only if rich
  interactive charts are needed.
- Recommended extraction before or alongside the fourth app (names follow
  `ghost_*`): `ghost_servers` (server rail section model, status-dot
  vocabulary, server editor + delegate, connection test report/log view),
  `ghost_prompts` (TOFU, keyboard-interactive, credential dialogs; could fold
  into `ghost_servers`), `ghost_theme` (palette/presets/appearance/chrome/status
  colours + appearance settings page). New for the fourth app: `ghost_charts`
  and a virtualized log viewer (`ghost_logs`). Main risks: string-bag
  migration against Poltergeist's contract test, ServerConfig field
  carry-over on save (sync data loss), pixel baselines, and the rule that a
  shared UI package may depend on `seance_protocol` but never on `seance_core`.

---

## 1. Reusable widgets and services

### 1.1 Package charters and dependency rules (verified)

| Rule | Evidence |
|---|---|
| Shared document/UI packages stay host-neutral; UI uses host services | `AGENTS.md:42` |
| Shared packages use relative paths | `AGENTS.md:20-21` |
| Each product keeps its own pure-Dart workspace; root pubspec is not a Flutter workspace | `AGENTS.md:15-16` |
| Preserve application IDs, keychain names, wire formats, user data | `AGENTS.md:44` |
| All owned package/app versions follow the suite version | `AGENTS.md:47`; every shared pubspec is `version: 1.9.0` (e.g. `planchette/packages/ghost_ui/pubspec.yaml:7`) |
| `ghost_ui`: "shared leaf UI widgets/theme tokens; ... no app or host dependencies" | `planchette/AGENTS.md:24-25` |
| `ghost_ui` deps: `flutter`, `flutter_svg ^2.3.0`, `intl ^0.20.3` only | `planchette/packages/ghost_ui/pubspec.yaml:14-20` |
| `ghost_marks` deps: `flutter`, `file_picker ^11.0.2`, `ghost_ui`, `seance_protocol` ("never seance_core: Poltergeist consumes this package and must not inherit dartssh2") | `planchette/packages/ghost_marks/pubspec.yaml:14-27` |
| `ghost_desktop` deps: `screen_retriever ^0.2.2`, `window_manager ^0.5.2` | `planchette/packages/ghost_desktop/pubspec.yaml:14-18` |
| `planchette_editor` deps: `clock`, `ghost_ui`, `planchette_core` | `planchette/packages/planchette_editor/pubspec.yaml:10-18` |
| `planchette_core` is a pure-Dart workspace member | `planchette/packages/planchette_core/pubspec.yaml:5` (`resolution: workspace`) |
| Host-agnostic contract: strings via string bags, colours via `SidebarThemeTokens` or ambient theme, behavior via callbacks | `planchette/packages/ghost_ui/lib/ghost_ui.dart:1-7` |
| Shared UI must not depend on `seance_core` (pulls dartssh2); `ghost_marks` sits in `planchette/packages`, not `seance/packages` | `docs/design/server-appearance-package.md:64,85,92` |
| dartssh2 confined to Poltergeist's core connection module, enforced by import guard | `poltergeist/tool/import_guard/lib/import_guard.dart:144-148,191-198`; `poltergeist/tool/import_guard/README.md:11-14` |

### 1.2 `ghost_ui` (planchette/packages/ghost_ui)

Barrel: `planchette/packages/ghost_ui/lib/ghost_ui.dart:10-29`.

| Component | Location | Fourth-app use |
|---|---|---|
| Sidebar kit: `SidebarKitLayout {rail, list}` | `lib/src/sidebar_kit.dart:236` | rail on desktop/tablet, list on phone home |
| `SidebarKitDensity {compact, comfortable}`, `sidebarHomeLayout` | `sidebar_kit.dart:247,251` | same density switch as siblings |
| `sidebarMarkExtent`, `sidebarGlyphSize` | `sidebar_kit.dart:294,299` | sizing server badges |
| `SidebarKitStrings` (injected copy) | `sidebar_kit.dart:312-347` | ARB-mapped like Poltergeist `ui/sidebar/sidebar_view.dart:638-650` |
| `SidebarKitScope(strings, background, layout, density)` | `sidebar_kit.dart:351-358` | one per rail |
| `SidebarMenuEntry/Action/Divider/Submenu`, `sidebarMenuWidgets`, `showSidebarMenuSheet` | `sidebar_kit.dart:487-512,546,600` | per-server verbs (Open dashboard, Containers, Logs, Edit, Pin, Duplicate) |
| `SidebarSectionHeader` (title, count, collapsed, onAdd, `status` + `statusLabel` for hidden live rows) | `sidebar_kit.dart:707-760` | PINNED / SERVERS / groups |
| `SidebarRow` (mark, one `SidebarStatusDot`, subtitle, `trailingText`, `trailingIcon`, `hoverAction`, `accent`, `markRing`, `menuEntries`, `tooltip`, `semanticLabel`) | `sidebar_kit.dart:1245-1330` | server row; `trailingText` could carry a load figure, `subtitle` the address |
| `SidebarDotStyle {solid, ring, blocked}`, `SidebarStatusDot` | `sidebar_kit.dart:1210,1216-1229` | status vocabulary paint |
| `SidebarFilterField` | `sidebar_kit.dart:1992` | server filter |
| `SidebarSyncTone`, `SidebarSyncChipData`, `SidebarBottomBar` ("+", sync chip, density, gear) | `sidebar_kit.dart:2145-2194` | identical rail foot |
| `SidebarDensitySwitch` | `sidebar_kit.dart:2356` | |
| `SidebarThemeTokens` ThemeExtension | `lib/src/sidebar_theme_tokens.dart:35-75` | host chrome adapter (Séance `lib/theme.dart:661-670`, Poltergeist `lib/theme/app_theme.dart:864`) |
| `showTopToast`, `showTopToastIn` (top-anchored notices, never bottom SnackBars) | `lib/src/top_toast.dart:8-57` | all transient notices |
| `ThemeModePreference`, `surfaceBrightness`, `automaticBrightness` | `lib/src/appearance.dart:12-36` | theme mode |
| `contrastRatio`, `compositeOver`, `legibleOn` | `lib/src/contrast.dart:13-25` | chart label contrast, status colours |
| `FamilyHue` (12 hues), `FamilyPalette`, `FamilyHueTile` | `lib/src/family_hues.dart:38,56,162` | glyph colours; candidate series palette for charts |
| `ColorPickerStrings`, `showColorPicker`, `ColorSwatchBox` | `lib/src/color_picker.dart:6,38,315` | theme editor |
| `encodeBadgeImage`, `BadgeImage`, `BadgeImageFailure`, `looksLikeSvg` | `lib/src/badge_image.dart:84-118,273` | via ghost_marks pickers |
| Chords: `formatShortcutActivator`, `GhostChordBinding`, `dispatchGhostChord`, `GhostChordScope` | `lib/src/ghost_chords.dart:9,67,116,164` | keyboard shortcuts |
| Command menus: `GhostCommandSpec`, `GhostMenu`, `ghostPlatformMenus`, `CheckedPlatformMenuDelegate`, `GhostShortcutHint`, `ghostMenuBarChildren` | `lib/src/ghost_command_menu.dart:12,97,245,335,433,573` | native macOS menu + Linux/Windows menu bar from one registry |
| `GhostMenuTheme.apply`, `GhostMenuItem`, `GhostMenuDivider`, `ghostTextContextMenu` | `lib/src/ghost_menus.dart:26,80,154,175` | pointer menus |
| `MiddleEllipsisText` | `lib/src/middle_ellipsis_text.dart:10` | container names, image digests, paths |
| `SelectedTabView` (in-place tabs, keep-alive, no hidden focus) | `lib/src/selected_tab_view.dart:29` | container detail tabs, inspector |
| File-list rendering: `GhostFileRow`, `GhostFileCompactRow`, `GhostFileColumnHeader`, `GhostFileColumnMetrics`, `GhostFileTheme` | `lib/src/ghost_file_row.dart:131`, `ghost_file_compact_row.dart:31`, `ghost_file_columns.dart:18,226`, `ghost_file_theme.dart:11` | pattern for tables; columns are file-specific (`GhostFileColumn {name,size,modified}`, `ghost_file_columns.dart:183`) |
| Formatting: `ghostFormatFileSize` (decimal on macOS/Linux, binary on Windows), `ghostFormatFileModified`, `ghostFormatPosixModeSymbolic/Octal`, `ghostUnevaluated` | `lib/src/ghost_file_format.dart:21-25,77,120,143` | disk/volume sizes; note server tools report IEC binary units, see section 5 |

### 1.3 `ghost_marks` (planchette/packages/ghost_marks)

Barrel: `planchette/packages/ghost_marks/lib/ghost_marks.dart:1-14`. Purpose:
"identical server records draw identical marks in both apps"
(`ghost_marks.dart:1-4`).

| Component | Location |
|---|---|
| `ServerAccent`, `serverAccent(context, tint)` | `lib/src/server_appearance.dart:33,70` |
| `ServerTint` | `server_appearance.dart:129` |
| `formatServerCustomColor`, `parseServerCustomColor`, `nearestServerColor` | `server_appearance.dart:171,179,195` |
| `serverIconData`, `serverIconLabel`, `serverIconMatches` | `server_appearance.dart:627,634,640` |
| `serverColorSeed`, `serverColorLabel` | `server_appearance.dart:782,786` |
| `ServerAccentBar`, `ServerBadge` | `server_appearance.dart:803,854` |
| `ServerAppearanceStrings` (string bag with English defaults) | `lib/src/server_appearance_strings.dart:9-82` |
| `showServerColorPicker` | `lib/src/server_color_picker.dart:16` |
| `kCuratedServerEmoji`, `showServerMarkPicker` | `lib/src/server_mark_picker.dart:22,118` |

The fourth app gets identical badges for synced servers for free. Poltergeist's
thin ARB adapter is the pattern to copy:
`poltergeist/app/poltergeist_app/lib/ui/server_mark_picker.dart:1-22` and
`lib/ui/server_appearance_strings.dart` (144 lines).

### 1.4 `ghost_desktop` (planchette/packages/ghost_desktop)

Barrel and charter: `planchette/packages/ghost_desktop/lib/ghost_desktop.dart:1-18`;
`planchette/packages/ghost_desktop/README.md:8-35`.

| Component | Location | Fourth-app use |
|---|---|---|
| `GhostWindowPersistence`, `GhostWindowAdapter`, `GhostWindowListener`, `GhostDisplayAdapter`, `WindowManagerGhostWindowAdapter` | `lib/src/adapters.dart:13,24,76,117,149` | window state |
| `GhostWindowLifecycle` (restore-before-show, debounced capture, close veto) with `GhostClosePolicy`, `MissingMonitorPolicy`, `GhostCoordinateSpace` | `lib/src/lifecycle.dart:32-59,80` | Séance adapter `seance/app/seance_app/lib/services/window_state.dart:21,70-91` (observe / rejectAndKeep / physicalOnWindows); Poltergeist adapter `poltergeist/app/poltergeist_app/lib/services/desktop_window_lifecycle.dart:21,52-68` (intercept / clampToNearest) |
| `GhostWindowSnapshot` | `lib/src/snapshot.dart:16` | |
| `MacosToolbarBandChannel` | `lib/src/macos_toolbar_band.dart:24` | integrated macOS titlebar |
| `semanticsActionView` | `lib/src/semantics_routing.dart:19` | VoiceOver with extra windows |
| `GhostSettingsWindowHost<TTab>`, `GhostSettingsWindowClient<TTab>`, `GhostSettingsSections`, `GhostSettingsPage` | `lib/src/settings_link.dart:62,71,96,336` | desktop Settings window on a second engine (design: `docs/design/settings-window-link.md`) |

### 1.5 `planchette_editor` (planchette/packages/planchette_editor)

Barrel: `planchette/packages/planchette_editor/lib/planchette_editor.dart:1-18`
(re-exports `planchette_core` minus `SearchResult`, `findSearchMatches`,
`searchText`).

- `PlanchetteEditor` widget: `lib/src/editor_view.dart:31`. Controller
  (`EditorController`, 3,547 lines) with host and view edit locks
  (`lib/src/editor_controller.dart:587-611`), so a read-only viewer is
  supported (`setEditingLocked`).
- `EditorStrings` concrete string bag with English defaults:
  `lib/src/editor_strings.dart:6-40`; Poltergeist maps it to ARB in
  `poltergeist/app/poltergeist_app/lib/ui/editor_strings.dart` (948 lines).
- `CodeEditingController` / `EditorSyntaxTheme`:
  `lib/src/code_editing_controller.dart:10,290-303`.
- Limits: the document is one `TextEditingController`; highlighting turns off
  above `syntaxHighlightingMaxChars = 200 * 1000`
  (`planchette/packages/planchette_core/lib/src/editor_syntax.dart:25`;
  `editor_controller.dart:660-665`). Good for compose files, `.env`, crontabs,
  unit files; not suitable for streaming or large logs (section 5).
- Host adapters around it are app-local and diverge: Séance
  `lib/ui/built_in_text_editor.dart` (506) vs Poltergeist (566), 371 of
  Séance's lines not found in Poltergeist's copy.

### 1.6 `planchette_core` (pure Dart)

Barrel: `planchette/packages/planchette_core/lib/planchette_core.dart:1-19`.

| Capability | Location | Fit for server-tool files |
|---|---|---|
| Language detection `syntaxLanguageFor(path, firstLine)` | `lib/src/editor_syntax.dart` (function after `_languageById`, table at 980-1034) | `.yml/.yaml` -> yaml (`:987`), `.env`/`.env.*` -> dotenv (special case in `syntaxLanguageFor`), `Dockerfile`/`Containerfile`/`*.dockerfile` -> dockerfile (`:1009`), `.service/.socket/.timer/.conf/.ini/.toml` -> ini (`:988-990`), basename `crontab` -> shell (`:1020`), `fstab`/`hosts`/`sshd_config` -> ini (`:1017-1020`), `.diff/.patch` -> diff (`:1000`) |
| Languages | `SyntaxLanguages` at `editor_syntax.dart:139`: dotenv, shell, python, javascript, dart, json, yaml, ini, dockerfile (`:417-446`), sql, c-family, rust, go, diff (`:714`), xml, markdown, css, ruby, perl, lua | no log, nginx, systemd-specific, or crontab-specific grammar |
| Tokenizer `tokenizeSyntax(text, language)` | `editor_syntax.dart:1104` | can highlight single log lines (JSON logs) outside the editor |
| Search `searchText`, `findSearchMatches` (case folding, whole word, scope, limit) | `editor_syntax.dart:1593,1715` (part file `pattern_search.dart`) | log search; hidden from the editor barrel, available from `planchette_core` |
| Validation `TextFormat {json, jsonWithComments, dotenv, yaml, toml, xml}`, `textFormatFor`, `validateText` | `lib/src/text_validation.dart:33-55,57-75,78-103` | compose YAML: repeated keys + tab indentation (`:41-45`); `.env`: repeated keys + unclosed quotes (`:38-39`); TOML repeated keys/tables. Explicitly no validation for INI dialects like systemd units and SSH config, which repeat keys by design (`:53-56`) |
| Problems model `TextProblem`, severities/kinds | `lib/src/text_problem.dart:2,14,68` | lint list UI |
| Unified diff `unifiedDiff`, isolate-bounded `boundedUnifiedDiff`, `UnifiedDiffResult/Status` | `lib/src/unified_diff.dart:24,42,63,358` | "review changes before apply" for compose/.env/crontab/unit edits; config drift views |
| Conflict-marker detection | `lib/src/conflict_markers.dart` (part of text_validation) | |
| Guarded local document I/O `TextDocument`, save options | `lib/src/text_document.dart`, `text_save_options.dart` | local exports only; remote edits need a checkout pipeline (Séance `lib/services/managed_remote_file*.dart`, Poltergeist `poltergeist_core/lib/src/checkout/`) |

Note: no YAML parser package is used; validation is a hand-written reader
(`yaml_validation.dart:55-88`). A compose-aware model (services, ports,
volumes) does not exist; the fourth app would need its own parser or a
dependency.

### 1.7 Non-UI shared pieces the server-list UI relies on

| Piece | Location |
|---|---|
| `normalizeServerGroup`, `serverGroupKey`, `existingServerGroups`, `serverSearchHaystack` | `seance/packages/seance_protocol/lib/src/models/server_config.dart:439,507,511,527` |
| `duplicateServerLabel`, `duplicateServerConfig` | `seance/packages/seance_protocol/lib/src/models/server_duplication.dart:13,72` |
| `ServerMark` resolve/stored, icon image codecs | `seance/packages/seance_protocol/lib/src/models/server_mark.dart` (see design doc `docs/design/server-appearance-package.md:62`) |
| `ProbeService` (reachability) | `seance/packages/seance_core/lib/src/probe/probe_service.dart`, exported `seance_core.dart:42` |
| `UpdateChecker`, `hauntwareUpdateRepo = 'L-K-M/Hauntware'` | `seance/packages/seance_core/lib/src/update/update_checker.dart:8,30-48` |
| `SyncEnrollmentIssue` validator (typed, both apps map to copy) | `seance/packages/seance_core/lib/src/sync/sync_enrollment_validation.dart`; PORTS `poltergeist/docs/PORTS.md:1178-1194` |
| `ConnectionTestResult` (dartssh2-free data, but in `seance_core`) | `seance/packages/seance_core/lib/src/ssh/test_connection.dart:120-145` |
| `SshConnectionLog` (redacting transcript, `onUpdate`) | `seance/packages/seance_core/lib/src/ssh/ssh_session.dart:142-160` |
| `HostKeyDecision` (TOFU verdict, presented/pinned) | `seance/packages/seance_core/lib/src/hostkey/tofu.dart:9-21` |
| `SshSession.runCommand` (non-PTY exec, captured, 256 KiB per stream cap, 30 s default timeout) and `RemoteCommandResult`/`RemoteCommandRunner` | `ssh_session.dart:474-491`; `seance/packages/seance_core/lib/src/ssh/remote_command.dart:5-49` |
| Poltergeist re-exports the needed `seance_core` types through its barrel (HostKeyDecision, ProbeStatus, ConnectionTestResult, SyncEnrollmentIssue, SshConnectionLog) | `poltergeist/packages/poltergeist_core/lib/poltergeist_core.dart:11-14,48,63,101,118,123` |

### 1.8 App-local pieces: shared, duplicated, or single-app

Divergence column = Séance lines with no counterpart in Poltergeist's file after
stripping indentation (`diff -w`), as a rough duplication measure.

| Concern | Séance | Poltergeist | Status |
|---|---|---|---|
| Server rail section (sections, groups, pinned, filter threshold, empty state) | `lib/ui/server_list_pane.dart` (1123): `ServerListPosture {rail, home}` `:24-34`, `serverSidebarStrings` `:38-49`, `ServerListPane` `:54`, kit headers `:488,512`, bottom bar `:401`, sync chip `:646-681`, update banner `:989` | `lib/ui/sidebar/sidebar_servers_section.dart` (927, `part of sidebar_view.dart`): `_serversSection` `:24`, `_CatalogServerRow` `:704` | Duplicated in concept, different code; both over the shared kit |
| Sectioning rules (pinned leaves group, ungrouped first, groups sorted) | Flutter-free `lib/ui/server_grouping.dart` (301): `groupServers` `:84`, `serverListRows` `:182`, `sectionsHoldingLive` `:240`, `hiddenByHeader` `:262` | inline `_ServerGroup` + loop in `sidebar_servers_section.dart:10-60`; Poltergeist pruned its port (`poltergeist/docs/PORTS.md:764-785`) | Duplicated rules, divergent code |
| Server row | `lib/ui/server_tile.dart` (336): `ServerTile` `:20`, `SidebarRow(... accent, markRing)` `:113-121` | `_SavedServerRow` `:439`, `_CatalogServerRow` `:704`, `_AdhocRow` `:846` in `sidebar_servers_section.dart` | Duplicated composition |
| Status-dot vocabulary (connected solid green, connecting amber, failed red, blocked no-entry, reachable ring, unknown none) | `lib/ui/server_status_dot.dart:1-120`: `ServerDot` `:29`, `serverDotFor` `:84`, `aggregateSessionStatus` `:108` | `lib/ui/server_state_indicator.dart`: `ServerIndicatorGlyph` `:9`, `serverIndicatorOf` `:51` | Same contract (sibling rule, `poltergeist/docs/plan/10-WORKSPACE-REDESIGN.md:436-442`), two implementations keyed on different status types |
| Server editor | `lib/ui/server_editor.dart` (1297), signature takes `AppState` `:197-211` | `lib/ui/server_editor.dart` (1490) with `ServerEditorDelegate` `:31-87`, `showServerEditor` `:246` | Ported copy; 208/1297 Séance lines differ; shared pure helpers duplicated verbatim: `excludingNeedsConfirmation`, `plannedCredential`, `plannedCredentialReadsStored`, `nextUpdatedAt`, `confirmSyncExclusion` (Séance `:35,70,124,158,167`; Poltergeist `:94,129,183,213,222`) |
| Editor backend | `AppState.testServerConnection` `lib/app_state.dart:621`, `saveServer` `:816` | `lib/services/server_editor_backend.dart` (304) | Different composition (PORTS `:978-997`) |
| TOFU dialog | `lib/ui/host_key_dialog.dart` (106), `showHostKeyDialog(ctx, HostKeyDecision)` `:7-8` | `lib/ui/prompts/host_key_dialog.dart` (126), `showHostKeyDialog(ctx, HostKeyPromptData)` `:15-20` | Ported; 29/106 lines differ (payload type + ARB) (PORTS `:418-464`) |
| Keyboard-interactive dialog | `lib/ui/keyboard_interactive_dialog.dart:6` (143) | `lib/ui/prompts/keyboard_interactive_dialog.dart:12` (161) | Ported; 51/143 differ (PORTS `:466-505`) |
| Missing-credential prompt | `lib/ui/credential_prompt.dart:12` `showMissingCredentialDialog` (179) | `lib/ui/prompts/credential_dialog.dart:33` `showCredentialDialog` (258) | Same job, independently written (111/179 differ) |
| Connection log view | `lib/ui/connection_log_view.dart` (109), `SelectableText` in a 260 px box `:76-101` | `lib/ui/connection_log_view.dart` (109) | Ported, ARB only (PORTS `:999-1006`); 14 lines differ |
| Connection test report | `lib/ui/connection_test_report.dart:14` (66) | same path (71) | Ported, ARB only (PORTS `:1008-1015`) |
| Theme stack (`ThemePalette`, `ThemePresets`, `AppAppearance`, chrome extension, status colours) | `lib/theme/theme_palette.dart` (593, `ThemePalette` `:257`), `theme_presets.dart` (414), `app_appearance.dart` (47), `lib/theme.dart` (768: `SeanceChrome` `:266`, `SeanceTheme.build` `:523`, extensions installed `:657-682`, `SeanceStatusColors` `:708`) | `lib/theme/theme_palette.dart` (449), `theme_presets.dart` (226), `app_appearance.dart` (48), `app_theme.dart` (888, extensions `:863-874`) | Ported (PORTS `:1812-1969`); `app_appearance.dart` differs only in comments; palette differs by the terminal block |
| Appearance settings page | `lib/ui/appearance_settings.dart` (1016) | `lib/ui/settings/appearance_settings.dart` (839) | Ported, ARB, different backend seam (PORTS `:1920-1936`) |
| Splitter / seam | `lib/ui/adaptive_shell.dart:610-734` (`_Seam`, `_ResizeHandle`) | `lib/ui/shell/shell_splitter.dart` (220, `ShellSplitter`) | Same behavior (1 px seam, floating hit area, 16 px arrow steps), two implementations |
| Keystore master key | `lib/services/secure_master_key.dart` (246), entry `seance.vault.masterKey.v1` `:75` | `lib/services/secure_master_key.dart` (162), entry `poltergeist.vault.masterKey.v1` `:45` | Ported with per-app entry names (PORTS `:305-325`); 116/246 differ |
| File stores / vault re-key journal | `lib/services/file_stores.dart` (616) | `lib/services/file_stores.dart` (484) | Partly ported (PORTS `:327-376`) |
| Atomic file | `lib/services/atomic_file.dart` (94) | (47) | Divergent ports (PORTS `:261-280`) |
| Locked/dynamic vault | `LockedSecretVault` `lib/services/app_services.dart:106` | `DynamicSecretVault` `lib/services/dynamic_secret_vault.dart:15` | Different designs |
| App lock (device auth gate) | `lib/services/app_lock.dart` (220), `app_lock_vault.dart` | none | Séance only |
| Secrets recovery (CRED-05) | `lib/services/secrets_recovery.dart`, `lib/ui/recovery_prompt.dart:14`, `recovery_settings.dart` | none | Séance only (`docs/design/cred-05-recovery.md`) |
| Sync enrollment UI | `lib/ui/settings_screen.dart` `_syncTab` `:808`, `SyncEnrollmentFields` `:1481`; backend `AppServices.registerSync/loginSync/runSync` `lib/services/app_services.dart:816,848,904` | `lib/ui/settings/backup_enrollment_form.dart:21-52`, `backup_enrolled_view.dart:18`, `backup_settings.dart:17`; backend `lib/services/bookmark_backup_service.dart` (887) | Different products, different flows |
| Settings window Dart side | `lib/services/settings_window.dart:57,97,244` (`RemoteSettingsBackend extends GhostSettingsWindowClient<SettingsTab>`) + `lib/settings_window_app.dart` (109) | `lib/services/settings_window/` (3 files) + `lib/settings_window_app.dart` (303) | Engine shared in `ghost_desktop`; sections, methods, runners per app (PORTS `:1774-1810`) |
| macOS menus | native Swift menu over `seance/menu` channel, `macMenuChannel` and `installMacMenu` `lib/ui/app_menus.dart:125-175` | Flutter-authored `PlatformMenuBar` from a command registry, `lib/ui/menus/app_menu_host.dart:17-24,97,152` over `ghostPlatformMenus` | Divergent; Poltergeist and Planchette use the shared `ghost_command_menu` |
| macOS titlebar / toolbar band | `lib/services/macos_titlebar.dart:24-67`, `lib/ui/macos_toolbar_band.dart` (131) | `lib/services/workspace_windows/window_titlebar.dart`, `lib/ui/shell/macos_toolbar_band.dart` (104) | Duplicated (57/131 differ) |
| Window state | `lib/services/window_state.dart:21-91` | `lib/services/desktop_window_lifecycle.dart:21-68` | Thin adapters over `ghost_desktop` |
| Update check UI | `_UpdateBanner` `lib/ui/server_list_pane.dart:989`; `AppState.checkForUpdate` `lib/app_state.dart:2319` | `lib/services/update_check_controller.dart:15-40` feeding the Alerts tab (banner retired, PORTS `:1480-1502`) | Checker shared in core; UI differs |
| Alerts center | none | `lib/services/alert_center.dart:10-40`, `lib/ui/inspector/alerts_view.dart` | Poltergeist only; good fit for observability alerts |
| Android foreground service | `lib/services/background_keep_alive.dart:10-60` over `seance/keepalive`; `android/app/src/main/kotlin/ch/lkmc/seance/KeepAliveService.kt` (176); manifest `dataSync` type `android/app/src/main/AndroidManifest.xml:9-11,47-50` | none (only `MainActivity.kt`) | Séance only |
| Adaptive layout | `lib/ui/adaptive_shell.dart:17-45` (3 resizable panes; breakpoint = 200+480+260+2x10 = 960) | `lib/ui/adaptive_shell.dart` (two-pane allocation) + D32 stages (`10-WORKSPACE-REDESIGN.md:138-148`), compact posture `< 600` `lib/ui/compact/compact_posture.dart:5-16` | Different shells |
| Top toasts | 1-line export `lib/ui/top_toast.dart:1` | 1-line export `lib/ui/top_toast.dart` | Shared via ghost_ui |
| Pickers / appearance module | `lib/ui/server_appearance.dart` (18), `server_mark_picker.dart` (4), `server_color_picker.dart` (22), `color_picker.dart` (36) | wrappers 18/22/28/34 lines + `server_appearance_strings.dart` (144) | Shared via ghost_marks/ghost_ui |

---

## 2. How the existing apps are built

### 2.1 Bootstrap and state

- **Séance**: `main()` branches to the Settings window engine on its launch flag
  (`seance/app/seance_app/lib/main.dart:31-38`), installs the macOS titlebar
  (`:41-43`), restores window state (`:47`), runs `SeanceApp`. `_Bootstrap`
  awaits `AppServices.initialize()` then `AppState(services)` (`:141-171`),
  wires host-key and keyboard-interactive prompters to dialogs on the root
  navigator (`:149-158`), installs the macOS menu (`:161`), creates the
  Settings window host (`:162-164`), posts keystore/app-lock/settings-recovery
  toasts (`:165-167,173-270`), and fires the update check (`:169,274-281`).
  One `MaterialApp` for every phase, `AppScope` injected in `builder` so pushed
  routes resolve it (`:283-331`). `AppScope` InheritedWidget: `:55-67`.
- `AppState extends ChangeNotifier` holds everything: servers, probe statuses,
  tabs, sync status, inbox, suggestions, chat, prompters, update info,
  keep-alive (`lib/app_state.dart:479-602`); 3,027 lines total. Mutations
  serialize through `_mutate` (e.g. `saveServer` `:816-822`).
- `AppServices` is the service bag: config/snippet/tombstone stores, vault,
  host-key store, TOFU verifier, probe, master keys, app lock, settings,
  managed remote files, inbox stores, identity audit, local shell
  (`lib/services/app_services.dart:132-221`); `initialize()` runs sandbox
  migration, opens JSON stores in the support directory, probes the keystore
  and settles any pending re-key (`:223-365`).
- Séance's own editor docs note the cost: "no widget test in this app stands up
  an [AppState]" (`lib/ui/server_editor.dart:32-34`).

- **Poltergeist**: `main()` is an explicit composition root
  (`poltergeist/app/poltergeist_app/lib/main.dart:74-795`): settings-window
  branch (`:78-81`), `CheckedPlatformMenuDelegate` on macOS (`:82-85`), error
  reporter, deep links, one `SettingsStore`, bookmark store, server config
  store, vault (`DynamicSecretVault` re-resolving the key per call, `:140-159`),
  preferences, window lifecycle (`:299-306`), engine session
  (`startEngineSession`, `:312-324`), transfer queue, sync environment, backup
  service, server editor backend, update check, appearance controller, then
  `PoltergeistApp`. Each concern is a `ChangeNotifier` controller passed by
  constructor (`lib/app.dart:62`).
- SSH runs in an engine isolate behind `AppEngine` (prompts, probes, connection
  status streams, catalog replacement): `lib/services/engine_session.dart:36-80`.
  Prompts cross the isolate as plain data (`HostKeyPromptData`,
  `poltergeist/packages/poltergeist_core/lib/src/engine/protocol.dart:279`;
  PORTS `:425-428`).
- PORTS records the design choice: "Poltergeist composes services rather than a
  monolithic state" (`poltergeist/docs/PORTS.md:1100-1105`).

Neither app uses provider, riverpod or bloc: neither pubspec lists them
(`seance/app/seance_app/pubspec.yaml:10-78`,
`poltergeist/app/poltergeist_app/pubspec.yaml:10-61`), and no lockfile resolves
them (section 5.1).

### 2.2 Where the server list comes from

- Séance: `FileConfigStore(servers.json)` in `AppServices.initialize`
  (`lib/services/app_services.dart:280`) and `AppState.servers`
  (`lib/app_state.dart:483`), synced by `seance_core`'s `SyncCoordinator`
  (`seance/packages/seance_core/lib/seance_core.dart:52-56`).
- Poltergeist: `FileServerConfigStore(servers.json)`
  (`lib/main.dart:129-133`;
  `poltergeist/packages/poltergeist_core/lib/src/sync/server_store.dart:1-14,105`)
  plus the read-only materialized `SeanceServerCatalog`
  (`poltergeist_core/lib/src/sync/seance_server_catalog.dart:1-50`) rebuilt by
  the bookmark coordinator each pull; the sidebar lists `view.catalog?.servers`
  (`lib/ui/sidebar/sidebar_servers_section.dart:31`). The catalog exists only in
  shared-account mode (`sidebar_servers_section.dart:19-23`).
- Same-account rule: "Both apps enroll in the same Séance sync server with the
  same account and passphrase" (`poltergeist/docs/plan/10-WORKSPACE-REDESIGN.md:454-458`).
  Any app on the account can decrypt every synced record, including `secret`
  records (`seance/docs/POLTERGEIST.md:446-455`); this applies equally to a
  fourth app and belongs in its setup copy.

### 2.3 Settings

- Séance: `SettingsTab {general, appearance, assistant, files, sync, inbox}`
  and `SettingsBackend` interface (`lib/services/settings_backend.dart:16,34`);
  `LocalSettingsBackend` holds logic, `RemoteSettingsBackend` forwards over the
  link (`seance/AGENTS.md` section 7, "SettingsBackend"); one
  `SettingsScreen` with `SettingsPresentation` (`lib/ui/settings_screen.dart:27,42`);
  layout helpers `SettingsPage`, `SettingsSectionHeader`
  (`lib/ui/settings_layout.dart:7,36`). Desktop opens a window, mobile a route
  (`lib/ui/app_menus.dart:20-60`).
- Poltergeist: `SettingsWindowTab {general, appearance, editing, sync}` and
  typed `SettingsLinkMethod` enum (`lib/services/settings_window/settings_window_link.dart:36,47`),
  per-section models (`lib/services/settings_models.dart`), a dedicated window
  app (`lib/settings_window_app.dart`, 303 lines). D36 makes the window binding
  for both apps (`poltergeist/docs/plan/00-OVERVIEW.md:835-860`).
- Shared engine: `GhostSettingsWindowHost/Client` (section 1.4). Native runners
  (`macos/Runner/SettingsWindow.swift`, `linux/runner/settings_window.cc`,
  `windows/runner/settings_window.cpp`) are near-identical copies differing in
  channel names and titles (`docs/design/settings-window-link.md:66`), still
  per app.

### 2.4 Localization

- Poltergeist: `l10n.yaml` (`arb-dir: lib/l10n`, template `app_en.arb`,
  class `AppLocalizations`), `flutter: generate: true`
  (`poltergeist/app/poltergeist_app/pubspec.yaml:87-88`), delegates in
  `lib/app.dart:468-483`. `app_en.arb` is 10,073 lines, about 1,870 message
  keys. D20: "All user-facing strings in ARB via gen-l10n (English only at v1)"
  plus hand-built semantics and contrast-checked status colours
  (`poltergeist/docs/plan/00-OVERVIEW.md:1101-1106`).
- Contract test: `test/localization_contract_test.dart` (2,803 lines) parses
  `lib/` with `package:analyzer` and rejects authored user-facing literals,
  with per-file reviewed allowlists (`:1-40`; tests `:2571-2727`). Companion
  `test/architecture_contract_test.dart` pins composition invariants
  (`:1-50`).
- Séance and Planchette: no `flutter_localizations`, no ARB
  (`seance/app/seance_app/pubspec.yaml:10-78`;
  `planchette/app/planchette_app/pubspec.yaml:9-22`).
- Shared packages bridge both with string bags: `SidebarKitStrings`,
  `ServerAppearanceStrings`, `ColorPickerStrings`, `GhostFileColumnStrings`,
  `EditorStrings` (sections 1.2-1.5).

### 2.5 Theming and appearance

- Per-app `ThemePalette` (accent, nullable Automatic slots, status colours,
  font family, corner scale) stored as one JSON object in `settings.json`
  (`seance/AGENTS.md` section 7, "ThemePalette"; Séance
  `lib/theme/theme_palette.dart:257-361`), `ThemePresets` (Séance
  `lib/theme/theme_presets.dart:24`, Poltergeist `:33`), `AppAppearance`
  value the `MaterialApp` rebuilds on (`lib/theme/app_appearance.dart:11-47`,
  rebuild at `lib/main.dart:312-330`).
- Theme build installs, in both apps, the app chrome extension, status colours,
  `FamilyPalette`, `SidebarThemeTokens` and `GhostFileTheme`, then
  `GhostMenuTheme.apply` (Séance `lib/theme.dart:657-688`; Poltergeist
  `lib/theme/app_theme.dart:863-874`). Chrome field names are identical on
  purpose (`ghost_ui/lib/src/sidebar_theme_tokens.dart:24-27`).
- Sibling contract: same tokens, one brand accent per app (Poltergeist teal,
  Séance violet), twelve family hues byte-identical
  (`10-WORKSPACE-REDESIGN.md:443-453`). A fourth app needs its own accent and
  preset and should paste themes from the siblings (same JSON keys,
  PORTS `:1839-1855`).

### 2.6 Layout

- Séance `AdaptiveShell`: at or above 960 px the server list, terminal and
  utility panel are tiled resizable panes; below it, screens with the utility
  panel in an end drawer (`lib/ui/adaptive_shell.dart:17-45`). The server list
  takes `ServerListPosture.rail` or `.home` (`lib/ui/server_list_pane.dart:24-34`).
- Poltergeist D32: sidebar | pane A | pane B | inspector, default widths and
  persisted keys (`10-WORKSPACE-REDESIGN.md:69-136`), responsive stages
  (`:138-148`), compact posture under 600 dp on touch platforms
  (`lib/ui/compact/compact_posture.dart:5-16`), Android navigation model "the
  list is home, a pushed detail screen follows" (`10-WORKSPACE-REDESIGN.md:470-471`).
- The Séance three-pane shape (server list | main view | utility/inspector)
  maps directly onto a server-management app (server rail | dashboard or
  Docker view | detail inspector). Poltergeist's inspector tabs with badge
  counts (`lib/ui/inspector/inspector_view.dart:17-30`) are a fit for
  Alerts/Details.

### 2.7 Other shell services

- macOS menu: prefer the Poltergeist/Planchette `ghost_command_menu` registry
  (`PlatformMenuBar` on macOS, Flutter `MenuBar` or a header menu elsewhere,
  `poltergeist/app/poltergeist_app/lib/ui/menus/app_menu_host.dart:17-24`)
  over Séance's hand-written native menu channel
  (`seance/app/seance_app/lib/ui/app_menus.dart:122-175`). The sibling contract
  fixes the conventions: Settings in the app menu, standard Edit, Help, and the
  "Use Compact/Comfortable Sidebar Rows" View item
  (`10-WORKSPACE-REDESIGN.md:465-469`).
- Update check: `UpdateChecker` against the shared Hauntware release
  (`update_checker.dart:7-8`), link-only, best-effort (Poltergeist
  `update_check_controller.dart:1-40`).
- Android keep-alive: Séance's foreground service anchors the process while
  sessions connect (`lib/services/background_keep_alive.dart:22-60`); declared
  `foregroundServiceType="dataSync"` (`AndroidManifest.xml:47-50`).

---

## 3. Recommended app-shell skeleton for the fourth app

Base it on Poltergeist's composition style and Séance's three-pane layout.

### 3.1 Directory layout

```
<app>/                               new product subtree (mirrors seance/, poltergeist/)
  AGENTS.md  CLAUDE.md  README.md  CHANGELOG.md  LICENSE
  pubspec.yaml                       pure-Dart workspace: packages/<app>_core (AGENTS.md:15-16)
  analysis_options.yaml  dart_test.yaml
  docs/plan/  docs/STATUS.md  docs/SHARED.md   ledger of shared-package adoption (PORTS.md precedent)
  scripts/  build.sh  release.sh (forwards to root, AGENTS.md:59-60)  package-linux.sh
  media-sources/icon.png
  packages/
    <app>_core/                      pure Dart, no Flutter (import-guard rule)
      lib/<app>_core.dart            curated barrel re-exporting needed seance_core types
                                     (poltergeist_core.dart:11-14 precedent)
      lib/src/hosts/                 command builders + parsers (/proc, df, free, ps, systemctl,
                                     journalctl, crontab), sample models, ring buffers
      lib/src/docker/                Docker over SSH (CLI JSON or Engine API via socket),
                                     containers/images/volumes/networks/compose models
      lib/src/metrics/               samplers, rate computation, retention
      lib/src/alerts/                rule evaluation (pure)
  app/<app>_app/
    pubspec.yaml                     ghost_ui, ghost_marks, ghost_desktop, planchette_editor,
                                     (ghost_servers, ghost_theme, ghost_charts once extracted),
                                     <app>_core, flutter_localizations, intl, window_manager,
                                     macos_window_utils, flutter_secure_storage, path_provider,
                                     package_info_plus, url_launcher
    l10n.yaml  lib/l10n/app_en.arb
    lib/
      main.dart                      composition root (settings-window branch, titlebar,
                                     stores, vault, sync, connection layer, runApp)
      app.dart                       MaterialApp: ARB delegates, appearance-driven theme,
                                     AppMenuHost, navigator key for prompts
      settings_window_app.dart       second-engine Settings window (GhostSettingsWindowClient)
      services/
        settings_store.dart  app_preferences.dart  atomic_file.dart
        secure_master_key.dart       keystore entry '<app>.vault.masterKey.v1'
        file_stores.dart  dynamic_secret_vault.dart
        server_catalog.dart          servers.json + sync coordinator (shared-account list)
        sync_credentials.dart  sync_enrollment.dart
        connection_manager.dart      SSH sessions, TOFU/keyboard-interactive prompt seams;
                                     plain-data streams so it can move to an isolate
        probe_controller.dart        ProbeService wrapper (reachability dots)
        host_metrics_controller.dart docker_controller.dart logs_controller.dart
        cron_controller.dart services_controller.dart processes_controller.dart
        alert_center.dart            Poltergeist's sealed-alert pattern
        update_check_controller.dart background_keep_alive.dart
        settings_window/  settings_window_host.dart  remote_settings.dart  settings_window_link.dart
        desktop_window_lifecycle.dart
      theme/                         brand preset + chrome adapter (thin if ghost_theme exists)
      ui/
        shell/       adaptive shell, header toolbar, macOS toolbar band, splitter use
        sidebar/     server rail (ghost_servers + SidebarKitScope), bottom bar, sync chip
        server/      overview dashboard, metric cards, sparklines
        docker/      containers, images, volumes, networks, stacks; container detail tabs
        logs/        virtualized log viewer
        system/      processes, services, cron, disks, network
        editors/     compose/.env/crontab/unit editing over PlanchetteEditor + diff review
        prompts/     ARB adapters over shared TOFU/credential/keyboard-interactive dialogs
        inspector/   alerts, details
        settings/    general, appearance, sync, docker, alerts
        compact/     phone posture (< 600 dp): list home, pushed detail
    test/
      localization_contract_test.dart  architecture_contract_test.dart
      platform_identity_test.dart      toolchain_contract_test.dart
      services/  ui/  theme/
    android/ ios/ linux/ macos/ windows/   committed platform folders
```

### 3.2 State management

- Composition root in `main.dart`, one `ChangeNotifier` controller per concern,
  passed by constructor; widgets use `ListenableBuilder`/`ValueListenableBuilder`
  as both apps do. Do not reproduce Séance's monolithic `AppState`
  (section 2.1).
- Define narrow seams per UI surface (the `ServerEditorDelegate` shape,
  `poltergeist/app/poltergeist_app/lib/ui/server_editor.dart:28-87`) so widget
  tests need no full app.
- Keep rebuild scope tight: Séance rebuilds `MaterialApp` only on appearance
  changes (`seance/app/seance_app/lib/main.dart:308-314`) and routes chatty
  connection-log updates through a separate notifier
  (`seance/app/seance_app/lib/app_state.dart:75-86`). Metrics polling across
  many servers makes this more important: per-server notifiers or
  `ValueListenable`s per metric series, never one global notify per sample.
- Transport: start with the plain-data stream contract Poltergeist's
  `AppEngine` uses (`lib/services/engine_session.dart:36-80`) even if the first
  version runs on the main isolate; parsing `ps`/`docker` JSON for many hosts
  is a candidate for an isolate later.

### 3.3 Identity, keystore, channels

Follow the siblings' scheme (`poltergeist/AGENTS.md:161-172`;
`planchette/AGENTS.md:89-95`): ASCII product name, Android id `ch.lkmc.<app>`,
Apple bundle id `ch.lkmc.<app>App`, Linux binary `<app>`, GApplication id
`ch.lkmc.<app>`, `StartupWMClass` `Ch.lkmc.<app>`. Own keystore entry
`<app>.vault.masterKey.v1` (precedent: `seance.vault.masterKey.v1`,
`poltergeist.vault.masterKey.v1`, PORTS `:309-311`). Channels named per product:
`<app>/settings_window`, `<app>/settings_link`, `<app>/window`,
`<app>/menu_checks`, `<app>/keepalive`.

### 3.4 Localization

ARB from day one (D20), with Poltergeist's contract test approach. Consider
moving the analyzer scanner of `poltergeist/app/poltergeist_app/test/localization_contract_test.dart`
into a shared dev tool so two apps do not carry 2,800-line copies; the
allowlists stay per app. Map every shared string bag to ARB in a single
`ui/*_strings.dart` adapter per package (Poltergeist precedent
`lib/ui/server_appearance_strings.dart`, `lib/ui/editor_strings.dart`).

### 3.5 Settings

`GhostSettingsWindowHost<SettingsTab>` with an app tab enum (for example
general, appearance, sync, docker, alerts) and typed `SettingsLinkMethod`
enum (Poltergeist's style, `settings_window_link.dart:43-76`, a typo is a
compile error). Section UIs take the same models in the window and in the
mobile dialog/route (D36, `00-OVERVIEW.md:850-852`). Copy and rename the three
native runners (no shared native package exists yet).

### 3.6 Theming

Either port the palette/presets/appearance/theme stack a third time (Poltergeist's
port of it is ~2,000 lines plus tests, PORTS `:1812-1969`) or extract
`ghost_theme` first (section 4). Install the same extension set as both apps
(`seance/app/seance_app/lib/theme.dart:657-688`) so every shared widget works.

### 3.7 Suite integration (non-UI, but required for an app to exist)

- Root release tooling enumerates apps explicitly:
  `tool/release_version/lib/release_version.dart:134-147`; release asset
  manifest `scripts/release-manifest.txt:22-38` (and "13 clients",
  `AGENTS.md:60`); `scripts/test.sh:138-166` iterates product apps;
  CI app jobs `.github/workflows/ci.yml:885-978`.
- Poltergeist's import guard scans only `poltergeist/packages` and
  `poltergeist/app` (`poltergeist/tool/import_guard/README.md:11-14`); the
  fourth app needs its own guard run or a generalized root guard.
- `poltergeist/docs/PORTS.md` style ledger for anything copied rather than
  shared.

---

## 4. Extraction plan for shared server-list, editor, prompt and sync UI

The fourth app makes three consumers of the server list. The repo's own rule is
to "reuse genuinely shared logic" and avoid speculative layers (root
`AGENTS.md`, Code design). The recommendations below are limited to what the
fourth app needs on day one.

### 4.1 Inventory and target

| Piece | Today | Target | Notes |
|---|---|---|---|
| Sidebar kit (rows, headers, filter, bottom bar, density) | shared `ghost_ui` | keep | done |
| Badges, accents, mark/colour pickers | shared `ghost_marks` | keep | done |
| Group/search/duplicate helpers | shared `seance_protocol` | keep | done |
| Sectioning rules (pinned, ungrouped first, groups, hidden-live headers) | Séance `ui/server_grouping.dart` (Flutter-free), Poltergeist inline | `seance_protocol` (pure) or `ghost_servers` | Séance's file is already Flutter-free (`server_grouping.dart:1-11`); Poltergeist's section mixes bookmarks and sessions, so its adoption is optional |
| Status-dot vocabulary | Séance `ServerDot`, Poltergeist `ServerIndicatorGlyph` | `ghost_servers`: an enum of dot states mapped to `SidebarStatusDot` with host-supplied colours and words | Each app keeps its own mapping from its status type (`TerminalStatus`/`ProbeStatus` vs engine `ServerStatus`) |
| Server rail section widget | duplicated compositions | `ghost_servers`: optional `ServerRailSection` taking servers, pinned set, collapsed keys, dot resolver, row verbs, strings | Poltergeist may keep its richer FAVORITES/DEVICES rail and use only the row builder |
| Server editor | ported copy, Séance takes `AppState` | `ghost_servers`: form + `ServerEditorDelegate` + `ServerEditorStrings` + extension slot for app-only fields | Poltergeist's delegate (`server_editor.dart:31-87`) is the seam; the five pure helpers move with it |
| Connection test report, connection log view | ported copies | `ghost_servers` (or `ghost_prompts`) | Needs `ConnectionTestResult`, `SshConnectionLog` data |
| TOFU dialog, keyboard-interactive dialog, missing-credential dialog | ported/independent copies | `ghost_prompts` (or inside `ghost_servers`) | Neutral view-model: endpoint, fingerprint, pinned fingerprint, verdict |
| Theme palette, presets, appearance, chrome tables, status colours, appearance settings | ported copies | `ghost_theme` | Brand preset and app-only slots (Séance terminal block) as parameters |
| Splitter/seam, pane allocation | two implementations | `ghost_ui` addition (`GhostSplitter`) | Small, low risk |
| Keystore manager, file stores, atomic file | divergent ports | leave app-side for now, or move pure parts to `seance_core` | Behavior already diverged deliberately (PORTS `:261-376`) |
| Sync enrollment UI | different products | leave app-side; share only `SyncEnrollmentIssue` (done) and the sidebar sync chip mapping | Flows, copy and backends differ (Séance `settings_screen.dart:808,1416-1458`; Poltergeist `backup_*`) |
| Recovery code (CRED-05), app lock | Séance only | leave app-side; revisit if the fourth app stores secrets | Approved design is Séance-scoped (`docs/design/cred-05-recovery.md:1-10`) |
| Android keep-alive | Séance only | copy with ledger, or a small shared plugin package | Native Kotlin service (176 lines) |

### 4.2 Proposed packages

1. **`ghost_servers`** at `planchette/packages/ghost_servers` (Flutter).
   Dependencies: `flutter`, `ghost_ui`, `ghost_marks`, `seance_protocol`
   (relative path, as `ghost_marks/pubspec.yaml:23-27`). Never `seance_core`.
   Contents: dot vocabulary, sectioning (if not moved to protocol), rail
   section and row builders, server editor with delegate and strings, connection
   test report and log view.
2. **`ghost_prompts`** (optional split): TOFU, keyboard-interactive and
   credential dialogs with string bags. Folding them into `ghost_servers` is
   acceptable; they are always used with a server.
3. **`ghost_theme`**: `ThemePalette`/`ThemePresets`/`AppAppearance`, neutral
   tables, chrome extension with the shared field names, status colours,
   `buildTheme(palette, brandPreset, ...)`, appearance settings page with a
   strings bag and a backend seam.
4. **New for the fourth app**: `ghost_charts` (section 5.1) and a log viewer
   (`ghost_logs`, section 5.3). Put them in shared packages from the start only
   if a second app is expected to use them (Séance could show host vitals);
   otherwise start them in the app and extract later.

### 4.3 Prerequisite type moves

The editor and prompts need `ConnectionTestResult`
(`seance_core/lib/src/ssh/test_connection.dart:120`), `SshConnectionLog`
(`ssh_session.dart:142`) and `HostKeyDecision` (`hostkey/tofu.dart:9`). They are
dartssh2-free data, but live in `seance_core`. Options: move them (or neutral
view-models of them) into `seance_protocol`, or define neutral types in
`ghost_servers`/`ghost_prompts` with per-app adapters. Moving changes
Poltergeist's barrel re-exports (`poltergeist_core.dart:48,101,123`) and its
pin audit (`poltergeist/docs/PORTS.md:1970-1993`).

### 4.4 Suggested PR sequence

1. `ghost_ui`: shared splitter; no behavior change in either app (both keep
   16 px steps, 1 px seam).
2. `seance_protocol`: neutral connection-test/host-key data (or the
   `ghost_prompts` view-models); update Poltergeist barrel and audit.
3. `ghost_prompts`: move TOFU and keyboard-interactive dialogs with their tests
   (Séance tests plus Poltergeist ARB and non-dismissible coverage, PORTS
   `:446-505`); both apps become ARB/English adapters.
4. `ghost_servers` part 1: dot vocabulary + connection log/test report.
5. `ghost_servers` part 2: server editor and delegate. Séance gains a delegate
   implementation over `AppState` (`server_editor.dart` uses `state.servers`,
   `testServerConnection`, `saveServer`, `services.vault.getSecret`,
   `services.isSyncConfigured`, `services.identityBookmarks.pick`,
   `services.settings.identityFileBookmarks`). Extension slots for Séance's
   identity bookmarks and Poltergeist's transfer cap and start folder.
6. `ghost_theme` (can run in parallel with 3-5).
7. Fourth app consumes the packages from its first commit.

### 4.5 Risks

- **Sync data loss through the editor.** A save must carry fields a given app
  does not show: Poltergeist hit this with `jumpHostId` and `startDirectory`
  (`poltergeist/docs/PORTS.md:1108-1120`). Keep `_formConfig` copying from the
  existing config, monotonic `updatedAt` (`nextUpdatedAt`, Poltergeist
  `server_editor.dart:192-214`), exclusion confirmation, and the vault-first save
  order. A shared editor raises the blast radius of a bug to three apps.
- **Credential single-slot gap** documented in `plannedCredential`
  (`poltergeist/app/poltergeist_app/lib/ui/server_editor.dart:112-119`, STATUS
  follow-up 17) moves with the code and must stay pinned by its fuzz test.
- **Localization contract.** Moving files out of `lib/` makes Poltergeist's
  allowlist entries dead; the test asserts every exception stays live
  (`localization_contract_test.dart:2657`), so those entries must go in the same
  PR (`docs/design/server-appearance-package.md:124`).
- **Copy drift.** Séance English vs Poltergeist ARB wording differs in places
  (the incompressible-image precedent,
  `docs/design/server-appearance-package.md:39`); each move needs an owner
  decision on canonical wording.
- **Pixel baselines.** Séance `test/server_list_capture_test.dart` (real-font PNG
  baselines) and Poltergeist's frozen whole-`ThemeData` comparison
  (`poltergeist/docs/PORTS.md:1950-1955,1966`) must pass unchanged after moves,
  especially for `ghost_theme`.
- **Dependency boundary.** A shared UI package that imports `seance_core`
  would bring dartssh2 into Poltergeist's import surface; the guard and the
  design doc forbid it (section 1.1).
- **Divergent status types.** Forcing one status enum across apps would leak
  Séance session or Poltergeist engine types into the shared layer; keep the
  mapping app-side.
- **Native runner duplication** (Settings window, keep-alive, titlebar, menus)
  stays per app; a fourth copy increases sync burden. A shared native plugin is
  possible but not proposed here.
- **Scope creep.** Extracting sync enrollment or keystore code now would touch
  security-critical, deliberately divergent paths (PORTS `:305-376`) for little
  fourth-app benefit.

### 4.6 What stays app-specific

Shell layout and header; the app's main panes (terminal, file panes, dashboards,
Docker views); app tab enums and settings sections; ARB catalogs; status
resolution from each app's connection model; sync/backup services and their
setup UI; recovery and app lock (Séance); keystore entry names and support-dir
file names; native runners and channel names; Android keep-alive service;
deep links; menus' command registries.

---

## 5. Gaps

### 5.1 Charts and sparklines

- None exist. Across the 13 `pubspec.lock` files no chart package resolves
  (resolved set checked: no `fl_chart`, `graphic`, `syncfusion_*`,
  `community_charts_*`). The only `CustomPainter`s in first-party code are
  `_CheckerPainter` (`ghost_ui/lib/src/color_picker.dart:347`) and
  `_EmojiBadgePainter` (`ghost_marks/lib/src/server_appearance.dart:998`).
- Dependency hygiene in the repo: Poltergeist pins exact versions with a
  rationale comment per dependency (`poltergeist/app/poltergeist_app/pubspec.yaml:11-61`);
  `ghost_ui` keeps two deps (`ghost_ui/pubspec.yaml:14-20`); patched upstream
  deps are vendored with PATCHES.md (`poltergeist/app/poltergeist_app/pubspec.yaml:63-68`).
  The license gate permits Unlicense, MIT, Apache-2.0, BSD-2/3-Clause, ISC
  (`poltergeist/tool/license_gate/lib/license_gate.dart:17-24`) but scans only
  the Séance component trees reached by local path dependencies
  (`license_gate.dart:128-190,244-247`); hosted pub packages are governed by
  convention, not by this gate.
- Options checked on pub.dev on 2026-10-10:
  - `fl_chart` 1.2.0, published 2026-03-13, MIT, deps `equatable`,
    `vector_math`, Flutter >= 3.27.4.
  - `graphic` 2.7.0, published 2026-02-25, MIT, deps `collection`,
    `vector_math`, `path_drawing`.
  - `syncfusion_flutter_charts` 35.1.39, published 2026-10-07, pub.dev license
    tag "unknown" (vendor licence); outside the permitted list, exclude.
  - `community_charts_flutter` 1.0.4, last published 2024-05-15; stale.
- Recommendation: an in-house `ghost_charts` (zero deps beyond Flutter) with a
  `Sparkline` (fixed-capacity ring buffer, min/max, threshold band), `Gauge`
  (percent with severity colours), `TimeSeriesChart` (1-4 series, shared time
  axis, crosshair, tooltip), `StackedBar` (memory: used/cache/free; disk), all
  `RepaintBoundary` + `CustomPainter` with `shouldRepaint` on a version counter,
  colours from `ColorScheme`/`FamilyPalette`, contrast checked with
  `contrastRatio`, and semantics labels summarizing the series (D20). This fits
  the `ghost_ui` charter and the repo's habit of small hand-built widgets.
  Revisit `fl_chart` if zoomable multi-series history becomes a requirement.

### 5.2 Tables and virtualized lists

- No generic table exists. `GhostFileColumnHeader` is tied to
  `GhostFileColumn {name, size, modified}` (`ghost_file_columns.dart:183,226-260`).
  Poltergeist's sync plan table is a `ListView.builder` with its own header
  (`poltergeist/app/poltergeist_app/lib/ui/sync/sync_plan_table.dart:1-30,199`);
  the file pane uses `ListView.builder` with `itemExtent`
  (`lib/ui/panes/pane_view.dart:2037-2047`).
- Needed for containers, images, volumes, processes, services, cron entries:
  sortable column header generalized over a host column enum, fixed-extent
  virtualized rows, keyboard selection, context menus (reuse
  `SidebarMenuEntry`/`GhostMenuItem`), row semantics (D20 asks for announced
  columns, `00-OVERVIEW.md:1102-1104`).
- Options: generalize `ghost_file_columns` into a `GhostColumnHeader<T>` in
  `ghost_ui`, or adopt `two_dimensional_scrollables` 0.5.5 (flutter.dev,
  BSD-3-Clause, published 2026-09-25, Flutter >= 3.41.0) `TableView` for
  wide tables with horizontal scrolling.

### 5.3 Log viewing

- The editor is unsuitable for live or large logs: single
  `TextEditingController` buffer and no highlighting above 200,000 chars
  (section 1.5). `ConnectionLogView` is a `SelectableText` in a 260 px box
  (`seance/app/seance_app/lib/ui/connection_log_view.dart:76-101`).
- Transport gap: `SshSession.runCommand` captures bounded output and returns at
  exit (256 KiB per stream, 30 s default timeout, `ssh_session.dart:474-491`);
  there is no streaming exec API for `docker logs -f` or `journalctl -f`. That
  needs a new `seance_core` (or `<app>_core`) API returning a stream with
  cancellation.
- Viewer needs: line ring buffer with cap, `ListView.builder` with fixed line
  extent, follow-tail toggle, regex/plain search reusing `planchette_core`
  `searchText`/`findSearchMatches` (`editor_syntax.dart:1593,1715`), level
  colouring, optional per-line JSON highlighting via `tokenizeSyntax`
  (`:1104`), ANSI SGR colour parsing (none outside vendored xterm), timestamps
  and multi-container merge, copy/export through the existing
  file export services. Redaction is the producer's job by repo convention
  (`connection_log_view.dart:15-20`).

### 5.4 Other gaps

- **Interactive shells** (`docker exec -it`, host shell): the terminal stack is
  Séance-only (vendored `seance/third_party/xterm`, `flutter_pty`,
  `seance/app/seance_app/pubspec.yaml:28-42`) and the `TerminalEngine` seam is
  in `seance_core`. A fourth app either path-depends on the vendored xterm or
  hands off to Séance through a deep link (Poltergeist's `seance://connect`
  precedent, `poltergeist/docs/PORTS.md:58-73`).
- **Byte units:** `ghostFormatFileSize` uses decimal units on macOS/Linux
  (`ghost_file_format.dart:21-25`); `free`, `df -h`, `docker stats` use binary
  units. Add an IEC formatter for server figures, and a rate formatter
  (Poltergeist `lib/ui/activity/activity_format.dart:20` and
  `lib/services/transfer_rate_tracker.dart:1-20` are app-local).
- **Crontab and systemd semantics:** crontab highlights as shell
  (`editor_syntax.dart:1020`) with no schedule parser or validation; unit files
  highlight as INI and are deliberately not validated
  (`text_validation.dart:53-56`). Compose files get only generic YAML checks;
  no compose schema model exists.
- **Remote file edit with conflict detection** exists in two shapes (Séance app
  `managed_remote_file*.dart`, Poltergeist core `src/checkout/`), neither
  shared as UI. Editing a remote compose file needs one of them.
- **Notifications:** no local-notification plugin resolves in any lockfile;
  alerting while backgrounded would need one plus platform permissions.
- **Background work on Android:** only Séance has a foreground service, typed
  `dataSync` (`AndroidManifest.xml:47-50`). Android 15 limits `dataSync`
  foreground services to about six hours per 24 h (platform behavior, not
  verified in this repo); a monitoring app should not rely on it for
  continuous polling.
- **Alerts:** Poltergeist's sealed `AppAlert` + `AlertSeverity` center
  (`lib/services/alert_center.dart:10-40`) and Alerts inspector tab are
  app-local; copy the pattern rather than the code.
- **Command palette:** Planchette `lib/widgets/command_palette.dart` (401) and
  Poltergeist `lib/ui/quick_open/quick_open_palette.dart` (760) are separate;
  a "jump to server/container" palette would be a third.
- **Contract tests:** platform identity and toolchain contract tests exist only
  in Poltergeist (`test/platform_identity_test.dart`,
  `test/toolchain_contract_test.dart`); copy them.

---

## 6. Verification notes

- Verified by reading code at the cited lines; duplication counts come from
  `diff -w` with indentation stripped and are approximate.
- pub.dev facts (versions, dates, license tags) were fetched from the pub.dev
  API on 2026-10-10.
- Not verified: Android 15 foreground-service limits (stated from platform
  knowledge); runtime behavior of any widget (no Flutter SDK was run).
