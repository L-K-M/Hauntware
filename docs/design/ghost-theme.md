# Shared package design: `ghost_theme` (F4b)

Scope: both shipped apps' theme stacks: the editable `ThemePalette` and its
stored/pasted JSON form, the preset tables, the theme builders and the chrome
and status `ThemeExtension`s, and the Appearance settings UI, all extracted into
`planchette/packages/ghost_theme`, Séance switched in the same PR series,
Poltergeist as a planned follow-up, Klabautermann consuming it for light/dark
themes, the shared extensions and the theme editor. This is the D3 "move,
switch, prove" design doc for 03 §3.5 row F4b (`03-ARCHITECTURE.md:978`), D9
(`:328-340`), §10.9 (`:3194-3199`) and 04 §13 "F4b" (`04-IMPLEMENTATION.md:174-188`).
Read-only design; no code changed.

Status: proposed for the Klabautermann foundations (F4b);
approval under the owner's instruction of 2026-10-13 to implement the plan.

Prepared against main at `20acafc7` (`git rev-parse --short HEAD` in this
worktree). All `path:line` references are at that commit.

## 1. Inventory

### 1.1 Production files

| Piece | Séance file (lines) | Poltergeist file (lines) | Verdict |
|---|---|---|---|
| Palette model + hex codec | `seance/app/seance_app/lib/theme/theme_palette.dart` (593) | `poltergeist/app/poltergeist_app/lib/theme/theme_palette.dart` (449) | Same model, same JSON; Poltergeist drops the terminal block (see §1.3) |
| Presets | `.../lib/theme/theme_presets.dart` (414) | `.../lib/theme/theme_presets.dart` (226) | Same nine shared presets; first preset and `initial` differ per app |
| Appearance value + brightness | `.../lib/theme/app_appearance.dart` (47) | `.../lib/theme/app_appearance.dart` (48) | Identical except Poltergeist's provenance header and em-dash rewording (verified by diff) |
| Contrast shim | `.../lib/theme/contrast.dart` (2) | `.../lib/theme/contrast.dart` (2) | Byte-identical re-exports of `ghost_ui` (`contrastRatio`, `compositeOver`, `legibleOn`) |
| Family hues shim | `seance/app/seance_app/lib/family_hues.dart` (2) | `.../lib/theme/family_hues.dart` (2) | Byte-identical re-exports of `ghost_ui`; different path only |
| Theme builder + chrome + status colors | `seance/app/seance_app/lib/theme.dart` (768) | `.../lib/theme/app_theme.dart` (895) | Same structure and mostly shared values; divergences enumerated in §1.3 |
| Diff colors | (none) | `.../lib/theme/compare_diff_colors.dart` (171) | Poltergeist only; stays app-side |
| Appearance settings UI | `.../lib/ui/appearance_settings.dart` (1016) | `.../lib/ui/settings/appearance_settings.dart` (839) | Ported; literals vs ARB, terminal section, font picker, backend seam |
| Color picker wrapper | `.../lib/ui/color_picker.dart` (36) | `.../lib/ui/color_picker.dart` (34) | Both already thin wrappers over `ghost_ui`'s `showColorPicker` |
| Installed-font picker | `.../lib/ui/font_picker.dart` (298) + `.../lib/services/system_fonts.dart` (549) | (none) | Séance only (Poltergeist uses a plain text field) |
| Terminal theme bridge | `.../lib/ui/terminal_appearance.dart` (212) | (none) | Séance only; maps `ThemeTerminalColors` to the vendored xterm's `TerminalTheme` |

**Séance `lib/theme.dart` section map** (768): imports 1-13 (`ghost_ui`
`SidebarThemeTokens`, `GhostFileTheme` `:5`; `planchette_editor` `GhostMenuTheme`
`:6-7`; `family_hues.dart` shim `:9`); `_Neutrals` class 21-63; `_dark`/`_light`
tables 65-108; `_isDesktop` 109-112; `_white`/`_black` and mix constants
114-136; `_mix` 138; `_drawnAt` 142-147; `_neutralsFor` 156-224 (Automatic
container ladder, seed-tuned accent path `:175-178`); `_selectionFor` 230-237
(darken accent until white text clears `_textContrast` 4.5, `:136`);
`_statusFor` 242-260; `SeanceChrome` 266-393 (15 color fields + 3 extents +
`cornerScale`, `of` 310-316); `_chromeFor` 395-422 (`onSelection` over the
rail at `:411-413`, header/row extents `:414-417`); `_desktopText` 424-444;
radius constants 446-453 (`_dialogRadius` 28); `SeanceTheme` 455-705 (`seed`
`0xFF6B5BD2` `:459`, `light`/`dark` 465-468, `forAppearance` 475-495,
`resolvedSlots` 497-521, `build` 523-688: scheme assembly 530-560, component
themes 583-655, extensions 656-679, `GhostMenuTheme.apply` 688); `monoFallback`
691-698; `SeanceStatusColors` 708-753; `StatusColors` statics 755-768.

**Séance `theme/theme_palette.dart` map** (593): `ThemeSlot` enum 17-48 (11
slots; `allowsAlpha` = `hairline`, `selection` at `:47`); `parseThemeColor`
57-72 (`#RGB`/`#RGBA`/`#RRGGBB`/`#RRGGBBAA`, `#`/`0x` prefixes, alpha-last);
`formatThemeColor` 78-86; `ThemeTerminalColors` 99-237 (`ansiCount` 16 `:141`,
`yellowIndex` 3 `:144`, `toJson` 179-185, all-or-nothing `fromJson` 194-218);
`ThemePalette` 257-591: normalizing factory `:262`; `customName = 'Custom'`
`:324`; `minCornerScale`/`maxCornerScale` 0/2 `:325-326`; fields 330-360
(11 nullable slots, `terminal` 349-352, `fontFamily` 355-357, `cornerScale`
358-360); `slot` `:374`, `withSlot` `:390`, `withTerminal` `:415`,
`withFontFamily` `:420`, `copyWith` `:425`, `matchingPreset` `:464`,
`relabelled` `:475`; `toJson` 488-496; `fromJson`
507-532 (gaps fill from `ThemePresets.seance` `:510`, unnamed reads relabel);
`decodeStored` 539-549 (never throws, falls back to `ThemePresets.initial`);
`tryParse` 556-566 (rejects JSON with no value key); `_valueKeys` 572-578
(`accent` + 11 slot names + `terminal` + `fontFamily` + `cornerScale`).

