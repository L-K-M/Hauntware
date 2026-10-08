# Shared package design: the server-appearance cluster

Scope: `ServerBadge`/`ServerAccentBar`/tint+glyph tables, the mark picker, the two color pickers, and the badge-image pipeline, duplicated between `seance/app/seance_app` and `poltergeist/app/poltergeist_app`. Read-only design; no code changed.

Status: approved by the owner on 2026-10-08 as recommended. Open questions
settled by the recommendations: Séance's incompressible-image wording
replaces Poltergeist's, glyph and colour vocabulary stays English data, and
Séance's unused `ServerAvatar` is deleted. Prepared from a read-only research pass (devin swe-2-max) over main at 7b41780a; sizes and the `ServerAvatar` and Poltergeist badge-test claims spot-checked.

**Update since the research:** the badge-image encoder (`badge_image.dart`) moved to `ghost_ui` in #99, with flutter_svg and Séance's tests. Read every mention of `badge_image.dart` in `ghost_marks` below as "imported from `ghost_ui`"; `ghost_marks` then needs `ghost_ui` but not flutter_svg directly.

## 1. Inventory

### 1.1 Production files

| Séance file | lines | Poltergeist file | lines | Verdict |
|---|---|---|---|---|
| `seance/app/seance_app/lib/ui/server_appearance.dart` | 1064 | `poltergeist/app/poltergeist_app/lib/ui/server_appearance.dart` | 946 | ~87% line-identical; divergences enumerated below |
| `.../lib/ui/server_mark_picker.dart` | 660 | `.../lib/ui/server_mark_picker.dart` | 670 | structurally identical; strings → ARB in Poltergeist |
| `.../lib/ui/server_color_picker.dart` | 42 | `.../lib/ui/server_color_picker.dart` | 46 | identical logic; ARB title/hint |
| `.../lib/ui/color_picker.dart` | 438 | `.../lib/ui/color_picker.dart` | 447 | identical mechanics; mono font + strings diverge |
| `.../lib/services/badge_image.dart` | 379 | `.../lib/services/badge_image.dart` | 383 | byte-identical except Poltergeist's 2-line provenance header (`badge_image.dart:1-2`); PORTS records "Divergences: none — carried verbatim" (`poltergeist/docs/PORTS.md:917-925`) |

**`server_appearance.dart` section map** (Séance, `seance/app/seance_app/lib/ui/server_appearance.dart`): imports 1-8; `_seeds` table 18-31; `ServerAccent` 36-46; memoized `serverAccent()` derivation 48-120 (named accents via `ColorScheme.fromSeed`, custom via `DynamicSchemeVariant.fidelity`, 64-entry FIFO cap at `:69`); `ServerTint` 122-169 (`named`/`custom`, `none` 143, `of(ServerConfig)` 146-149, `custom(Color)` 153-154, `stored` 158-161); color helpers 171-213 (`formatServerCustomColor` 174, `parseServerCustomColor` 182, `nearestServerColor` 198); `_Glyph{data,label,keywords}` 224-233 + exhaustive `_glyph()` switch 235-490; glyph API 492-523 (`_defaultGlyph` 493, `serverIconData` 496, `serverIconLabel` 500, `serverIconMatches` 506-523); `serverIconGroups` 532-645 (7 headings: Infrastructure, Storage, Services, Building, Access, Places, Marks, compare Poltergeist `server_appearance.dart:566,593,609,619,630`); `serverColorSeed`/`serverColorLabel` 648-653; `ServerAccentBar` 667-706 (`width = 4` at `:686`, `height = ServerBadge.defaultSize` at `:681`); `ServerBadge` 718-850 (`semanticsLabel` 729, `defaultSize = 32` 734, `.glyph` ctor 745, `cornerRatio = 0.28` 755, image/emoji/glyph branches 788-833); `ServerAvatar` 852-949 + `_SessionRing` 950-982; `_EmojiBadgePainter` 983-1064.

