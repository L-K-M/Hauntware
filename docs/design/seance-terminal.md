# Shared package design: `seance_terminal`

Scope: Klabautermann v1 extraction row F5c (03-ARCHITECTURE.md D11 and the
section 3.5 table, 03:1833; 04-IMPLEMENTATION.md "F5"). New Flutter package
`seance/packages/seance_terminal` that Séance and Klabautermann share for
interactive shells: Séance's `XtermTerminalEngine`, the on-screen terminal
keyboard bar and the terminal appearance mapping move into it with Séance
switched, and two new seams let Klabautermann's container shells (CTX-07)
use it without importing `seance_core`: a byte transport session and a
paste policy. Search and the find bar stay in Séance (1.6). CTX-08
(one-off command) shows output and an exit code and uses no terminal.
Dependencies: Flutter, the vendored `seance/third_party/xterm`,
`seance_core` (barrel only), and from F5c-2a `ghost_fonts`, `ghost_theme`
and `ghost_ui`. No `dartssh2` import, no `seance_protocol` import.

Status: proposed for the Klabautermann v1 extractions (F5c); approval under the owner's instruction of 2026-10-13 to implement the plan (`docs/design/klabautermann/06-EXECUTION.md:13-14`).

Main commit read: `11ee9db7`.

## 1. Inventory

`SA` = `seance/app/seance_app`, `SC` = `seance/packages/seance_core`,
`KA` = `klabautermann/app/klabautermann_app`, `XT` =
`seance/third_party/xterm`.

### 1.1 Production files

| File | Lines | Contents |
|---|---|---|
| `SA/lib/services/xterm_engine.dart` | 475 | `TerminalCursorKey` (:8-18), `TerminalPromptPhase` (:20), `TerminalStageResult` (:22-28), `ShellIntegrationState` (:30-56), `XtermTerminalEngine implements TerminalEngine` (:62-461): constructor and `onOutput` wiring (:140-164), OSC 7/133/1337 handling (:166-246), one-shot Ctrl (:251-272, :381-385), pending-input tracking (:274-319), `injectInput` (:324-329), `sendKey` (:334-339), `sendCursorKey` (:342-349), `stageChangeDirectory` (:352-371), `feed` (:387-400), `size`/`resize` bookkeeping (:405-417), `recentText` (:428-442), idempotent `dispose` (:446-460); `_TerminalOutputSink` (:463-475) |
| `SA/lib/ui/terminal_keyboard_bar.dart` | 202 | `TerminalKeyboardBar({required XtermTerminalEngine engine})` (:16-147): byte constants (:20-24), 16 keys plus "hide keyboard" (:47-89), mono key caps through `SeanceTheme.mono` (:102, :117, :123, :138), sticky Ctrl (:127-146); `_KeyButton` (:150-202). 17 English semantics labels and tooltips |
| `SA/lib/ui/terminal_appearance.dart` | 249 | Re-export of xterm's `TerminalLigatures` (:14), `TerminalPalette` (:17-23), font-size limits and `clampTerminalFontSize` (:27-35), `SeanceTerminalThemes` dark/light/`builtIn`/`fromColors`/`toColors` (:40-170), `kDefaultTerminalFont` (:175), `TerminalAppearance` with `resolve(AppSettings, Brightness)` (:195-205), `of(...)` (:210-243) and `brightness` (:247-248) |
| `SA/lib/services/terminal_search.dart` | 720 | `TerminalBufferScan`, `TerminalSearchSession`, `TerminalSearchViewport` (:19-720). Imports only `dart:*`, Flutter and xterm (:1-7). Stays, 1.6 |
| `SA/lib/ui/terminal_find_bar.dart` | 272 | `TerminalFindBar`, `TerminalFindBarOverlay`, `TerminalViewSearchViewport` (:21-272); imports `../services/terminal_search.dart` and `../theme.dart` (:7-8) for `SeanceChrome.of(context, seanceThemeStyle)` (:84). Stays, 1.6 |
| `SA/lib/ui/terminal_pane.dart` | 1,791 | Mounts the keyboard bar (:135-136), resolves the appearance (:1189-1192, :1328-1331), builds `TerminalView` with `shortcuts: const {}` (:1230-1250), routes Ctrl/Cmd-V to `terminalPaste` (:1430-1432). Stays |
| `SA/lib/ui/app_menus.dart` | n/a | `terminalPaste` (:99-105): clipboard text straight to `tab.engine.terminal.paste(text)`. Stays |
| `SC/lib/src/terminal/terminal_engine.dart` | 80 | `TerminalSize` (:5-17), `TerminalEngine` (:26-32), `HeadlessTerminalEngine` (:37-80) |
| `SC/lib/src/terminal/session_transport.dart` | 31 | `SessionTransport` (:16-31); ownership rule "close disposes the engine" (:12-15) |
| `SC/lib/src/terminal/paste_sanitizer.dart` | 50 | `UnsafePasteException` (:2-7), `PasteSanitizer.sanitize` (refuses CR/LF, :19-27), `sanitizeFirstLine` (:32-35), private `_stripControlChars` (C0 except tab, DEL; :37-49) |
| `SC/lib/src/terminal/shell_command.dart` | 72 | `RemoteShellKind` (:2-8), `buildChangeDirectoryCommand` (:18-47) |