**Séance `theme/theme_presets.dart` map** (414): doc 6-23 ("a preset is a
starting point, not a mode"); `seance` 30-33 (all Automatic, accent
`SeanceTheme.seed`); `graphite` 37-41; `paper` 44-87; `newsprint` 89-136;
`solarized` 138-177; `midnight` 179-218; `terminal` 220-265; `vapor`
267-307; `bubblegum` 309-349 (deeper `#E63A91` accent, `:22-23`);
`highContrast` 351-391; `all` 398-409; `initial => terminal` 413. Eight of
the ten carry a `ThemeTerminalColors` block (`terminal:` initializers at
`:61,104,151,192,239,281,323,368`; all but `seance` and `graphite`).

**Séance `ui/appearance_settings.dart` map** (1016): widget + deps
(`SettingsBackend`, `SystemFonts`) 32-45; `_slotLabels` 49-61; `_colourSlots`/
`_statusSlots` 63-78; `_ansiNames` 81-98; state and write-through coalescing
112-199 (`_persist` 157-177: one write in flight, dirty-folded, error toast
only when nothing newer waits); preset/paste/reset adopt 190-199;
`_setAutomatic` set-aside restore 202-216; pickers 218-246 (`showColorPicker`
via the app wrapper); terminal toggle/pickers 248-275 (`SeanceTerminalThemes`
at `:253-254` seeds first-use colors); font field + `_pickFont` via
`showFontPicker` 277-295; `_copy` 297-304 (`JsonEncoder.withIndent('  ')` of
`palette.toJson()`); `_paste` 306-321 (`ThemePalette.tryParse`); `_reset`
323-345; sections 355-510 (Theme help, Mode, Colours, Status colours,
Terminal colours, Shape and type, Share, Start over); `_terminalSection`
513-574; `_shapeSection` 576-637 (font `TextField` + picker suffix 583-597,
corners slider 599-621); `_Footnote`/`_ColourRow`/`_SwatchButton` 639-760;
`_PresetGrid`/`_PresetTile` 764-925 (`SeanceTheme.resolvedSlots` per preset at
`:787-788`); `_AnsiGrid` 926-967; `_TerminalPreview` 970-1016 (mono stack
`SeanceTheme.monoFallback` `:993-994`).

**Poltergeist `lib/theme/app_theme.dart` map** (895): `poltergeistSeedColor`
`0xFF3D8A78` 15-21; `poltergeistMonoFontFamilies`/`poltergeistMonoTextStyle`
23-40; `_Neutrals` 50-215 (superset of Séance's: adds `error`,
`errorContainer`, `onErrorContainer`, `onSelection`, `connected`,
`connecting`); `_drawnAt` 199-203; `_neutralsFor` 215-298 (`onSelection`
rule 288-294); `_selectionFor` 304-311; `_StatusColors` typedef + `_statusFor`
314-330; `PoltergeistChrome` 337-541 (Séance's 15 fields **plus**
`statusConnected`/`statusConnecting`/`statusFailed`/`statusUnknown`
351-415; `of` 436-441); `isDesktopPlatform` (public) ~531; `_chromeFor`/
`_chromeOver` 542-625; `buildPoltergeistTheme` 626-633; `poltergeistThemesFor`
640-668; `resolvedThemeSlots` 674-693; `buildPoltergeistThemeFor` 698-895
(scheme 707-739, component themes 766-861, extensions 862-892,
`GhostMenuTheme.apply` 894).