Poltergeist's file (`poltergeist/app/poltergeist_app/lib/ui/server_appearance.dart`, 946 lines) is the same map minus the avatar block: `ServerAccentBar` 670-709, `ServerBadge` 721-~863, `_EmojiBadgePainter` 865-946.

**Identical** (verified line-for-line, and recorded as such in `poltergeist/docs/PORTS.md:705-714`): seed values, accent derivation + both caches, `ServerTint` semantics, custom-color format/parse/nearest logic, the whole glyph table incl. keywords, `serverIconGroups`, bar/badge geometry and semantics fallbacks, emoji painter.

**Divergences in `server_appearance.dart`:**
- Séance imports `../app_state.dart` and `../theme.dart` (`server_appearance.dart:6-7`); Poltergeist imports only `flutter/material.dart` + `poltergeist_core` (`server_appearance.dart:1-5`). Both Séance-only imports serve exclusively the avatar tail: `TerminalStatus` at `:869` and `StatusColors.online(context)` at `:964`. **Poltergeist's copy is already host-neutral**, the shared core of this file needs no injection for color/theme at all.
- `ServerAvatar`/`_SessionRing` exist only in Séance (`:852-982`, ~131 lines), keyed on Séance session semantics (`TerminalStatus`, `hasSession`); Poltergeist deliberately does not port them (`PORTS.md:721-724`). Notably they are **dead production code in Séance today**: the only references are the widget itself and its test group (`test/server_appearance_test.dart:77-80,195-340`); the connected ring Séance's list actually draws comes from the shared kit's `SidebarRow.markRing` (`seance/app/seance_app/lib/ui/server_tile.dart:121`; D33 extension recorded `PORTS.md:884`). (Finding: worth deleting or keeping app-side, see §4/§6.)
- Comment naming: `SeanceTheme`/`Séance` vs `Poltergeist` (`seance .../server_appearance.dart:51` vs `poltergeist .../server_appearance.dart:49-50`); Poltergeist adds a provenance header (`:1`) and one doc note about upstream vocabulary on `serverColorLabel` (`:651-652`).

**`server_mark_picker.dart`**, identical structure: `kCuratedServerEmoji` table byte-identical (`seance .../server_mark_picker.dart:16-39` = `poltergeist .../server_mark_picker.dart:21-44`, escapes preserved "for re-diffability" per `PORTS.md:1006-1007`); signature identical (`seance:47-53` / `polt:52-58`, incl. the `@visibleForTesting readImage` seam); `_pickImageBytes` platform/extension gating identical (`seance:75-106`); dialog geometry 460×520 (`seance:130-131`); tab order and `initialIndex` by mark kind (`seance:135-139`); `SelectedTabView` tabs (`seance:151-160`); icons tab search/sectioning (`seance:189-309`); emoji tab normalize-gated commit (`seance:353-358,378-381`); image tab import/encode flow (`seance:473-524`), preview (`seance:540-544`), explanation (`seance:598-609`); `_MarkChoice` badge preview + tooltip/semantics (`seance:617-659`).

Divergences:
- Every user-facing string routes through `l10n.*` in Poltergeist (28 call sites, `poltergeist/.../server_mark_picker.dart:128-616`) vs English literals in Séance (`:122,145-147,170,230,237,242,342-347,386,390,397,416-419,506,515-523,549-550,570,580,601-608`). The ARB catalog exists and is already parameterized: `app_en.arb:7987-8112`, including `{formats}`/`{side}` placeholders (`:8099-8111`) and four platform emoji hints (`:8019-8034`).
- One real copy drift beyond localization: the incompressible-image message. Séance: "Try a simpler picture — a logo rather than a photograph." (`seance .../server_mark_picker.dart:521-523`); Poltergeist ARB: "Try a smaller or simpler one." (`app_en.arb:8067`). Must be reconciled on merge.
- Poltergeist localizes the "Default" section heading (`polt:249` → `l10n.serverMarkPickerDefault`, `app_en.arb:8015`); Séance hard-codes `'Default'` (`seance:242`).
- Imports: `seance_core` vs `poltergeist_core` barrel (`seance:6` / `polt:10`); ARB import (`polt:12`).