`SC/lib/seance_core.dart:13-17` exports all five terminal files.

### 1.2 Imports of the moving files

| File | Import | Symbols used | Kind |
|---|---|---|---|
| `xterm_engine.dart` | `package:seance_core/seance_core.dart` (:5) | `TerminalEngine` (:62), `TerminalSize` (:67, :142, :145, :406, :409), `RemoteShellKind` (:32, :45, :239-240), `buildChangeDirectoryCommand` (:365) | `seance_core` barrel |
| | `package:xterm/xterm.dart` (:6) | `Terminal`, `TerminalTargetPlatform`, `BufferRangeLine`, `CellOffset` | vendored |
| `terminal_keyboard_bar.dart` | `../services/xterm_engine.dart` (:5) | `XtermTerminalEngine`, `TerminalCursorKey` | moves in F5c-1 |
| | `../theme.dart` (:6) | `SeanceTheme.mono` = `TextStyle(fontFamily: ghostMonoFontFamily, fontFamilyFallback: ghostMonoFontFamilies)` (`SA/lib/theme.dart:78-87`) | app-only |
| `terminal_appearance.dart` | `package:ghost_fonts/ghost_fonts.dart` (:4) | `BundledMonoFont`, `resolveMonoFamily`, `MonoLigatures` | shared |
| | `package:xterm/xterm.dart` (:5-6) | `TerminalLigatures`, `TerminalStyle`, `TerminalTheme` | vendored |
| | `../services/app_settings.dart` (:8) | `AppSettings`, only in `resolve` (:195-205) and doc comments | app-only |
| | `../theme.dart` (:9) | `SeanceTheme.monoFallback` (:221) = `ghostMonoFontFamilies` (`SA/lib/theme.dart:78`) | app-only |
| | `../theme/contrast.dart` (:10) | `contrastRatio` (:112); the file is a shim over `ghost_ui` (`SA/lib/theme/contrast.dart:1-2`) | shim |
| | `../theme/theme_palette.dart` (:11) | `ThemeTerminalColors` (:108, :145, :215); a shim over `ghost_theme` (`SA/lib/theme/theme_palette.dart:6-11`) | shim |

None of the moving files imports `dartssh2`, `seance_protocol` or a
`package:seance_core/src/` path.

### 1.3 How bytes reach the engine today