**Poltergeist `theme/theme_palette.dart` map** (449): `ThemeSlot` 24-64 (same
11 names, Poltergeist worded docs); codec 66-113 identical; `ThemePalette`
133-449, same fields minus `terminal` (`'fontFamily': ?fontFamily` null-aware
map element `:352`); `toJson` 347-354 writes `name`, `accent`, set slot keys,
`fontFamily`, `cornerScale` and never `terminal`; `fromJson` 365-390 (fallback
`ThemePresets.poltergeist` `:366`, reads past `terminal` per the doc comment
`:364`); `decodeStored` 396-406; `tryParse` 413-424; `_valueKeys` 430-435
(excludes `terminal` deliberately: "an object holding only that would change
nothing").

**Poltergeist `theme/theme_presets.dart` map** (226): provenance header 1-5;
`poltergeist` 39-42; `graphite` 47; `paper` 54; `newsprint` 72; `solarized`
97; `midnight` 114; `terminal` 131 (name `Terminal`, no terminal block);
`vapor` 151; `bubblegum` 169 (same `#E63A91`); `highContrast` 187; `all`
210-221 (same order, `poltergeist` first); `initial => vapor` 225.

**Poltergeist `ui/settings/appearance_settings.dart` map** (839): divergence
header 1-7; `AppearanceSection` over `AppearanceSettingsModel` 35-42;
slot lists 44-59; `slotLabel` ARB switch 62-74; `presetLabels` ARB map 78-89
(stored names stay English); state 106-300: `_setAside` 110-115, `_persist`
150-177 (same coalescing), `_edit`/`_adopt`/`_setMode`/`_setAutomatic`
179-216, `_pickSlot`/`_pickAccent` 218-237 (`showColorPicker` with ARB title),
`_commitFont` 239-243 (text field only), `_copy` 245-253 (same pretty JSON),
`_paste` 255-266, `_reset` 268-290; build 292-345 (`_Heading` with ARB help,
`_PresetGrid`, mode, colour rows, status rows, share); `_shapeSection` 444+
(`appearance.fontFamily` TextField `:450-452`, corner `Slider` `:473`);
`_PresetGrid`/`_PresetTile`/`_ColourRow`/`_SwatchButton`/`_Footnote` below.

### 1.2 The stored and pasted form (X-01, v1)

Two layers, both device-local and never synced:

- **Container.** Séance stores the palette inside the one `settings.json`
  document as top-level keys `themePalette` (palette JSON object) and
  `themeMode` (enum name); `app_settings.dart` fields `:257-265`
  (device-local rationale `:250-256`), write `:373-376`, lenient read
  `:443-447`. Poltergeist stores two keys in its `SettingsStore`:
  `theme.palette` and `theme.mode` (`app_preferences.dart:42-43`),
  `loadAppearance` 452-468 / `saveAppearance` 471-474.
- **Palette JSON (the pasted form).** Keys: `name`, `accent`, the eleven
  `ThemeSlot.name`s when set, `fontFamily`, `cornerScale`, and in Séance's
  format `terminal` = `{background, foreground, cursor, selection, ansi[16]}`
  (`theme_palette.dart:488-496`, terminal block `:179-185`). Automatic values
  are omitted, not written as null (`:485-487`). X-01 v1 compatibility (a
  theme copied in one app pastes whole in the other (`03-ARCHITECTURE.md:2388`,
  `04-IMPLEMENTATION.md:188`)), rests on: identical key names and hex grammar;
  English stored `name` values shared across apps; `decodeStored`/`tryParse`
  leniency (`theme_palette.dart:539-566` / `:396-424`); Poltergeist reading
  past `terminal` while never writing it (`theme_palette.dart:364`,
  `430-435`, tested `test/theme/theme_palette_test.dart:101-165` and end to
  end `test/ui/settings/appearance_settings_test.dart:433`). A
  `{"terminal": ...}`-only clipboard is a theme for Séance but not for
  Poltergeist, a real behavioral difference the shared reader must keep
  parameterizable (§4).

### 1.3 Divergences between the two stacks

1. **Terminal block.** Séance's `ThemePalette` carries `terminal` and the
   editor has a Terminal colours section; Poltergeist has neither and reads
   past the key. Presets differ accordingly.
2. **Status colors.** Séance: separate `SeanceStatusColors` extension
   (`theme.dart:708-753`) with per-brightness constants (`:242-260`), consumed
   through `StatusColors.online(context)` statics (`:755-768`) in 4 widget
   files. Poltergeist: four `status*` fields on `PoltergeistChrome`
   (`app_theme.dart:351-415`), Automatics from its neutrals table
   (`:325-330`); `offline`/`unknown` fall back to `error`/`outline` so a
   palette's red dot cannot restyle error text (PORTS `poltergeist/docs/
   PORTS.md:1924-1932`).
3. **`onSelection`.** Séance always computes it over the rail
   (`theme.dart:411-413`); Poltergeist computes it over the listing for a
   custom selection and pins the tuned teal's in the table
   (`app_theme.dart:288-294`). PORTS `:1933-1935`.
4. **Neutrals tables.** Shared neutral values are byte-identical (slate dark,
   Finder light); Poltergeist's `_Neutrals` adds the pinned error family,
   `onSelection`, `connected`, `connecting`, and its primary family is teal
   where Séance's is violet. Séance leaves `error*` to
   `ColorScheme.fromSeed` (`theme.dart:530-560` does not touch them);
   Poltergeist pins them (`app_theme.dart:736-738`), so a custom accent
   re-seeds Séance's error but never Poltergeist's.
5. **Component tweaks.** `visualDensity`: Séance `comfortable`
   (`theme.dart:584`), Poltergeist `compact` (`app_theme.dart:767`).
   `focusColor`: Poltergeist only (`:770`). `dialogTheme`: Poltergeist always
   shapes (radius 12, `_dialogRadius` vs Séance's 28) and styles the desktop
   title (`:804-810`); Séance only when `scaled` (`theme.dart:608-610`).
   `tooltipTheme`: Poltergeist sets `textStyle` with `palette.fontFamily`
   (`:780-786`); Séance does not. `floatingActionButtonTheme`: Poltergeist
   only (`:833-835`, `_fabRadius` 16). `menuTheme.padding`: Poltergeist sets
   a desktop value (`:796-798`) that `GhostMenuTheme.apply` overwrites; dead
   on desktop, null on touch; safe to drop on extraction.
6. **API shape.** Séance: `SeanceTheme.{seed,light,dark,forAppearance,
   resolvedSlots,build,monoFallback}`, private `_isDesktop`. Poltergeist:
   top-level `buildPoltergeistTheme`, `poltergeistThemesFor`,
   `resolvedThemeSlots`, `buildPoltergeistThemeFor`, public
   `isDesktopPlatform` (`app_theme.dart:531`, used by 8+ files outside the
   theme), `poltergeistSeedColor`, `poltergeistMonoTextStyle`. PORTS
   `:1942-1945`.
7. **Editor UI.** Séance literals, `SettingsBackend` + `SystemFonts` +
   installed-font picker + terminal section + `SettingsPage`/
   `SettingsSectionHeader` chrome; Poltergeist ARB throughout
   (`presetLabels` for names), `AppearanceSettingsModel`, plain font text
   field, no terminal, column scroll for both the window tab and the dialog.
   PORTS `:1966-1982`.
8. **Extra extension.** Poltergeist installs `CompareDiffColors.derive`
   (`app_theme.dart:865-870`); stays app-side.

### 1.4 What already lives in shared packages

`ghost_ui` (`planchette/packages/ghost_ui`, barrel `lib/ghost_ui.dart` 29)
already owns everything the plan names as "extensions shared widgets need":
`src/appearance.dart` (36): `ThemeModePreference` `:12-21`,
`surfaceBrightness` `:29-30`, `automaticBrightness` `:33-36`.  
`src/sidebar_theme_tokens.dart` (169): `SidebarThemeTokens` `:35-75`
(`sidebarBackground`, `separator`, `hoverFill`, `capsuleFill`,
`inactiveSelectionFill`, `secondaryText`, `sidebarRowExtent`, `cornerScale`),
`of` fallback `:78-117`, `copyWith`/`lerp` `:118-168`.  
`src/family_hues.dart` (204): `FamilyHue` (12 hues) `:38`, `FamilyPalette`
`:56-160` (`forBrightness` `:103`, `glyph` `:115`), `FamilyHueTile` `:162`.  
`src/color_picker.dart` (478): `ColorPickerStrings`, `showColorPicker`,
`ColorSwatchBox`; both apps wrap it (`ui/color_picker.dart` 36/34).  
`src/ghost_menus.dart` (280): `GhostMenuTheme.apply` `:27`,
`ghostTextContextMenu` `:175`, reached today through the
`planchette_editor` barrel's 5-line re-export
(`planchette_editor/lib/src/ghost_menus.dart:1-5`).  
`src/ghost_file_theme.dart` (144): `GhostFileTheme` `:11` (8 fields + `rowExtent`,
`of` fallback `:53`).  
`src/contrast.dart` (33): `contrastRatio`, `compositeOver`, `legibleOn`,
extracted from Séance's `theme/contrast.dart`, header `:1-3`.

ghost_ui already holds the tests too: `test/appearance_test.dart`,
`contrast_test.dart`, `family_hues_test.dart`, `sidebar_theme_tokens_test.dart`,
`color_picker_test.dart`, `ghost_menu_theme_test.dart`.

`ghost_desktop` owns the settings-window link engine both apps ride
(`GhostSettingsWindowHost`/`GhostSettingsSections` used by
`seance/.../services/settings_window.dart:109-119` and Poltergeist's
`settings_window_host.dart`); its codec is app-defined, so the appearance
payload (`encodeAppearance`/`decodeAppearance`,
`settings_window_link.dart:196-206` in Poltergeist; Séance's
`SettingsLinkMethod.setAppearance` dispatch `settings_window.dart:171-176`)
stays app-side.

### 1.5 What stays app-side

- Per-app style constants: seed color, brand preset name, `initial` preset,
  dialog radius, density, focus color, tooltip/fab/menu details; the package
  takes them as a style parameter (§4).
- The preset façade (`ThemePresets`) and builder façade (`SeanceTheme`,
  `poltergeistThemesFor`) become thin app-side aliases or typedefs.
- Persistence: `AppSettings.themePalette`/`themeMode` and
  `SettingsBackend.setAppearance` (Séance `app_settings.dart:257-265,373-376,
  443-447`; `settings_backend.dart:84-86`; `local_settings_backend.dart:
  131-144` applies before saving); `AppPreferences.loadAppearance`/
  `saveAppearance` and `AppearanceController`
  (`appearance_controller.dart:21-42`, apply-then-save) in Poltergeist;
  the settings-window wire (`SettingsLinkMethod.setAppearance`,
  `encodeAppearance`/`decodeAppearance`) and the remote model
  (`remote_settings.dart:235-256`).
- `AppAppearance` wiring: `AppState.appearance` notifier
  (`app_state.dart:2398-2411`), `main.dart:311-330` and
  `settings_window_app.dart:94-105` `ValueListenableBuilder`s in Séance;
  `app.dart:460-483`, `main.dart:546-549` (constructed with
  `loadAppearance`/`saveAppearance`), `settings_window_app.dart:101-114`,
  `editor_window_app.dart` in Poltergeist.
- Séance-only consumers of `terminal`: `terminal_appearance.dart` (212,
  `SeanceTerminalThemes.builtIn`/`fromColors`/`toColors` map to the vendored
  xterm `TerminalTheme`, `:91-140`), the terminal panes' Colors=followApp
  path (`:169-190`).
- Séance-only font machinery: `services/system_fonts.dart` (549:
  `SystemFonts` `:43-52`, `NoSystemFonts` `:57-64`, `SfntSystemFonts` `:70`),
  `ui/font_picker.dart` (298, `showFontPicker` `:52`).
- `CompareDiffColors` (Poltergeist, `compare_diff_colors.dart` 171).
- The localization seam: Séance has no ARB; Poltergeist's
  `AppLocalizations` + `localization_contract_test.dart` allowlist entries
  for `lib/theme/*.dart` and the appearance section
  (`localization_contract_test.dart:427-465`) stay in the app, becoming dead
  keys to drop when its files move (same disposition as the F3-era picker
  move).

### 1.6 Tests and the pixel baselines

Séance theme tests: `test/theme_palette_test.dart` (294; hex forms, lenient
decode, terminal whole-or-nothing `:98-117`, stored keys incl. `terminal`
`:180`, copy/paste round-trip `:267`), `test/theme_presets_test.dart` (184;
order/identity `:18-44`, completeness `:46`, per-preset contrast `:66-133`,
terminal contrast `:135-161`, family hues `:163`), `test/theme_build_test.dart`
(491; frozen pre-theme scheme `_legacyScheme` `:13-40` compared whole
`:43-152`, palette→scheme/chrome `:171-272`, brightness `:274-348`, corner
scale `:349-426`, font `:411-426`, sidebar tokens mirror `SeanceChrome`
`:427-466`), `test/seance_chrome_test.dart` (70), `test/status_colors_test.dart`
(108), `test/color_picker_test.dart` (75), `test/family_hues_test.dart` (99),
`test/system_fonts_test.dart` (605), `test/font_picker_test.dart` (189),
`test/terminal_appearance_test.dart` (273), `test/app_settings_test.dart`
theme persistence `:354-400`, `test/settings_window_test.dart` (466; theme
re-themes app and window `:212-230`), `test/settings_screen_test.dart`
(1244; Appearance group `:566-924`: preset pick, screen-reader label, mode,
Automatic off/on, terminal colours, reset, copy, paste rejection/adoption,
layout fit, coalesced writes, save-error toast).

**Pixel baselines are generated, not committed.** No golden PNGs exist under
`seance/app/seance_app/test/` (the only committed goldens are the vendored
xterm's own `seance/third_party/xterm/test/src/_goldens/`). The baseline
mechanism is opt-in capture tests:

- `test/server_list_capture_test.dart` (454): nothing is written unless
  `SEANCE_CAPTURE=1` (`:32`); PNGs land in `SEANCE_CAPTURE_DIR`, default
  `build/sidebar-captures` (`:33-34`). Scenes are pumped and sanity-checked
  on every run regardless (`:28-31`). Real fonts: `FontLoader` loads
  `MaterialIcons-Regular.otf` from the Flutter SDK (`FLUTTER_ROOT` or derived
  from `Platform.resolvedExecutable`, `:48-58`) and `DejaVuSans.ttf` (+ Bold)
  from `SEANCE_CAPTURE_FONT_DIR`, `/usr/share/fonts/truetype/dejavu`, or
  `$HOME/.local/share/fonts` (`:59-72`), installed as the `Capture Sans`
  family and applied to both text themes (`:75-83`); the widget-test
  default font draws boxes, hence the real face (`:24-26`).
- `test/family_hues_capture_test.dart` (397): same mechanism plus
  `SEANCE_CAPTURE_PREFIX` for before/after pairs (`:24-31`), regular, bold,
  mono and mono-bold DejaVu faces.

So "pixel baselines unchanged" for the Séance switch means: run
`SEANCE_CAPTURE=1` (with `SEANCE_CAPTURE_DIR`/`_PREFIX` separating runs)
before and after the move on one host and diff the PNG pairs, on top of the
always-on suite. Poltergeist has the same pattern under `POLTERGEIST_CAPTURE*`
(`test/ui/family_hues_capture_test.dart:26-45,287`,
`built_in_editor_capture_test.dart:21-76`, `quick_open_capture_test.dart`,
`quit_dialog_capture_test.dart`): its follow-up gate.

Poltergeist theme tests: `test/theme/theme_palette_test.dart` (338; cross-app
paste `:101-165`, terminal-only is not a theme `:162`), `test/theme/
theme_presets_test.dart` (314; shared presets match Séance by name and order
`:58-75`, sidebar dots matrix `:202-249`, diff colors per preset `:251-290`),
`test/theme/theme_build_test.dart` (475) against the frozen
`test/theme/legacy_theme.dart` (293; `app_theme.dart` @ `c4d4512`, header
`:1-7`), `test/theme/compare_diff_colors_test.dart` (175),
`test/theme/context_menu_theme_test.dart` (29), `test/app_appearance_test.dart`
(70; live re-theme only on appearance), `test/ui/app_theme_test.dart` (141;
`PoltergeistChrome` lerp/copyWith `:45-96`), `test/ui/settings/
appearance_settings_test.dart` (571; fake `AppearanceSettingsModel`, ARB
preset names `:131`, coalesced writes `:333`, Séance paste `:433`, failure
toast `:483`), `test/app_preferences_test.dart` (589; device-theme group
`:162-227` checks `theme.palette`/`theme.mode` keys and garbage tolerance),
`test/ui/settings/settings_window_app_test.dart` (324),
`test/localization_contract_test.dart` (2832; theme-file allowlists
`:427-465`), `test/ui/contrast_matrix_test.dart` (224) +
`test/ui/contrast_math.dart` (35), `test/ui/family_hues_test.dart` (123).

## 2. Package proposal

New package `planchette/packages/ghost_theme`, host-neutral like `ghost_ui`
(`planchette/AGENTS.md:24-25`: "shared leaf UI widgets/theme tokens … no app
or host dependencies").

```yaml
dependencies:
  flutter: { sdk: flutter }
  ghost_ui: { path: ../ghost_ui }
```

Nothing else: the model is pure Flutter data; the editor needs `ghost_ui`'s
picker, `SidebarThemeTokens` contract and `FamilyPalette`; the menu skin is
`ghost_ui`'s `GhostMenuTheme` (the `planchette_editor` import is only a
re-export seam, §1.4). No `seance_*`/`poltergeist_*` dependency, so the
suite import guard (`tool/import_guard`, moved from `poltergeist/tool` in F1a) and pin audit are
untouched. Layout mirrors `ghost_marks`/`ghost_ui`: `lib/ghost_theme.dart`
barrel over `lib/src/*.dart`, `test/` beside it, suite registration in
`scripts/test.sh:141-151` and `ci.yml:899-936` (`planchette_flutter`).

Boundary choices:

- **The package's `ThemePalette` is Séance's superset**, including
  `ThemeTerminalColors` and the `terminal` field and key, the only shape
  that round-trips both apps' stored data and X-01. Hosts that do not want
  it opt out through the codec seam (§4), preserving Poltergeist's exact
  read-past and never-write behavior.
- **One shared chrome extension** (`GhostChrome`) carrying the superset
  field set: Séance's fifteen fields plus Poltergeist's four `status*` fields.
  Putting status next to the tokens it must keep contrast with is
  Poltergeist's documented design (`PORTS.md:1924-1932`), and it costs
  Séance only a 14-line `StatusColors` adapter (or `typedef`s) instead of a
  second installed extension. Rejected alternative: keep a separate
  `GhostStatusColors` extension, which would be two sources of the same four colors with
  no consumer need.
- **Neutral tables are per-app parameters**, but the shared neutral fields
  are one table definition in the package (`GhostThemeNeutrals`); the
  per-app surface is the brand/error/status family. The slate/Finder values
  themselves are byte-identical between the apps; the sibling look is the
  contract, not a coincidence (`theme.dart:15-19`, `app_theme.dart:42-49`).
- **The Appearance editor moves with a string bag and a model seam**
  (Poltergeist's `AppearanceSettingsModel` shape is the one both backends
  already satisfy: `value` + `setAppearance`). The terminal subsection and
  the font picker's existence are style/seam parameters. The editor widget
  lives in the package rather than each app porting a third copy, and that is
  the F4b scope ("theme editing") and what Klabautermann shows in Settings
  (§5).
- Rejected: extracting only the model and leaving builders app-side (keeps
  ~900 lines of duplicated theme construction per app and forces a third
  copy for Klabautermann). Rejected: folding into `ghost_ui` (its charter is
  leaf widgets; a theme stack with presets and a settings editor is a layer
  above it; same reasoning as the `ghost_marks` split).

## 3. String injection

Follow the `EditorStrings`/`ColorPickerStrings` precedent: a concrete
`GhostAppearanceStrings` class, `const` constructor, English defaults equal
to Séance's current literals (`appearance_settings.dart:50-98,355-445`),
parameterized methods for interpolations. Members needed: the eight section
headings and help texts; the eleven slot labels plus `accent`; the sixteen
ANSI names; preset tile tooltip `presetTooltip(String name)` and
`usingPreset`/`ownColours` footers; mode labels and the own-surface note;
`automatic` chip + `automaticSemantics(label)`; swatch tooltips (two forms);
font label/hint/helper and picker tooltip; corners `square`/`percent(n)`;
share `copy`/`paste`/`copied`/`pasteNotATheme`; reset
`title`/`body(name)`/`cancel`/`confirm`/`button(name)`; `notSaved(error)`;
terminal section strings incl. `ansiName(i)`, `normal`/`bright`,
preview semantics. Slot labels arrive as `slotLabel(ThemeSlot)` on the bag:
the keys are already an enum both apps share, so adapters are a switch.
`presetLabel(String storedName)` maps the stored English name to the display
name (Poltergeist adapter → `themePreset*` ARB `app_en.arb:2724-2761`;
Séance default = the stored name itself, matching today's
`appearance_settings.dart:836-876` where `preset.name` is shown literally).
The stored `name` and `'Custom'` remain English data (X-01), exactly as
Poltergeist's contract test records (`localization_contract_test.dart:
445-465`).

Adapters: Poltergeist gains `PoltergeistAppearanceStrings extends
GhostAppearanceStrings` mapping to `AppLocalizations` (the
`PoltergeistEditorStrings` shape); Séance supplies nothing (defaults are its
literals); Klabautermann maps ARB from day one (03 §10.10, `:3201-3204`).
The color picker's own strings stay in `ghost_ui`'s `ColorPickerStrings`;
the editor passes them through from the host's picker wrapper or bag.

## 4. Public API (Dart)

```dart
// lib/ghost_theme.dart

export 'package:ghost_ui/ghost_ui.dart'
    show ThemeModePreference, surfaceBrightness, automaticBrightness,
        SidebarThemeTokens, FamilyPalette, FamilyHue, FamilyHueTile,
        GhostFileTheme, GhostMenuTheme, ColorPickerStrings,
        showColorPicker, ColorSwatchBox,
        contrastRatio, compositeOver, legibleOn;

enum ThemeSlot { surface, sidebar, raised, text, secondaryText, hairline,
  selection, online, offline, connecting, unknown /* + allowsAlpha */ }