**`server_color_picker.dart`**, both are thin wrappers over the generic picker that preview `ServerAccentBar` + `ServerBadge` on `ServerTint(custom: color)` (`seance:20-36` / `polt:27-43`). Divergences: Poltergeist passes `title: l10n.serverColorPickerTitle` (`polt:26`) and `note: l10n.serverColorPickerHint` (`polt:44`); Séance relies on the picker's default title and a literal note (`seance:37-40`). Recorded at `PORTS.md:984-999`.

**`color_picker.dart`**, identical mechanics: HSV hue/saturation/brightness(+alpha) sliders with painted tracks, hex field with `#` prefix and digit filtering, `preview` slot defaulting to `ColorSwatchBox`, `note` line, Cancel/confirm actions (`seance:15-33,141-270`); `ColorSwatchBox` checkerboard swatch (`seance:275-305`); `_CheckerPainter`, `_ChannelSlider` below. Divergences: `title` is a required-in-practice parameter in Poltergeist because copy must come from ARB (recorded `PORTS.md:1846-1847`); the hex field's mono font is `SeanceTheme.monoFallback` (`seance:173-176`) vs `poltergeistMonoTextStyle` (`polt:9`); all labels/errors/semantic announcements are literals in Séance (`'Hex'` 178, `'Six…digits'` 182-184, slider labels 195-229, `'N degrees'/'N percent'` semantic values 202-236, `'Cancel'` 254, `'Use colour'` 265) vs ARB keys `colorPicker*` (`polt:181-263`; ARB `app_en.arb:8117-8174`, already parameterized `{degrees}`/`{percent}`). Both files carry the same dead `theme_palette.dart` import (`seance:5`, `polt:10`, no symbol referenced; drops out on extraction).

**`badge_image.dart`**, identical except the 2-line port header. Public surface: `kBadgeImageSide=256` (`seance .../badge_image.dart:25`), `_sideAttempts [256,192,128,96]` (`:34`), `kBadgeImageExtensions`/`kBadgeImageAppleExtensions` (`:43-52`), `kMaxSvgRasterSide` (`:60`), `kMaxBadgeSourceBytes`/`kMaxBadgeSourcePixels` (`:69,81`), `BadgeImageFailure` (`:84`), `BadgeImage` (`:104`), `encodeBadgeImage` (`:118`), `looksLikeSvg` (`:270`). Deps: `dart:*` + `dart:ui` + `flutter_svg` (`:12-17`).

### 1.2 What is product-specific (stays app-side)

- Séance: `ServerAvatar`/`_SessionRing` (above); `server_tile.dart` (336 lines, `ServerDot` + subtitle/`markRing` composition, `:22,97-121,253-334`); `server_status_dot.dart` (120, dot vocabulary); `server_list_pane.dart` (1123, `ServerTile` at `:584`); `terminal_pane.dart` (1626, accent line `:124`, badge `:168-169`); `header_toolbar.dart` (242, badge `:119-120`); `server_editor.dart` (1291, tint/mark fields `:230-241`, preview `:709-711`, swatches `:751-753,1166-1259`, picker calls `:796,810`, write path `_formConfig` `:907-941`, custom-swatch tooltip `'Custom colour (#…)'` `:1254`); `appearance_settings.dart` (1016, theme editor calling `showColorPicker` `:225`, `ColorSwatchBox` `:752`).
- Poltergeist: `place_glyphs.dart` (91, place/family-hue logic; borrows only `serverIconData` at `:45,49`); `server_editor.dart` (1491, `ServerEditorDelegate` seam, ARB `serverEditor*` keys `:864-942`, picker calls `:952,966`, tooltip key `:1454`); `sidebar_home.dart`/`sidebar_servers_section.dart`/`sidebar_favorites_section.dart` (518/927/575, `part of` sidebar_view, `ServerBadge.glyph`, `serverAccent(...).line`, `FamilyHueTile` fallback, e.g. `sidebar_home.dart:284,359-370`); `workspace_shell.dart` (4848, connect choices `:2609-2627`); `sync_setup_sheet.dart` (1230, badges `:940-952`); `pane_tabs_view.dart` (`:774-778`), `pane_view.dart` (`_LocationGlyph` `:2664-2689`), `quick_open_palette.dart` (`_favoriteBadge` `:709-722`); `settings/appearance_settings.dart` (839, `showColorPicker` `:219,230`).

