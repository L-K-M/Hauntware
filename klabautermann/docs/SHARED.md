# Copied native code ledger

Dart code is shared through packages and never copied. Native runner code
cannot be shared that way, so Klabautermann copies it from a sibling and
records each copy here (03 D32): the source path and commit, how the copy
diverges, and who owns it. Update the entry whenever either side changes,
and review the code for a shared plugin before another copy appears.

Paths are relative to the repository root. "Copied at" is the `origin/main`
commit the files were taken from; "last changed" is the source file's own
last commit at that point, which a later diff starts from.

## macOS keyboard and accessibility compatibility controller

Copied at `ddb8cd690891a6967b0b42ae11a30e26e56f2c7e` (M1, A6).
Owner: Klabautermann maintains its copy; Séance owns the canonical
version and its documentation:
[macos-keyboard-compatibility.md](../../seance/docs/macos-keyboard-compatibility.md)
and [macos-accessibility-crash.md](../../seance/docs/macos-accessibility-crash.md).
Keep the behavior in step with Séance and rerun both fixtures after every
Flutter upgrade; both fixes depend on private engine selectors.

| Klabautermann file | Source (last changed) | Divergences |
|---|---|---|
| `klabautermann/app/klabautermann_app/macos/Runner/KlabautermannFlutterViewController.h` | `seance/app/seance_app/macos/Runner/SeanceFlutterViewController.h` (`f9bd1e1`) | Class renamed; provenance note in the doc comment. |
| `klabautermann/app/klabautermann_app/macos/Runner/KlabautermannFlutterViewController.m` | `seance/app/seance_app/macos/Runner/SeanceFlutterViewController.m` (`f9bd1e1`) | Class, categories and the normalization function renamed from `Seance*` to `Klabautermann*`; provenance comment. Behavior identical. |
| `klabautermann/app/klabautermann_app/macos/Runner/Runner-Bridging-Header.h` | `seance/app/seance_app/macos/Runner/Runner-Bridging-Header.h` (`f9bd1e1`) | Imports the renamed header. |
| `SWIFT_OBJC_BRIDGING_HEADER` in `klabautermann/app/klabautermann_app/macos/Runner/Configs/AppInfo.xcconfig` | The same setting in `seance/app/seance_app/macos/Runner/Configs/AppInfo.xcconfig` (`f9bd1e1`) | None. |
| `klabautermann/app/klabautermann_app/macos/Runner.xcodeproj/project.pbxproj` (three file references, the Runner group entries, one Sources build file) | Séance's wiring of the same three files in `seance/app/seance_app/macos/Runner.xcodeproj/project.pbxproj` (`f9bd1e1`) | Own object ids `D7A6C0DE2F8E4A1B00000001` to `D7A6C0DE2F8E4A1B00000004`. |
| `klabautermann/app/klabautermann_app/macos/RunnerTests/AccessibilityLifecycleTest.mm` | `seance/app/seance_app/macos/RunnerTests/AccessibilityLifecycleTest.mm` (`f9bd1e1`) | `KLABAUTERMANN_USE_GUARD` and the renamed controller. Like Séance's, compiled only by the fixture script, not by the Xcode project. |
| `klabautermann/scripts/test-macos-keyboard.sh` | `seance/scripts/test-macos-keyboard.sh` (`f9bd1e1`) | App path, `KLABAUTERMANN_USE_CONTROLLER`, temporary directory name and controller file. Same shape as Poltergeist's adaptation. |
| `klabautermann/scripts/test-macos-keyboard.mm` | `seance/scripts/test-macos-keyboard.mm` (`79a5679`) | Selects the renamed controller. The checks are not copied: it includes the suite's `scripts/macos-keyboard-fixture.mm`. |
| `klabautermann/scripts/test-macos-accessibility.sh` | `seance/scripts/test-macos-accessibility.sh` (`f9bd1e1`) | App path, `KLABAUTERMANN_USE_GUARD`, temporary directory name and controller file. |