Color? parseThemeColor(Object? value);
String formatThemeColor(Color color);

final class ThemeTerminalColors { /* Séance's verbatim: ansiCount,
  yellowIndex, background/foreground/cursor/selection/ansi, copyWith,
  withAnsi, toJson, static fromJson (all-or-nothing), == */ }

final class ThemePalette {
  factory ThemePalette({String name, required Color accent,
    Color? surface, ... Color? unknown,
    ThemeTerminalColors? terminal, String? fontFamily,
    double cornerScale = 1});
  static const String customName = 'Custom';
  static const double minCornerScale = 0, maxCornerScale = 2;
  // name, accent, 11 nullable slots, terminal, fontFamily, cornerScale;
  // slot/withSlot/withTerminal/withFontFamily/copyWith; toJson writes
  // `terminal` only when set (Poltergeist-safe by construction).
}

/// Per-app fixed inputs to the shared builder.
final class GhostThemeStyle {
  const GhostThemeStyle({
    required this.seed,                 // accent whose tuned tables apply
    required this.brand,                // first preset ('Séance', ...)
    required this.initial,              // ThemePresets.initial
    required this.dark, required this.light,   // GhostThemeNeutrals tables
    this.hasTerminal = false,
    this.selectionLabel = SelectionLabel.overRail,   // | overListing
    this.dialogRadius = 28, this.scalesDialogAlways = false,
    this.dialogTitleOnDesktop = false,
    this.tooltipUsesInterfaceFont = false,
    this.fabRadius,                                  // null = no FAB theme
    this.visualDensity = VisualDensity.comfortable,
    this.focusColorOpacity,                          // null = unset
    required this.monoFontFamilies,
  });
}