### 1.3 Tests

- Séance: `server_appearance_test.dart` 850 (groups: `ServerAccentBar` ~`:85`, `ServerBadge` `:138`, `ServerAvatar` `:195-340`, `serverAccent` `:340+`, glyph-table exhaustiveness/labels/search `:756-810`); `server_mark_picker_test.dart` 496 (`readImage` seam `:26,41`); `server_color_picker_test.dart` 167; `color_picker_test.dart` 105; `badge_image_test.dart` 408; `server_tile_test.dart` 592; `server_list_capture_test.dart` 454 (real-font PNG baselines); `server_editor_test.dart` 1798; `server_list_pane_test.dart` 1315.
- Poltergeist: `test/ui/server_appearance_test.dart` 699 (avatar group dropped; two cases adapted to `ServerBadge`, header `:2-6`, `PORTS.md:732-743`); `server_mark_picker_test.dart` 42 (accent-preview regression only, `PORTS.md:1017-1025`); `color_picker_test.dart` 122 + `server_color_picker_test.dart` 173 (wrapped in `AppLocalizations`, `PORTS.md:1889-1891`); `place_glyphs_test.dart` 142; `localization_contract_test.dart` 3141. **No `badge_image_test.dart` exists in Poltergeist**, coverage is Séance-only today; moving it is a net gain.
- Contract-test machinery: scans `Directory('lib')` recursively (`localization_contract_test.dart:3045-3063`); per-file allowlists keyed by `lib/`-relative path (`:17`+); appearance entries at `:2508-2520` (mark picker), `:2527-2545` (appearance), `:1287-1297` (place_glyphs); vocabulary sets `_portedServerIconVocabulary` `:2658` and `_portedCuratedEmojiVocabulary` `:2818`; rationale "upstream English … kept verbatim so the files stay re-diffable" `:2521-2526`.

### 1.4 Shared anchors

- Protocol types: `seance/packages/seance_protocol/lib/src/models/server_mark.dart`, `ServerMark` sealed + `resolve`/`stored` `:18-62`, `kMaxServerIconImageBytes` `:170`, `normalizeServerEmoji` `:248`, `normalizeServerIconImage`/`decodeServerIconImage`/`encodeServerIconImage` `:310/354/413`, `serverIconFromName` `:524`; `server_config.dart`. Barrel exports `server_mark.dart`/`server_config.dart` (`seance_protocol/lib/seance_protocol.dart:15,17`). Protocol stores *names*; the name→pixel mapping is deliberately app-side per its docs and `PORTS.md:711-714` ("identical records draw identical badges in both apps", the design goal).
- Poltergeist's barrel `poltergeist_core.dart:31-136` already re-exports everything the cluster touches: `ServerColor/ServerConfig/ServerIcon` `:73-75`, `ServerMark` + three impls `:79-82`, `normalizeServerEmoji` `:89`, `kMaxServerIconImageBytes` `:96`, `normalizeServerCustomColor`/`normalizeServerGroup` `:130-131`. "Consumers use these types via this barrel, never a direct `package:seance_core/...` import" `:11-14`.
- `import_guard` enforces `dartssh2` confinement to `poltergeist_core` (`poltergeist/tool/import_guard/lib/import_guard.dart:149-156,206-210`), a shared UI package must not dep on `seance_core` (which pulls dartssh2).
- ghost_ui precedent: compat shims `export 'package:ghost_ui/ghost_ui.dart' show …` in both apps (`seance .../ui/selected_tab_view.dart:1`, `middle_ellipsis_text.dart:1`, `sidebar/sidebar_kit.dart`; Poltergeist same). Moves are ledgered: `PORTS.md:46-54` (2026-10-02 ownership), `:1027-1045` (SelectedTabView: "widget and its test now live in ghost_ui … compatibility exports … both app test copies are removed"), `:828-915` (sidebar kit port-out: "imports only Flutter, the chrome tokens … every string arrives through `SidebarKitStrings`; every behavior through callbacks" `:834-839`).
- Strings precedent: `EditorStrings`, a *concrete* class, `const` ctor, English-default getters, parameterized methods (`planchette/packages/planchette_editor/lib/src/editor_strings.dart:6-40`); Poltergeist adapts via `PoltergeistEditorStrings extends EditorStrings` mapping members to `AppLocalizations` (`poltergeist/.../ui/editor_strings.dart:13-60`).