`MainFlutterWindow.swift` creates the controller and, since the desktop
chrome landed, hosts it inside macos_window_utils'
`MacOSWindowUtilsViewController` for the integrated titlebar, as Séance's
runner does; those lines are ledgered under "Main window chrome" below.

Not copied, because Klabautermann does not need them yet:

- Séance's terminal Edit-menu routing in `MainFlutterWindow.swift`; the
  app has no terminal.
- Poltergeist's multi-view semantics routing in
  `PoltergeistFlutterViewController.m`; Klabautermann shows one Flutter
  view per engine.

`klabautermann/app/klabautermann_app/test/macos_runner_test.dart` checks
the wiring on Linux; only macOS compiles the controller and runs the
fixtures.

### D32 shared-plugin review

This is the suite's fourth copy of the controller, after Séance's,
Poltergeist's and Planchette's, so D32 requires a review for a shared
plugin first. Reviewed at the copy commit above:

- **The copies.** Klabautermann's controller is Séance's after the
  rename. Planchette's is Séance's plus multi-view semantics routing
  (`updateSemantics:`), which forwards only updates that name another
  view and so never acts in a single-view app. Poltergeist's carries a
  variant of that routing without Planchette's view-identifier check:
  the copies have already drifted (04 R18). The lifecycle test is the
  same in Séance, Planchette and Klabautermann after the rename. The
  keyboard checks already live once, in
  `scripts/macos-keyboard-fixture.mm`.
- **What a plugin takes.** The suite has no macOS plugin package yet;
  `ghost_desktop` is pure Dart. A new one would ship Planchette's
  controller (both fixes and the routing) and export it to Swift, as
  `macos_window_utils` exports the `MacOSWindowUtilsViewController` that
  Séance's runner creates. Each product would then add the dependency,
  import the plugin where it creates the controller
  (`MainFlutterWindow.swift`, and Séance's `SettingsWindow.swift`), and
  drop its controller files,
  bridging-header import and project entries. Every product's fixture
  scripts would compile the plugin's source, the lifecycle test would
  move to a root include like the keyboard checks, and the macOS CI legs
  of all four products and the siblings' release legs would have to pass
  with the plugin in the same change.
- **Outcome: copy now, extract in a separate suite PR.** M1 needs the
  controller: the 04 §12.1 Packaging row requires the fixtures from M1,
  and they fail on the stock controller. The extraction rewrites four
  products' runners and CI legs that only macOS can build, so it does
  not belong in a Klabautermann milestone PR; 04 R18 already plans the
  shared plugin, with this ledger as the interim control. This copy adds
  no new variant to reconcile, since Planchette's controller contains it.
  No fifth copy: the next product that needs the controller does the
  extraction first. Klabautermann's own later windows (the settings
  window, D32) reuse this class and are not copies.

## Desktop settings window runners

Copied at `ddb8cd690891a6967b0b42ae11a30e26e56f2c7e` (M1, A8; the files
are unchanged at `2e61152e`). Owner: Klabautermann maintains its copy;
Séance owns the canonical runners, and Poltergeist carries the other copy
(`poltergeist/docs/PORTS.md`, "Settings window runners"). The Dart side
is not copied: ghost_desktop's link engine
([settings-window-link.md](../../docs/design/settings-window-link.md))
under Klabautermann's own channels, method table and sections in
`app/klabautermann_app/lib/services/settings_window/`.

Séance's set is the source because it is the closest working copy:
like Klabautermann it has one main window and one engine, and its view
keeps the template's background. Poltergeist's differs only in names,
its transparent Linux view and comments, and it is itself a port of
Séance's.