final class GhostThemePresets {
  GhostThemePresets(GhostThemeStyle style);
  List<ThemePalette> get all;          // brand + shared nine; terminal
                                       // blocks stripped when !hasTerminal
  ThemePalette? matching(ThemePalette palette);   // today's matchingPreset
  ThemePalette relabel(ThemePalette palette);     // today's relabelled()
}

/// Codec seam carrying the per-app defaults today's statics close over.
final class GhostThemeCodec {
  const GhostThemeCodec(GhostThemeStyle style);
  ThemePalette decodeStored(Object? json);       // never throws; initial fallback
  ThemePalette? tryParse(String text);           // `terminal` counts as a
                                                 // value key iff hasTerminal
  ThemePalette fromJson(Map<String, Object?> json);  // gaps fill from brand
}

final class GhostChrome extends ThemeExtension<GhostChrome> {
  /* Séance's 15 fields + statusConnected/statusConnecting/
     statusFailed/statusUnknown; corner(double); copyWith; lerp;
     static of(BuildContext, GhostThemeStyle style) */
}

final class AppAppearance { const AppAppearance({required this.palette,
  this.mode = ThemeModePreference.system}); /* ==, hashCode */ }
Brightness resolveBrightness(ThemePalette, Brightness platform,
  ThemeModePreference mode);