## 2. Package proposal

**Two layers, matching where the boundaries already are:**

1. **New package `ghost_marks`** at `planchette/packages/ghost_marks`, the protocol-typed cluster: appearance module, mark picker, server color picker, badge-image pipeline, strings bag. (Alternative names: `ghost_server_ui`, or folding into `ghost_ui`, rejected, see below.)
2. **`ghost_ui` gains the generic `color_picker.dart`**, it has zero protocol types (`seance .../color_picker.dart:1-33` imports only Flutter + theme), which is exactly ghost_ui's charter ("shared leaf UI widgets/theme tokens … no app or host dependencies", `planchette/AGENTS.md:24-25`).

**`ghost_marks` dependencies:**

```yaml
dependencies:
  flutter: { sdk: flutter }
  ghost_ui:        { path: ../ghost_ui }                    # SelectedTabView, ColorSwatchBox
  seance_protocol: { path: ../../seance/packages/seance_protocol }
  flutter_svg: ^2.3.0   # SVG rasterization in badge_image.dart:17
  file_picker: ^11.0.2  # default readImage in server_mark_picker.dart:84
```

- `seance_protocol`, not `seance_core`: the cluster only uses models (`ServerMark`, `ServerIcon`, `ServerColor`, `ServerConfig`, `normalizeServerEmoji`, `normalizeServerCustomColor`, `kMaxServerIconImageBytes`), all public from the protocol barrel (`seance_protocol/lib/seance_protocol.dart:15,17`). Depending on `seance_core` would pull `dartssh2` into a package Poltergeist consumes, violating the guard (`import_guard.dart:149-156`).
- `file_picker`/`flutter_svg` move with the code that uses them (`server_mark_picker.dart:84-94`, `badge_image.dart:17`); both apps already pin compatible versions (`seance_app/pubspec.yaml:49,77` = `^11.0.2`/`^2.3.0`; `poltergeist_app/pubspec.yaml:24,27` = `11.0.3`/`2.3.0`), so no app gains a plugin it lacked. The AGP-9/Kotlin gotcha already applies to both apps today (`poltergeist/AGENTS.md` §4).

**Why this boundary respects the rules:**
- Root `AGENTS.md`: "shared packages use relative paths" and "shared document/UI packages remain host-neutral", `ghost_marks` gets strings via a bag and theme via ambient `Theme.of(context)` + explicit params, exactly like `SidebarKitStrings`/`_chrome()` (`PORTS.md:834-839`).
- `planchette/AGENTS.md:7-9` designates Planchette "the shared editor foundation for Séance and Poltergeist"; both apps already path-dep into `planchette/packages/` (`seance_app/pubspec.yaml:11-18`; `poltergeist_app/pubspec.yaml:14-15,44-48`). A Flutter package stays outside the pure-Dart workspace per `planchette/AGENTS.md:20-28`.
- The "Poltergeist consumes Séance code only through its core barrel" rule (root AGENTS) and the barrel comment (`poltergeist_core.dart:11-14`) govern *type* imports of `seance_*` packages. `ghost_marks` is a `package:ghost_marks` import, same class as `ghost_ui`, and internally it consumes `seance_protocol`, exactly as `poltergeist_core` does (`poltergeist/packages/poltergeist_core/pubspec.yaml:17-24`). Poltergeist app code still never imports `package:seance_*`; the `ServerMark` values it passes come from the barrel and are the same class objects since both resolve to the same on-disk package.
- Rejected: putting the cluster **inside `ghost_ui`** would give the protocol-agnostic leaf a `seance_protocol`+`flutter_svg`+`file_picker` dep that Planchette-the-editor also inherits; rejected: `seance/packages/` location would create Poltergeist's first direct `seance/*` app-level dependency (today it reaches Séance only via `poltergeist_core`), weakening the pin/audit boundary (`PORTS.md:1900-1923`).