The engine never sees a transport. Séance's two transports, in
`seance_core`, wire it themselves: `SshSession implements SessionTransport`
(`SC/lib/src/ssh/ssh_session.dart:673`) pipes stdout and stderr into
`engine.feed` and `engine.userInput` into the shell (`:707-729`), and its
`resize` calls `engine.resize` then `shell.resizeTerminal(cols, rows)`
(`:805-808`). `LocalShellSession` does the same over a pty
(`SC/lib/src/terminal/local_shell.dart:228, :296-310, :323-326`). The app
forwards the widget's size: `engine.terminal.onResize = (w, h, pw, ph) =>
session.resize(TerminalSize(w, h))` (`SA/lib/app_state.dart:1465-1467,
:1595-1597`). `engine.resize` is bookkeeping only, because the xterm
widget owns the grid size (`xterm_engine.dart:409-417`). The app holds
the engine and the transport side by side (`SA/lib/app_state.dart:141-142`).

`seance_core` is pure Dart (`tool/guards.yaml:39-42`), so it cannot depend
on a Flutter package; Séance's transports stay where they are.

### 1.4 How paste works today

- Clipboard paste in a Séance shell (menu, context menu, touch toolbar,
  Ctrl/Cmd-V) goes through `terminalPaste`, which calls
  `terminal.paste(text)` unchanged (`SA/lib/ui/app_menus.dart:99-105`).
  xterm wraps it in `ESC[200~ ... ESC[201~` when the shell enabled
  bracketed paste and sends it raw otherwise (`XT/lib/src/terminal.dart:336-342`,
  `XT/lib/src/core/escape/emitter.dart:28-30`). Neither the sanitizer nor
  the danger linter runs.
- `PasteSanitizer.sanitize` guards text the app injects: snippets
  (`SA/lib/ui/snippets_pane.dart:169`), the command generator
  (`SA/lib/ui/command_generator.dart:98`) and inbox proposals
  (`SA/lib/app_state.dart:3003`).
- `DangerLinter` runs on assistant suggestions
  (`SA/lib/ui/chat_sidebar.dart:308`) and inbox scripts
  (`SA/lib/ui/inbox_view.dart:284`), and in Klabautermann's engine on
  plan steps (`klabautermann/packages/klabautermann_core/lib/src/operations/danger.dart:5-18`),
  whose findings cross the isolate as plain data
  (`.../engine/protocol.dart:46`).
- xterm's default shortcut layer pastes the clipboard directly
  (`XT/lib/src/ui/shortcut/actions.dart:25-30`); Séance turns it off
  (`terminal_pane.dart:1247`).

### 1.5 The vendored xterm package

`XT` is Séance's fork of xterm.dart 4.0.0 (`XT/pubspec.yaml`, version
`4.0.0+seance.1`), with every divergence listed in `XT/PATCHES.md` (542
lines) and about 15,100 library lines. Séance depends on it by path
(`SA/pubspec.yaml`, `xterm: path: ../../third_party/xterm`). It is not an
owned pubspec (`tool/release_version/test/release_script_test.dart:128`)
and its tests run in their own steps (`.github/workflows/ci.yml:1370-1376`,
`scripts/test.sh:201`). It does not move and is not edited.

### 1.6 What stays in Séance

- `terminal_pane.dart`, `app_menus.dart` and the session model: tabs,
  status, reconnect, Files and Git, the assistant context.
- Search and the find bar. CTX-07 asks for shell, user and resize only
  (02:847); Klabautermann's log viewer already has Planchette's search
  (`KA/pubspec.yaml`, `planchette_core` comment). `terminal_search.dart`
  could move byte-identical later; `terminal_find_bar.dart` would first
  need its `SeanceChrome`/`seanceThemeStyle` reach (:84) replaced by an
  injected corner radius.
- `SshSession`, `LocalShellSession`, `PasteSanitizer` and the local shell
  stay in `seance_core`.

### 1.7 Tests and pixel baselines

| Test | Lines | Fate |
|---|---|---|
| `SA/test/xterm_engine_test.dart` | 448 | Moves in F5c-1; import `:5` repointed |
| `SA/test/terminal_keyboard_bar_test.dart` | 154 | Moves in F5c-2a; imports `:7-8` repointed |
| `SA/test/terminal_appearance_test.dart` | 353 | Stays: every case goes through `resolve(AppSettings, ...)` or settings JSON (:17-353), so it proves the Séance switch |
| `SA/test/terminal_ligatures_test.dart` | 115 | Stays (uses `resolve`, :8-9) |
| `SA/test/terminal_find_bar_test.dart`, `terminal_search_test.dart` | 267, 298 | Stay |

28 test files and 5 `lib/` files import `services/xterm_engine.dart`; 7
`lib/` files and 5 tests import `ui/terminal_appearance.dart`; only
`terminal_pane.dart` and its test import the keyboard bar.

Pixel baselines (03 D3, 03:286-296): Séance's real-font captures run
with `SEANCE_CAPTURE=1` and `SEANCE_CAPTURE_FONT_DIR`. Five capture suites
exist; two construct an `XtermTerminalEngine` for tab models
(`SA/test/family_hues_capture_test.dart:215`,
`SA/test/server_list_capture_test.dart:201`), but none renders a
`TerminalView`, the keyboard bar or a terminal palette. So no capture
covers what moves. F5c-1 adds one (9.2).

### 1.8 What blocks a byte-identical move, and the minimal seam

| File | Blocker | Minimal seam |
|---|---|---|
| `xterm_engine.dart` | None. Both imports resolve from a package that depends on `seance_core` and `xterm` | Byte-identical move; export shim at the old path |
| `xterm_engine_test.dart` | `package:seance_app/...` import | Repoint one import line |
| `terminal_keyboard_bar.dart` | Relative engine import; `SeanceTheme.mono` (4 uses); English labels Klabautermann must localize (03 §10.10, 03:6820-6822) | Package-relative import; a private `const` `TextStyle` with the same two `ghost_fonts` values; an optional strings bag whose defaults are today's literals (4) |
| `terminal_appearance.dart` | `resolve` takes `AppSettings`, and `app_settings.dart` imports this file back (`SA/lib/services/app_settings.dart:15`); `SeanceTheme.monoFallback`; two app shims | `resolve` stays in Séance as `resolveTerminalAppearance(AppSettings, Brightness)`; `ghostMonoFontFamilies`, `contrastRatio` and `ThemeTerminalColors` imported from the ghost packages they already come from; doc comments that name `AppSettings` reworded |
| Klabautermann use of any of it | The app may not import `seance_core` (`KA/test/architecture_contract_test.dart:11-16`), and nothing of 1.3 exists outside `seance_core` | The byte session and the paste policy (3.2, 3.3), new code |

## 2. Package proposal

- Path `seance/packages/seance_terminal`, Flutter, version at the suite
  version (1.9.2 today), `publish_to: none`. Not a member of the pure-Dart
  Séance workspace (`seance/pubspec.yaml`); it resolves standalone like the
  app, and its `pubspec.lock` is committed because it declares a Séance
  path package (`tool/license_gate/lib/license_gate.dart:556-608`).
- Dependencies: `flutter`; `seance_core: path: ../seance_core`;
  `xterm: path: ../../third_party/xterm`; from F5c-2a `ghost_fonts`,
  `ghost_theme`, `ghost_ui` at `../../../planchette/packages/...`. Dev:
  `flutter_test`, `flutter_lints: ^5.0.0`. `analysis_options.yaml` copies
  Séance's (`flutter_lints` plus `prefer_final_locals`), so the moved files
  analyze as they do now.
- The guards stay as they are: `seance.pure_packages` lists only the three
  pure packages (`tool/guards.yaml:39-42`), the scan already covers
  `packages/` (:38), and the `ghost_*` rule (:76) forbids only ghost
  packages depending on `seance_core`, not the reverse.
- The license gate already treats any `seance_*` name and any path under
  `seance/` as Séance (`license_gate.dart:33, :372-391, :1027-1029`); no
  gate change.
- 03 §3.2's graph has `ST --> SC` and `ST --> XT` (03:1606-1607).
  F5c-2a adds `ST --> GUI`, `ST --> GT` and an edge to `ghost_fonts`;
  Klabautermann's app already depends on all three, so no package enters
  its closure through them. F5c-2a records the edges in 03.

## 3. Seams (the `seance_core` boundary)

### 3.1 Engine

`XtermTerminalEngine` is the view seam. It keeps implementing
`seance_core`'s `TerminalEngine`, so Séance's transports take it unchanged.
Klabautermann uses the concrete class: it builds one, hands
`engine.terminal` to xterm's `TerminalView`, and never calls `resize` or
reads `TerminalSize` itself. No separate engine interface is added; a
second interface with one implementation would only forward calls.

Signatures still mention `seance_core` types (`TerminalEngine`,
`TerminalSize`, `RemoteShellKind`). The barrel does not export them, so
app code cannot name or construct them without importing `seance_core`,
which the contract test already forbids. The constructor's one such
parameter, `initialSize`, is optional (`xterm_engine.dart:140-145`), so
Klabautermann builds the engine as `XtermTerminalEngine()` and lets the
first `onResize` size it. That is the boundary P4 asks
for; 3.4 makes it checked.

### 3.2 Byte transport session

```dart
/// Bytes to and from one far end (a container exec stream), with no SSH
/// or Docker type. Rows and columns are named because Docker's resize
/// takes rows first (03 c2 R15, 03:2719).
abstract interface class TerminalByteTransport {
  /// Far end to terminal. Done when the far end ends.
  Stream<Uint8List> get output;
  void write(Uint8List bytes);
  void resize({required int columns, required int rows});
  /// Idempotent.
  Future<void> close();
}

/// Wires an engine to a byte transport the way SshSession wires a shell
/// (ssh_session.dart:707-729, :805-808), under SessionTransport's
/// ownership rule: close disposes the engine.
final class TerminalByteSession implements SessionTransport {
  TerminalByteSession({
    required XtermTerminalEngine engine,
    required TerminalByteTransport transport,
  });
}
```

Behaviour: `output` feeds `engine.feed`; `engine.userInput` goes to
`write` while open; it sets `engine.terminal.onResize` to
`engine.resize(TerminalSize(w, h))` plus `resize(columns: w, rows: h)`,
as `app_state.dart:1465-1467` does for Séance; `output` ending fires
`onClosed` once, also when assigned late (as `ssh_session.dart:694-698`),
and cancels the input subscription, so nothing more is written; an
`output` error tears down as `close()` does and fires `onClosed` once,
and never escapes the subscription; `close()` cancels the subscriptions,
closes the transport and disposes the engine, once. Input after the
session closed is dropped, never written to the transport. Implementing `SessionTransport` is what 03 §7.13 names
("through a new `SessionTransport`", 03:3749-3750); the interface name is
not exported.

Séance does not adopt it: its transports live in `seance_core` and own
their wiring (1.3). Klabautermann's adapter (M12) implements
`TerminalByteTransport` over the engine client: `TerminalBytes` in,
`TerminalInput`, `TerminalResize` and `CloseTerminal` out, `TerminalClosed`
ending `output`. Today's protocol has only `OpenTerminal(serverId,
containerId, shell)`, `TerminalBytes` and `TerminalClosed`
(`klabautermann/packages/klabautermann_core/lib/src/engine/protocol.dart:610-618,
:1631-1645`); M11a adds the rest.

### 3.3 Paste policy

```dart
enum TerminalPasteSeverity { warning, critical }

@immutable
final class TerminalPasteFinding {
  const TerminalPasteFinding({
    required this.severity,
    required this.line,
    required this.explanation,
  });
  final TerminalPasteSeverity severity;
  final int line;
  final String explanation;
}

@immutable
final class TerminalPasteReview {
  final String text;
  final int lineCount;
  /// Null when the inspector failed: unknown, not clean.
  final List<TerminalPasteFinding>? findings;
}

enum TerminalPasteChoice { pasteAll, firstLineOnly, cancel }

final class TerminalPastePolicy {
  const TerminalPastePolicy({required this.inspect, required this.confirm});
  /// Lints multi-line text. Klabautermann fills it from the engine.
  final Future<List<TerminalPasteFinding>> Function(String text) inspect;
  /// Asks the user; called only for a multi-line paste with findings, or
  /// when [inspect] failed.
  final Future<TerminalPasteChoice> Function(TerminalPasteReview review)
      confirm;
  Future<void> paste(XtermTerminalEngine engine, String text);
}
```

Rules, in order:

1. Empty text pastes nothing.
2. Text without CR or LF goes through `PasteSanitizer.sanitize` (controls
   other than tab removed) and `engine.terminal.paste`. It is not linted:
   a line with no line break never runs without the user's Enter, the
   sanitizer's own rule (`paste_sanitizer.dart:9-15`).
3. Text with a line break is linted with `inspect`. Lines are split at
   `\r\n`, `\r` and `\n`, the split `sanitizeFirstLine` already uses
   (`paste_sanitizer.dart:33`), so no line reaches `sanitize` with a CR.
   No findings: every line goes through `PasteSanitizer.sanitize`, the
   lines are joined with `\n`, and the result is pasted. Findings, or an `inspect` error: the
   policy calls `confirm`; `pasteAll` pastes as above, `firstLineOnly`
   pastes `PasteSanitizer.sanitizeFirstLine(text)`, `cancel` pastes
   nothing.

Sanitizing per line removes ESC, so pasted text cannot end bracketed
paste early. Joining with `\n` matches what Séance's raw paste sends for
LF text today [guess: no shell in the container images needs CR].
The policy re-exports no `seance_core` type: `UnsafePasteException`
cannot occur, because `sanitize` only ever sees single lines.

Séance does not adopt the policy in M5. Its raw clipboard paste is
shipped behaviour (1.4), and D3 puts behaviour changes in their own PRs.

The policy covers only paste paths the host routes through it. xterm's
default shortcut paste must stay off, as in Séance (1.4), and a phone's
own paste in the soft keyboard reaches xterm as text input that no policy
sees [guess]. M12's tests cover the menu, context-menu and shortcut
paths.

### 3.4 Contract test

`KA/test/architecture_contract_test.dart` gains, in F5c-2b:

- `seance_terminal` stays outside `_forbiddenPackages` (:11-16), and app
  files may import it only as `package:seance_terminal/seance_terminal.dart`
  (no `src/`).
- Every `export` in `seance/packages/seance_terminal/lib/**` names no
  `seance_core`, `seance_protocol` or `dartssh2` URI.
- Every barrel export has a `show` list, and no shown name is declared at
  top level in `seance/packages/seance_core/lib` or
  `seance/packages/seance_protocol/lib` (regex over `class`, `enum`,
  `mixin`, `typedef`, `extension`, `extension type`, top-level
  functions, and top-level variables, constants and getters). None of
  the names in 5 collides today (checked at `11ee9db7`, and for the
  wider set at `cc65864b`).

The test reads the barrel by its monorepo path, so it runs before the
app depends on the package (M12).

## 4. Strings

`TerminalKeyboardBarStrings`, a const class with English defaults equal
to today's 17 literals (`terminal_keyboard_bar.dart:48-88, :133`):
`escape`, `tab`, `controlModifier`, `controlC`, `leftArrow`, `upArrow`,
`downArrow`, `rightArrow`, `home`, `end`, `pageUp`, `pageDown`, `pipe`,
`slash`, `hyphen`, `tilde`, `hideKeyboard`. The cap legends (`esc`,
`ctrl`, `^C`, `pgup`, `|`, ...) are key names and stay literal. Séance
passes nothing; Klabautermann's ARB adapter follows 03 §10.10's one
adapter per bag (M12). The paste policy has no strings: the host's
`confirm` words the question. The appearance mapping has none.

## 5. Public API

```dart
// seance/packages/seance_terminal/lib/seance_terminal.dart
export 'src/xterm_engine.dart'
    show
        ShellIntegrationState,
        TerminalCursorKey,
        TerminalPromptPhase,
        TerminalStageResult,
        XtermTerminalEngine;
// F5c-2a
export 'src/terminal_keyboard_bar.dart'
    show TerminalKeyboardBar, TerminalKeyboardBarStrings;
export 'src/terminal_appearance.dart'
    show
        SeanceTerminalThemes,
        TerminalAppearance,
        TerminalPalette,
        clampTerminalFontSize,
        kDefaultTerminalFont,
        kDefaultTerminalFontSize,
        kMaxTerminalFontSize,
        kMinTerminalFontSize,
        kTerminalFontSizeStep;
export 'package:xterm/xterm.dart'
    show
        TerminalController,
        TerminalLigatures,
        TerminalStyle,
        TerminalTheme,
        TerminalView;
// F5c-2b
export 'src/byte_session.dart'
    show TerminalByteSession, TerminalByteTransport;
export 'src/paste_policy.dart'
    show
        TerminalPasteChoice,
        TerminalPasteFinding,
        TerminalPastePolicy,
        TerminalPasteReview,
        TerminalPasteSeverity;
```

`TerminalLigatures` moves from the appearance file's own re-export (:14)
to the barrel. The xterm view names let Klabautermann host the view
without declaring the fork itself. `TerminalPalette` and
`TerminalLigatures` keep their value names, which Séance stores in
settings by `.name` (`SA/lib/services/app_settings.dart:406-407`).

## 6. Per-app adapters

Séance, after F5c-2a:

- `SA/lib/services/xterm_engine.dart` becomes an export shim with the
  five engine names, so its 33 importers do not change.
- `SA/lib/ui/terminal_keyboard_bar.dart` is deleted; `terminal_pane.dart`
  imports the barrel (one site).
- `SA/lib/ui/terminal_appearance.dart` becomes a shim: it re-exports the
  appearance names and declares `resolveTerminalAppearance(AppSettings
  settings, Brightness brightness)`, the body of today's `resolve`
  (:195-205). Its 21 `TerminalAppearance.resolve(` call sites (2 in
  `terminal_pane.dart`, 19 in two tests) are renamed mechanically.
  Rejected: an `AppSettings implements TerminalAppearanceSource`
  interface, which would put a Séance-shaped settings type in the package
  to save a rename.

Klabautermann (M12, not F5c): `KA/lib/ui/docker/container_terminal.dart`
builds an `XtermTerminalEngine`, a `TerminalByteTransport` over the engine
client, a `TerminalByteSession`, a `TerminalPastePolicy` whose `inspect`
asks the engine and maps its plain danger findings, and the ARB strings
bag. Its theme sets `hasTerminal: false` and its presets carry no terminal
colours (`KA/lib/theme/app_theme.dart:92-93, :110`), so it calls
`TerminalAppearance.of(palette: TerminalPalette.followApp, themeColors:
null, ...)` and gets the built-in palettes, unless M12 decides otherwise.

## 7. Registration (03 D3 bookkeeping, 04:62-69)

In F5c-1, all root-shared, so F5c-1 is [R]:

- Owned list: `seance/packages/seance_terminal/pubspec.yaml` joins
  `tool/release_version/test/release_script_test.dart:98-125`. Discovery
  is automatic (`tool/release_version/lib/release_version.dart:48-58`
  excludes only vendored and workspace roots); the list is the deliberate
  check. The name collides with no lockfile entry today.
- `ci.yml`'s `seance_flutter` job (`.github/workflows/ci.yml:1351-1376`):
  resolve, analyze, test and format steps for
  `seance/packages/seance_terminal`, before the app steps, one resolution
  at a time (root `AGENTS.md`).
- `scripts/test.sh:196-202` (Séance block): the same four commands.
- Pin audit: the `seance_pin_audit` job (`ci.yml:477`) runs; the record in
  `poltergeist/docs/PORTS.md` is refreshed only if
  `audit-seance-pin.sh --print-findings` reports drift
  (`docs/design/catalog-library.md:948-975`). A new package with no license
  file and no vendored path should not drift [guess].
- No `poltergeist/docs/PORTS.md` ledger entry: no Poltergeist code moves.
- `tool/guards.yaml`: unchanged (2).

## 8. Staged PRs

Every PR is [S]: it changes `seance/`, merges alone with a merge commit,
in the queue order of P6 (M02, F5c-1, F5d-1, F5c-2a, F5c-2b, ...).
Sizes count moved lines once and leave out lockfiles.

| PR | Contents | Switches | Gates | Size |
|---|---|---|---|---|
| F5c-0 | This document | none | docs | ~500 |
| F5c-1 [S][R] | First commit: `SA/test/terminal_capture_test.dart` (9.2), run on the old code. Then: package skeleton (pubspec, lock, analysis options, barrel); `xterm_engine.dart` moved byte-identical; `xterm_engine_test.dart` moved with one import repointed; export shim; registration (7) | Séance | Séance full suite; package suite; terminal fork suite; the five capture suites plus the new one byte-identical before and after, recorded in the PR; pin audit | ~1,150 |
| F5c-2a [S] | Keyboard bar moved (import repoint, private mono const, strings bag); appearance moved (ghost imports, `resolve` left in Séance's shim, 21 call sites renamed); package appearance tests for `of`, `fromColors`, `toColors` and the clamp; 03 graph edges | Séance | Séance full suite including `terminal_appearance_test` and `terminal_ligatures_test` unchanged except the rename; moved keyboard-bar test; captures byte-identical | ~800 |
| F5c-2b [S] | `TerminalByteTransport` and `TerminalByteSession`; `TerminalPastePolicy` and its types; contract test (3.4) | none (first user M12) | Package suite; Klabautermann app suite; Séance suite untouched | ~700 |

F5c-2a and F5c-2b are the M5 plan's F5c-2 (~900) split at the move/new
code line: the estimate above is about 1,500, past the ~1,400 lines GLM
reviews in time. M12 then depends on F5c-2b.

## 9. Tests and baselines

### 9.1 Per PR

- F5c-1: the moved engine test (25 cases) runs in the package; Séance's
  28 engine-importing tests run through the shim.
- F5c-2a: the moved keyboard-bar test (5 cases), plus a case that a
  custom strings bag reaches the semantics labels. Séance's appearance
  and ligature tests stay as the switch proof.
- F5c-2b, byte session: bytes in reach the buffer; typed bytes reach
  `write`; a 132x43 resize arrives as `columns: 132, rows: 43` (R15
  boundary, 03:2719); no write after close; `output` ending fires
  `onClosed` once, also when assigned late; `close` twice disposes once;
  a closed session ignores late output.
- F5c-2b, paste policy: one line is sanitized and never inspected; tab
  survives and ESC does not; multi-line without findings pastes without
  asking; multi-line with findings calls `confirm` once with the
  findings; `firstLineOnly` pastes the sanitized first line; `cancel`
  pastes nothing; an inspector error calls `confirm` with null findings;
  bracketed paste wraps the result once.

### 9.2 Pixel baselines

D3 requires real-font captures before and after each move, compared in
the PR. Because no existing capture renders the terminal (1.7), F5c-1's
first commit adds `SA/test/terminal_capture_test.dart`, gated like the
others on `SEANCE_CAPTURE=1`: a `TerminalView` over an engine fed fixed
ANSI output, in the dark and light built-in palettes and one theme
palette, with and without ligatures, and the keyboard bar with Ctrl armed
and not. It changes no behaviour, runs in CI as an ordinary widget test,
and gives F5c-1 and F5c-2a a terminal baseline. Klabautermann has no
terminal yet, so it has no baseline to keep.

## 10. Risks

1. Byte identity: Séance's app sources are analyzed but not
   format-checked (`scripts/test.sh:199-201`). If `dart format` changes a
   moved file, the package's format step and the byte-identical move
   conflict. F5c-1 checks this first; if needed, a Séance-side format
   commit precedes the move in the same PR (not checked here: no Dart SDK
   in this environment).
2. Boundary: `TerminalByteSession implements SessionTransport` and the
   engine's `TerminalSize` signatures put `seance_core` types in reach of
   inference. The rule is "never named, never exported", checked by 3.4;
   a later barrel addition that exports a `seance_core` name fails it.
3. Paste coverage: the policy guards only routed paths (3.3). Leaving
   xterm's default shortcuts on would bypass it silently.
4. Resize order: Docker takes rows first; xterm reports width first. The
   named parameters and the 132x43 test are the guard.
5. Stored values: `TerminalPalette` and `TerminalLigatures` names live in
   Séance's settings file; renaming either loses user settings.
6. Ownership: `close` disposes the engine. A Klabautermann view that also
   disposes it relies on `dispose` staying idempotent
   (`xterm_engine.dart:446-452`).
7. Licenses: Klabautermann's lock gains the fork's hosted dependencies
   (`convert`, `meta`, `quiver`, `equatable`, `zmodem`; `XT/pubspec.yaml`)
   in M12. M12 runs the license gate in release mode for them.
8. Séance follow-up, out of scope: its raw clipboard paste passes ESC
   through, so a clipboard holding `ESC[201~` ends bracketed paste early
   and the rest runs as typed (1.4). Adopting `TerminalPastePolicy` in
   Séance would fix it; that is a behaviour change for its own PR.

## 11. Corrections to the plan

1. 03 §7.13 says container pastes pass the sanitizer and the danger
   linter "as in Séance shells" (03:3751-3752). Séance's clipboard paste
   passes neither (1.4); the sanitizer guards injected text only. The
   policy is new behaviour for Klabautermann, not a port.
2. P4 and the plan's F5c-2 name "Séance's `SessionTransport` adapter, so
   Séance's behaviour does not change". `SessionTransport` carries no
   bytes and Séance's transports wire the engine inside pure-Dart
   `seance_core` (1.3), so no adapter fits without moving that wiring.
   Séance is not switched onto the byte seam; Klabautermann is its first
   user, and the class implements `SessionTransport` instead (3.2).
3. P4's paste policy "wraps `PasteSanitizer`", but the sanitizer refuses
   multi-line text and its control stripping is private
   (`paste_sanitizer.dart:19-27, :37`). The policy sanitizes line by
   line; `seance_core` is not edited.
4. The plan's F5c-1 test line expects "the `SEANCE_CAPTURE=1` terminal
   captures byte-identical". There are none (1.7); F5c-1 adds one.
5. The plan cites `scripts/test.sh:179-201` and `ci.yml:1351-1377`; the
   Séance block is `scripts/test.sh:196-202` and the job is
   `ci.yml:1351-1376` at `11ee9db7`. 03 §11.6 still cites
   `seance_flutter` at `ci.yml:938` (03:7208).
6. F5c-2 at ~900 lines is about 1,500 with the strings bag, the
   appearance tests and the seams' tests; split into F5c-2a and F5c-2b.

## 12. Decided question

**Where do paste danger findings come from?** The policy takes an
`inspect` callback. Klabautermann can fill it from the engine (a text-lint
query added in M12, mapping the protocol's plain findings), or
`seance_terminal` could call `DangerLinter` itself in the UI isolate and
expose `TerminalPasteFinding`s directly.

Decided: the engine, as P4 says. It already runs `DangerLinter`
with the F2d Docker rules for plan previews, so a paste and a planned
action get the same verdict and wording; the engine is a local isolate,
so the round trip cannot fail for lack of a network; and
`seance_terminal` keeps a single `seance_core` dependency beyond the
engine seam (`PasteSanitizer`). The callback shape lets Séance pass a
local linter if it ever adopts the policy.