abstract final class GhostTheme {
  static ThemeData light(GhostThemeStyle, {TargetPlatform? platform});
  static ThemeData dark(GhostThemeStyle, {TargetPlatform? platform});
  static ThemeData build(GhostThemeStyle, ThemePalette, Brightness,
    {TargetPlatform? platform});
  static ({ThemeData theme, ThemeData darkTheme, ThemeMode themeMode})
    forAppearance(GhostThemeStyle, AppAppearance, {TargetPlatform? platform});
  static Map<ThemeSlot, Color> resolvedSlots(GhostThemeStyle, ThemePalette,
    Brightness);
}

bool isGhostDesktopPlatform(TargetPlatform platform);  // Poltergeist's
                                                       // isDesktopPlatform

abstract interface class GhostAppearanceModel {
  AppAppearance get value;
  Future<void> setAppearance(ThemePalette palette, ThemeModePreference mode);
}

class GhostAppearanceStrings { /* const ctor, English defaults, members in §3 */ }

final class GhostAppearanceSection extends StatefulWidget {
  const GhostAppearanceSection({
    required GhostThemeStyle style,
    required GhostAppearanceModel model,
    this.strings = const GhostAppearanceStrings(),
    this.pickInstalledFont,          // null: text field only (Poltergeist)
    this.defaultTerminalColors,      // null/hasTerminal==false: no terminal part
  });
}
```

`build` installs `GhostChrome`, `FamilyPalette.forBrightness`,
`SidebarThemeTokens`, `GhostFileTheme` and returns through
`GhostMenuTheme.apply`, the same list both apps install today
(`theme.dart:656-688`, `app_theme.dart:862-894`). Host-only extensions
(`CompareDiffColors`) are appended by the host after `build`: expose
`GhostTheme.build` returning `ThemeData` so the host adds
`theme.copyWith(extensions: [...theme.extensions, CompareDiffColors...])`,
or the style takes an `extraExtensions` hook; recommend the simple copyWith
at the call site.

App-side shims keep Séance's suite green during the switch:
`typedef SeanceChrome = GhostChrome` (its `of` signature gains the style;
the 14 `SeanceChrome.of` call sites take `seanceThemeStyle`), `typedef
SeanceStatusColors` is replaced by the existing `StatusColors` statics
re-pointed at `GhostChrome.of`, `SeanceTheme` becomes a thin façade over
`GhostTheme` bound to `seanceThemeStyle`.

## 5. Migration plan (one monorepo, staged PRs)

Per D3, each PR moves code and switches a shipped app in the same PR; suites
and captures are the gate.

- **PR 1: package skeleton + model.** Create `ghost_theme`; move
  `ThemeSlot`, `ThemeTerminalColors`, `ThemePalette`, hex codec,
  `AppAppearance`, `resolveBrightness`, `GhostThemePresets`,
  `GhostThemeCodec`. Move Séance's `theme_palette_test.dart` (294) and the
  palette half of `app_appearance`-level tests; the app's files become
  `export` shims. Séance's full suite + a `SEANCE_CAPTURE=1` capture pair
  run unchanged. No behavior change: Séance's codec is constructed with
  `hasTerminal: true`.
- **PR 2: builder + extensions.** Move `_Neutrals`/`_neutralsFor`/
  `_selectionFor`/`_statusFor`/`_desktopText`/radius constants/`build` as
  `GhostThemeStyle` + `GhostTheme` + `GhostChrome`; Séance's `theme.dart`
  becomes facades (`SeanceTheme`, `SeanceChrome` typedef, `StatusColors`
  adapter, `monoFallback` stays as the style's `monoFontFamilies`).
  `theme_build_test.dart` (491) moves mostly intact; its frozen
  `_legacyScheme` comparison is exactly the regression gate for a move;
  `seance_chrome_test.dart`, `status_colors_test.dart` move/adapt. Switch
  `main.dart`/`settings_window_app.dart` to the façade or directly to
  `GhostTheme.forAppearance`. Captures: `server_list_capture` +
  `family_hues_capture` PNG pairs diffed identical.
- **PR 3: editor UI.** Move `appearance_settings.dart` as
  `GhostAppearanceSection` + `GhostAppearanceStrings` + the model seam;
  Séance's file becomes a thin `AppearanceSettings` wrapper that keeps its
  constructor signature (`backend`, `systemFonts`), wiring the
  `pickInstalledFont` seam to `showFontPicker` and
  `defaultTerminalColors` to `SeanceTerminalThemes`. Move the Appearance
  group of `settings_screen_test.dart` (`:566-924`) to the package
  (fake model, mirroring Poltergeist's `appearance_settings_test.dart`).
  Suite + captures unchanged.
- **PR 4: bookkeeping + ledger.** `scripts/test.sh:141-151`,
  `ci.yml:897-936`, `poltergeist/docs/PORTS.md` device-themes section
  (`:1858-2006`) annotated "Moved to ghost_theme", root release tooling if
  it enumerates packages (`04-IMPLEMENTATION.md:61-69`).
- **PR 5+ (planned follow-up): Poltergeist.** Same three moves on its
  copies: palette/presets/appearance (codec `hasTerminal: false`),
  `app_theme.dart` → style + façades (keep `poltergeistThemesFor`,
  `isDesktopPlatform` alias, `poltergeistSeedColor`,
  `poltergeistMonoTextStyle`, `PoltergeistChrome` typedef), editor →
  `AppearanceSection` wrapper + `PoltergeistAppearanceStrings`; drop the
  dead contract-test allowlist entries (`localization_contract_test.dart:
  427-465`) in the same PR; `CompareDiffColors` stays. Gates: full suite,
  `POLTERGEIST_CAPTURE` pairs, `legacy_theme.dart` whole-`ThemeData`
  comparison.
- **Klabautermann (M1+):** consumes `ghost_theme` from the scaffold (own
  brand preset/accent/neutrals family, `hasTerminal: false`, ARB adapter)
  and gets editing/presets free; sibling paste lands at v1 (X-01)
  automatically once the keys are shared.

## 6. Tests that move or are added

Move with the code (Séance first): `theme_palette_test.dart` (294),
`theme_presets_test.dart` (184; its per-preset contrast floors become the
package's preset contract), `theme_build_test.dart` (491), the Appearance
group of `settings_screen_test.dart` (`:566-924`), `seance_chrome_test.dart`
(70), `status_colors_test.dart` (108). On the Poltergeist follow-up:
`theme/*_test.dart` merge into the package's suites (cross-app paste cases
stay as package tests; they define X-01), `appearance_settings_test.dart`
collapses into the moved group plus ARB-adapter tests, `app_preferences_test`
device-theme group stays app-side (store keys are app keys), capture tests
stay app-side (they capture app scenes).

Add in the package: codec tests for both `hasTerminal` shapes (a terminal-
only clipboard parses for Séance, is not a theme for Poltergeist; the two
pinned behaviors that make the seam mandatory); `GhostChrome` lerp/copyWith;
`GhostThemePresets.matching`/`relabel`; a style-equivalence test that freezes
each app's `GhostThemeStyle` against its current tables (Séance's
`_legacyScheme` and Poltergeist's `legacy_theme.dart` pattern); extension
installation test (chrome + `SidebarThemeTokens` + `GhostFileTheme` +
`FamilyPalette` present, menu applied on desktop). Add for Klabautermann at
M4: a contract test that a Séance-copied theme JSON pastes into
Klabautermann's codec (X-01).

## 7. Risks

- **Pixel drift from reordered construction.** `build` is ~160 lines of
  `copyWith` calls; a missed component theme or reordered extension lands
  silently (lerp order, density). Mitigation: the frozen-scheme whole-
  `ThemeData` comparisons (`theme_build_test.dart:43-152`,
  `legacy_theme.dart`) catch it field by field; the capture pairs catch
  anything structural.
- **Codec flag asymmetry.** `hasTerminal` must gate `_valueKeys`
  (`tryParse`) and `fromJson`/`toJson` symmetrically; getting either wrong
  changes stored bytes on disk for one app. Mitigation: dedicated package
  tests for both shapes before either app switches.
- **`matchingPreset`/`relabelled` need the app's preset list.** Making them
  preset-object methods (`GhostThemePresets`) changes their call sites in
  the editors; mechanical, covered by the editor tests.
- **String drift on the Séance side.** Séance's literals become the bag's
  defaults; any mis-transcription changes visible copy. Mitigation: defaults
  are copied verbatim in PR 3; the moved Appearance group asserts the
  strings (`settings_screen_test.dart:819-860`).
- **Poltergeist regression risk deferred to its own PRs** (R25 mitigation:
  `04-IMPLEMENTATION.md:540`). Its `legacy_theme.dart` gate is stronger than
  Séance's; the follow-up is sized separately below.
- **Scope creep into settings backends.** The backends, windows and stores
  stay app-side deliberately; touching them is out of scope for F4b.
- **`GhostChrome.of` signature change** (takes `style` when the extension is
  absent). Only the fallback path is affected; installed paths are
  unchanged. Séance's 14 call sites take `seanceThemeStyle` in PR 2.

## 8. Estimates and recommendation

- **Moved to the package:** ~1,600 lines from Séance (palette 593 +
  presets ~250 shareable + appearance 47 + builder ~700 of 768 +
  editor ~950 shareable of 1016) plus ~220 new (style/presets/codec/
  strings/model seams). Poltergeist's equivalent ~1,300 lines collapse to
  ~150 of façade + adapter on the follow-up. Net: ~2,900 duplicated
  lines → ~1,800 owned once.
- **Estimates** (engineering time, aligned to the plan's L = 4 to 6 weeks
  for the whole F4b incl. Poltergeist follow-up): PR 1 model ~1 week; PR 2
  builder ~1.5 (the divergence parameterization + frozen-table parity);
  PR 3 editor ~1.5 (string bag inventory is the bulk); PR 4 ~0.5; PR 5+
  Poltergeist switch ~1. Total ~5.5 engineer-weeks, inside the plan's L
  band (04 `:174`, `:540`).
- **Recommendation: extract as designed.** The stacks are already
  port-synchronized (PORTS `:1858-2006`), the divergences are enumerable
  and each has a typed knob or an app-side seam, and the alternative the
  plan rejects (a third port) is the measured cost: ~2,000 lines plus
  tests (c3 §3.6, `03-ARCHITECTURE.md:340`).

## Corrections to the plan

1. **04 §13 F4b scope line lists `SidebarThemeTokens`, `FamilyPalette` and
   "the menu theme" among what moves into `ghost_theme`**
   (`04-IMPLEMENTATION.md:176-178`). All three already live in shared
   packages: `SidebarThemeTokens` and `FamilyPalette` in `ghost_ui`
   (`src/sidebar_theme_tokens.dart:35`, `src/family_hues.dart:56`) and
   `GhostMenuTheme` in `ghost_ui` (`src/ghost_menus.dart:26-75`; the
   `planchette_editor` symbol the apps import is a 5-line re-export,
   `planchette_editor/lib/src/ghost_menus.dart:1-5`). What moves is the
   *installation call* in each app's `build` (`theme.dart:656-679`,
   `app_theme.dart:862-894`), not the extensions. 03's D9 wording ("installs
   the extensions shared widgets need", `03-ARCHITECTURE.md:332-334`) is
   accurate; only 04's "move into" is wrong.
2. **"Séance's real-font PNG pixel baselines" are generated, not stored.**
   No committed baseline PNGs exist for the theme stack; the capture tests
   write PNGs only under `SEANCE_CAPTURE=1` into `build/` and always pump
   the scenes (`server_list_capture_test.dart:28-34`). The gate must be run
   as before/after pairs on one host (§1.6). 04's exit line
   (`04-IMPLEMENTATION.md:184-185`) and R25 (`:540`) imply existing
   baselines; the mechanism still satisfies the intent once the run
   procedure is fixed.
3. **Research doc (c3 §2.5/table) cites Poltergeist `app_theme.dart` as
   "888" lines** (`research/c3-shared-ui-app-shells.md:237`), actually 895
   at this commit, and its extensions range as `:863-874`; the list starts at
   `:862` and runs to `:892`. Cosmetic, but the F4b estimate inherits it.
4. **c3 §2.5 attributes the menu theme to `planchette_editor`** (implied by
   the import path). The class is `ghost_ui`'s; both apps import it through
   the editor barrel (`theme.dart:6-7`, `app_theme.dart:6`). Stated for
   precision since it decides `ghost_theme`'s dependency edge (§2).
5. **Séance's palette persistence is not the `theme.palette`/`theme.mode`
   key pair.** Those dotted keys are Poltergeist's
   (`app_preferences.dart:42-43`); Séance stores `themePalette`/`themeMode`
   inside its single settings document (`app_settings.dart:373-376`). 04's
   F4b text does not claim either, but the sibling docs and §1.2 here
   pin it.

## Design decisions resolved

- **Where does `terminal` live?** In the package's `ThemePalette`, gated by
  `GhostThemeStyle.hasTerminal`/`GhostThemeCodec`. Reason: the stored form
  is one object and X-01 requires Séance's key to survive a round trip;
  Poltergeist's exact read-past behavior is preserved by the flag (its
  pinned tests, `theme_palette_test.dart:101-165`, stay green).
- **One chrome extension or two?** One `GhostChrome` (superset incl.
  `status*` fields). Reason: Poltergeist's ledger documents why status
  belongs beside the contrast-gated chrome tokens; a parallel
  `GhostStatusColors` would duplicate the same four colors.
- **`SeanceTheme` statics vs top-level functions?** Keep a `GhostTheme`
  namespace class (Séance's shape). Reason: the switched app's call sites
  (`SeanceTheme.build/forAppearance/resolvedSlots`, 3 main call patterns)
  map one-to-one; Poltergeist's top-level names become aliases either way.
- **Presets shared how?** Package owns the nine shared presets' values and
  order; the host injects `brand` + `initial`. Reason: the nine are already
  value-identical across apps (PORTS `:1908-1914`); only the first slot and
  initial differ.
- **Editor in or out?** In the package with `GhostAppearanceStrings` +
  `GhostAppearanceModel`. Reason: "theme editing … in the MVP preview"
  (03 `:328-340`, decision 5 at `04-IMPLEMENTATION.md:561`) requires it;
  Poltergeist's model seam is already the right shape.
- **Font picker and terminal colors source?** Host seams
  (`pickInstalledFont`, `defaultTerminalColors`), not package code. Reason:
  `SystemFonts`/`showFontPicker` and `SeanceTerminalThemes` are Séance-only
  and drag in platform font scanning and the vendored xterm respectively.
- **`GhostChrome.of` fallback?** Takes the style (`of(context, style)`).
  Reason: the fallback constructs the app's table values, which are
  per-app; call sites name the style explicitly instead of a package-global
  default.
- **Where does `isDesktopPlatform` live?** Package, public
  (`isGhostDesktopPlatform` or keep name). Reason: Poltergeist uses it in
  8+ non-theme files; Séance's private `_isDesktop` becomes the same helper.
- **Behavior changes?** None in F4b: every divergence above is preserved as
  a style parameter, never unified; unifications (e.g. Séance's density to
  `compact`, error-family pinning) are out of scope and belong to separate
  PRs with their own tests and changelog lines (D3).