## 3. String injection

Follow `EditorStrings`: concrete classes with `const` constructors and English defaults equal to Séance's current literals; hosts subclass. Glyph/color **vocabulary is not injected**, `serverIconLabel`/`serverColorLabel` outputs, `_Glyph.keywords`, `serverIconGroups` headings, and the `'default server'` haystack stay English *data* in the package, preserving Poltergeist's documented posture (`PORTS.md:724-728`: "glyph vocabulary, not product copy"; contract test `:2521-2526`). What *is* injected is dialog chrome + prose. Owner decision flagged: the icons-tab "Default" *heading* is already localized in Poltergeist (`app_en.arb:8015`), so the bag includes it while `serverIconLabel(null)`'s `'Default'` stays vocabulary.

**`ServerAppearanceStrings`** (in `ghost_marks`; defaults = Séance's literals, ARB key = Poltergeist's existing key):

| Member | Default | ARB key |
|---|---|---|
| `markPickerTitle` | `'Server mark'` | `serverMarkPickerTitle` (`app_en.arb:7987`) |
| `iconsTab` / `emojiTab` / `imageTab` | `'Icons'`/`'Emoji'`/`'Image'` | `:7991-8000` |
| `markPickerCancel` | `'Cancel'` | `:8003` |
| `iconSearchHint` | `'Search icons — try k8s, psql, prod…'` | `:8007` |
| `iconSearchEmpty` | `'No icon matches.'` | `:8011` |
| `defaultMarkHeading` | `'Default'` | `:8015` |
| `emojiShortcutHintMacOS`/`Windows`/`Linux`/`Other` | `server_mark_picker.dart:342-347` verbatim | `:8019-8033` |
| `emojiFieldLabel` / `emojiFieldError` / `emojiUse` | `'Any emoji'`/`'One emoji, please.'`/`'Use'` | `:8035-8045` |
| `emojiFontNote` | `server_mark_picker.dart:416-419` verbatim | `:8047` |
| `imageAbsent` / `imagePresent` | `'No image on this server yet.'`/`'This server carries an image.'` | `:8071-8077` |
| `imageChoose` / `imageReplace` / `imageRemove` | `'Choose image…'`/`'Replace image…'`/`'Remove image'` | `:8079-8089` |
| `imageOpenFailed` | `'That file could not be opened. Try another.'` | `:8051` |
| `imageFailure(BadgeImageFailure)` → 4-way | `server_mark_picker.dart:515-523` verbatim | `:8055-8067` (reconcile `incompressible` drift, recommend Séance's wording as upstream source) |
| `imageFormatsDesktop` / `imageFormatsIos` | `'PNG, JPEG, WebP or SVG'`/`'PNG, JPEG or WebP'` | `:8091-8095` |
| `imageExplanation(String formats, int side)` | interpolated `server_mark_picker.dart:601-608` | `:8099` (placeholders `{formats}`,`{side}` already exist) |
| `serverColorTitle` / `serverColorHint` | `'Custom colour'` / `server_color_picker.dart:37-40` verbatim | `serverColorPickerTitle`/`serverColorPickerHint` (`:8113,8157`) |

**`ColorPickerStrings`** (in `ghost_ui`): `hexLabel`, `hexError`, `hexErrorAlpha`, `hue`/`saturation`/`brightness`/`opacity`, `degrees(int)`, `percent(int)`, `cancel`, `use`, mapping `colorPicker*` ARB keys (`app_en.arb:8117-8174`). `showColorPicker`'s `title`/`note` remain parameters (Poltergeist already passes localized values, `server_color_picker.dart:26,44`, `appearance_settings.dart:219-230`); the mono hex font becomes a `TextStyle? hexStyle` parameter, Séance passes `SeanceTheme.monoFallback`-derived style (`color_picker.dart:173-176`), Poltergeist `poltergeistMonoTextStyle` (`color_picker.dart:9`).

**Supply:**
- Séance: nothing, the defaults are its literals verbatim, so its compat shims are pure `export`s. (If it ever wants overrides it gets a `SeanceServerAppearanceStrings` the same way.)
- Poltergeist: `lib/ui/server_appearance_strings.dart` holding `PoltergeistServerAppearanceStrings extends ServerAppearanceStrings` + `PoltergeistColorPickerStrings extends ColorPickerStrings`, mapped to `AppLocalizations`, the `PoltergeistEditorStrings` shape (`editor_strings.dart:13-15`). The three picker files become thin wrappers that call `AppLocalizations.of(context)` and pass `strings:`, preserving today's call sites (`server_editor.dart:952,966`, `appearance_settings.dart:219,230`) and keeping every picker invocation localized.
- Contract test: once the files leave `lib/`, their allowlist entries (`localization_contract_test.dart:2508-2520,2527-2545`) become dead keys, remove them in the same PR; the scanner only walks `Directory('lib')` (`:3047`), so shared-package literals are out of scope by construction and enforcement moves to the adapter. Verify no companion assertion requires allowlist keys to name existing files.

## 4. Public API

`ghost_marks` barrel exports: `ServerAccent`, `ServerTint` (+`none`,`of`,`custom`,`stored`), `serverAccent`, `ServerAccentBar`, `ServerBadge` (+`.glyph`, `defaultSize=32`, `cornerRatio=0.28`, `semanticsLabel`, `size`), `serverIconData`, `serverIconLabel`, `serverIconMatches`, `serverIconGroups`, `serverColorSeed`, `serverColorLabel`, `formatServerCustomColor`, `parseServerCustomColor`, `nearestServerColor`, `kCuratedServerEmoji`, `ServerAppearanceStrings`, `showServerMarkPicker(context,{required current, required accent, strings=const ServerAppearanceStrings(), @visibleForTesting readImage})`, `showServerColorPicker(context,{required initial, required mark, strings})`, and the badge-image surface (`kBadgeImageSide`, `kBadgeImageExtensions`, `kBadgeImageAppleExtensions`, `kMaxSvgRasterSide`, `kMaxBadgeSourceBytes`, `kMaxBadgeSourcePixels`, `BadgeImage`, `BadgeImageFailure`, `encodeBadgeImage`, `looksLikeSvg`). `ghost_ui` adds `showColorPicker` (+`hexStyle`, `strings` params) and `ColorSwatchBox`.

Defaults unchanged: bar `height=ServerBadge.defaultSize`,`width=4` (`server_appearance.dart:681,686`); badge `size=32`, `cornerRatio=0.28`; picker dialog 460×520; `readImage` defaults to the `file_picker` implementation inside the package (`server_mark_picker.dart:75-106`).

App-side (unchanged): `ServerAvatar`/`_SessionRing` (recommend deletion, dead, superseded by `SidebarRow.markRing`, `server_tile.dart:121`; alternatively move to `server_avatar.dart`), `ServerDot`/`server_status_dot.dart`, `server_tile.dart`, list/terminal/toolbar chrome, both server editors' forms and swatch tooltips, `place_glyphs.dart`, both `appearance_settings.dart` files, all themes (`monoFallback`/`poltergeistMonoTextStyle` injected via `hexStyle`).

## 5. Migration plan (one monorepo, staged PRs)

- **PR 1, `ghost_ui` color picker.** Port `color_picker.dart` into `ghost_ui` with `ColorPickerStrings` + `hexStyle`; move `seance/.../test/color_picker_test.dart` (105) into the package; Séance's file → `export` shim; Poltergeist's → l10n wrapper + adapter members. Update `PORTS.md:1841-1851` and `:1889-1891` to "Moved" wording modeled on `:1041-1045`. Risk: low (visual only via `hexStyle`).
- **PR 2, `ghost_marks` core.** Create package; move `server_appearance.dart` shared sections (Séance `1-850` + painter `983-1064`), `badge_image.dart`, and the appearance/badge/glyph-table tests (Séance `server_appearance_test.dart` minus the `ServerAvatar` group `:195-340`, `badge_image_test.dart` 408). Séance's file → compat export + decision on avatar (delete recommended; if retained, `server_avatar.dart` app-side). Poltergeist's → pure export. `PORTS.md:697-730,732-743,917-925` updated; add `ghost_marks` to the "Shared Ghost UI ownership" note `:46-54`. Risks: accent/badge pixel regressions, run Séance `server_list_capture_test.dart` (454, real-font baselines) before/after; exhaustiveness test `:756-768` moves with the table.
- **PR 3, pickers + strings.** Move `server_mark_picker.dart` + `server_color_picker.dart` and `ServerAppearanceStrings` into `ghost_marks`; move Séance's picker tests (496+167); Poltergeist wrappers + `PoltergeistServerAppearanceStrings`; reconcile the `incompressible` wording (`seance:521-523` vs `app_en.arb:8067`); drop dead contract-test allowlist entries and `theme_palette.dart` imports. Poltergeist gains `badge_image` coverage it lacks. `PORTS.md:984-999,1001-1015,1017-1025` updated; barrel comment at `poltergeist_core.dart:76-82` re-worded ("shared `ghost_marks` package", not "ported").
- **PR 4, audit & cleanup.** Regenerate the Séance source audit (`PORTS.md:1900-1923`): `seance/` stays at `HEAD`, but `ghost_marks` is a new path consumer of `seance_protocol`, record it, confirm no `seance_core`/`dartssh2` edge (`import_guard` stays green). Optionally delete `ServerAvatar` and its test group here if not done in PR 2.

## 6. Estimates and recommendation

- **Moved to packages:** ~2,450 production lines (appearance shared part ~933 = Séance 1064 − avatar/ring 131; mark picker ~660; server color picker ~42; generic picker ~438; badge image ~379) + ~120-160 new `ServerAppearanceStrings`/`ColorPickerStrings`.
- **Removed:** Séance ~2,420 (→ ~60 of compat exports; −131 more if `ServerAvatar` is deleted, plus ~150 test lines). Poltergeist ~2,480 (→ ~130 of wrappers + ~80 adapter). Tests: ~2,460 moved/deleted (Séance 2,026 moved; Poltergeist 1,036 deleted as package superset, per the `middle_ellipsis` precedent `PORTS.md:823-826`); Séance keeps tile/editor/capture suites (~3,400) app-side.
- **Net:** ~4,900 duplicated lines collapse to ~2,500 owned once.

**Recommendation: extract, but as the two-layer split above, not all, not none.** The five files are 90-100% identical and every divergence already has a sanctioned seam (string bags, `hexStyle` param, the `readImage` test seam); the protocol-typed parts genuinely cannot diverge without breaking "identical records draw identical badges" (`PORTS.md:712-714`). Exclude: `ServerAvatar`/`_SessionRing` (dead upstream, delete or keep app-side), `place_glyphs.dart` (one borrowed function, `place_glyphs.dart:45,49`), editors/sidebar/chrome/themes (product UI). Open questions for the owner: the `incompressible` wording reconciliation, whether glyph vocabulary ever localizes (today's ledgered answer is no), and `ServerAvatar`'s fate.