| Klabautermann file | Source (last changed) | Divergences |
|---|---|---|
| `klabautermann/app/klabautermann_app/macos/Runner/SettingsWindow.swift` | `seance/app/seance_app/macos/Runner/SettingsWindow.swift` (`f9bd1e1`) | Channels `klabautermann/settings_window` and `klabautermann/settings_link`, argument `--klabautermann-settings-window`, `KlabautermannFlutterViewController` (Séance's controller, copied in the section above), provenance note. Comments point at Klabautermann's and ghost_desktop's Dart files, and the ⌘W comment names no terminal tabs, since the app's window binds no ⌘W yet. |
| `klabautermann/app/klabautermann_app/linux/runner/settings_window.{h,cc}` | `seance/app/seance_app/linux/runner/settings_window.{h,cc}` (`f9bd1e1`) | Channels, argument, title `Klabautermann Settings`, the main window's data key `klabautermann-settings-window`, provenance note. Template background, as Séance's. |
| `klabautermann/app/klabautermann_app/linux/runner/window_title.{h,cc}` | `seance/app/seance_app/linux/runner/window_title.{h,cc}` (`f9bd1e1`) | Provenance note in the header; the `.cc` is byte-identical. It is the `flutter create` title code that `my_application.cc` carried inline; both windows now call it. |
| `klabautermann/app/klabautermann_app/windows/runner/settings_window.{h,cpp}` | `seance/app/seance_app/windows/runner/settings_window.{h,cpp}` (`f9bd1e1`) | Channels, argument, title `Klabautermann Settings`, provenance note spelled ASCII for MSVC. |
| Wiring: `MainFlutterWindow.swift` (the `settingsWindow` property, the host's creation and the `close()` override), `my_application.cc` (`settings_window_install` after the plugins, `window_title_apply`), `flutter_window.{h,cpp}` (the `settings_window_` member, created after the plugins and reset first in `OnDestroy`), both runner `CMakeLists.txt` | The same lines in Séance's files (`f9bd1e1`) | `flutter_window.{h,cpp}` now equal Séance's. The Linux main window keeps its 1280 by 720 size and the macOS window its `flutter create` frame. |
| `klabautermann/app/klabautermann_app/macos/Runner.xcodeproj/project.pbxproj` (one file reference, the Runner group entry, one Sources build file) | Séance's wiring of `SettingsWindow.swift` (`f9bd1e1`) | Own object ids `D7A6C0DE2F8E4A1B00000005` and `D7A6C0DE2F8E4A1B00000006`. |

The runners are byte relays with a control channel, so nothing native
sees Klabautermann's method names. What they share with the siblings is
the shape the link engine relies on: the window is created on the first
`open` and only hidden on close, because disposing a second engine on
Linux terminates the EGL display every engine shares; the window's
engine registers no plugins; and the link handler is set on its engine
before Dart can say hello. A change to Séance's runners should reach
both copies.

This is the suite's third copy of the runners (Séance, Poltergeist,
Klabautermann). A fourth needs the D32 shared-plugin review first;
settings-window-link.md §4 records why the runners stayed per product
when the Dart engine moved into `ghost_desktop`.

`klabautermann/app/klabautermann_app/test/settings_window_runner_test.dart`
checks the native wiring on Linux; only each platform's toolchain
compiles the runners, and only a person on each desktop OS can open and
use the window (docs/STATUS.md).

## Main window chrome

Copied at `9354e623733c38219ffd2e0d7d0943d04332ea80` (M1, the desktop
chrome of 03 §10.2). Owner: Klabautermann maintains its copy; Séance owns
the canonical runner, and Poltergeist's `MainFlutterWindow.swift` carries
the same lines. The Dart side is not copied: the window lifecycle is
ghost_desktop's `GhostWindowLifecycle`, configured in
`app/klabautermann_app/lib/services/window_state.dart`.

| Klabautermann file | Source (last changed) | Divergences |
|---|---|---|
| `klabautermann/app/klabautermann_app/macos/Runner/MainFlutterWindow.swift`: `import window_manager` and the `order(_:relativeTo:)` override that calls `hiddenWindowAtLaunch()` | The same lines in `seance/app/seance_app/macos/Runner/MainFlutterWindow.swift` (`f9bd1e1`); Poltergeist's (`c90eb5a`) and `planchette/app/planchette_app/macos/Runner/MainFlutterWindow.swift` (`d0e978a`) carry them too | The comment names `restoreMainWindow()` in `lib/services/window_state.dart`. |
| `MainFlutterWindow.swift`, integrated titlebar: `import macos_window_utils`, the `MacOSWindowUtilsViewController` around the compatibility controller, the `setContentSize` and `center()` after it, `MainFlutterWindowManipulator.start`, the `toolbar` override, `inFullScreen`, the `klabautermann/window` channel answering `isToolbarBandVisible`, the will-enter and will-exit full-screen observers and `setInFullScreen`, which sends `toolbarBandChanged` | The same lines in Séance's `MainFlutterWindow.swift` (`f9bd1e1`); Poltergeist's carries them too (`c90eb5a`), apart from the default size, which it passes to its window lifecycle | Channel `klabautermann/window`; the controller inside is `KlabautermannFlutterViewController`; after the controller swap the window takes 1280 by 720, the Linux and Windows runners' size, where Séance's takes 1280 by 800, and centres as Séance's does; the comments name Klabautermann's Dart files and say the band covers the content's top, since no header draws under it yet. Séance's menu, files and bookmark channels are not copied. |
| `MainFlutterWindow.swift`, menus: `NSWindow.allowsAutomaticWindowTabbing = false` | The same line in Séance's `MainFlutterWindow.swift` (`f9bd1e1`); Poltergeist's (`c90eb5a`) and Planchette's (`d0e978a`) set it too | The comment names the Dart menus in `lib/ui/menus/`, which `PlatformMenuBar` installs; Séance builds its menus natively. |

### D32 shared-plugin review

The hidden-launch override and the tabbing line are the suite's fourth
copies, after Séance's, Poltergeist's and Planchette's runners, so D32
asks for a shared-plugin review. Reviewed at the copy commit above:

- **The hidden-launch override.** The shared plugin already exists:
  window_manager ships `hiddenWindowAtLaunch()` as an `NSWindow`
  extension, and the four-line `order(_:relativeTo:)` override that
  calls it is how window_manager's own example runner hooks it in. The
  override belongs to the runner's own `NSWindow` subclass; a plugin
  could only take it over by swizzling AppKit.
- **The tabbing line.** One AppKit setting, made where the runner
  configures its window; a plugin would only wrap it.
- **The integrated titlebar.** Its shared plugin is macos_window_utils;
  the copied lines are the host setup its README asks for, plus the full-screen
  toolbar handling and the band channel, whose Dart side is
  ghost_desktop's `MacosToolbarBandChannel`. Planchette has no
  integrated titlebar, so this is the third copy.
- **Outcome: no extraction.** Nothing here is logic a further plugin
  would own; the rows above stay the record of each copy.

Linux and Windows need no runner code for the window state: the
window_manager plugin, which their runners already register, carries the
restore, as in Séance's runners. Only the main window waits hidden for
Dart and gets the titlebar; the settings window's runner is unchanged, and
its engine registers no plugins, so it never reaches macos_window_utils or
window_manager. `macos/Flutter/GeneratedPluginRegistrant.swift` is
regenerated by `flutter pub get` and registers macos_window_utils' plugin
for the main window's engine.

The View menu's pane toggles and the Edit menu are the first commands
with checked state, so `klabautermann/menu_checks` (04 §12.3) is now
wired to its native peer:

| Klabautermann file | Source (last changed) | Divergences |
|---|---|---|
| `klabautermann/app/klabautermann_app/macos/Runner/MenuChecks.swift` | `poltergeist/app/poltergeist_app/macos/Runner/MenuChecks.swift` (`c90eb5a`) | Channel `klabautermann/menu_checks`; the header comment names this ledger. |

`klabautermann/app/klabautermann_app/test/desktop_chrome_runner_test.dart`
checks the wiring on Linux; only macOS compiles it, and only a person can
check the titlebar, a restore or the menus on a real desktop
(docs/STATUS.md).
