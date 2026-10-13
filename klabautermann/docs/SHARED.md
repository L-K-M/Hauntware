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
| `klabautermann/app/klabautermann_app/macos/Runner/KlabautermannFlutterViewController.h` | `seance/app/seance_app/macos/Runner/SeanceFlutterViewController.h` (`0eaba47`) | Class renamed; provenance note in the doc comment. |
| `klabautermann/app/klabautermann_app/macos/Runner/KlabautermannFlutterViewController.m` | `seance/app/seance_app/macos/Runner/SeanceFlutterViewController.m` (`0eaba47`) | Class, categories and the normalization function renamed from `Seance*` to `Klabautermann*`; provenance comment. Behavior identical. |
| `klabautermann/app/klabautermann_app/macos/Runner/Runner-Bridging-Header.h` | `seance/app/seance_app/macos/Runner/Runner-Bridging-Header.h` (`0eaba47`) | Imports the renamed header. |
| `SWIFT_OBJC_BRIDGING_HEADER` in `klabautermann/app/klabautermann_app/macos/Runner/Configs/AppInfo.xcconfig` | The same setting in `seance/app/seance_app/macos/Runner/Configs/AppInfo.xcconfig` (`0eaba47`) | None. |
| `klabautermann/app/klabautermann_app/macos/Runner.xcodeproj/project.pbxproj` (three file references, the Runner group entries, one Sources build file) | Séance's wiring of the same three files in `seance/app/seance_app/macos/Runner.xcodeproj/project.pbxproj` | Own object ids `D7A6C0DE2F8E4A1B00000001` to `D7A6C0DE2F8E4A1B00000004`. |
| `klabautermann/app/klabautermann_app/macos/RunnerTests/AccessibilityLifecycleTest.mm` | `seance/app/seance_app/macos/RunnerTests/AccessibilityLifecycleTest.mm` (`0eaba47`) | `KLABAUTERMANN_USE_GUARD` and the renamed controller. Like Séance's, compiled only by the fixture script, not by the Xcode project. |
| `klabautermann/scripts/test-macos-keyboard.sh` | `seance/scripts/test-macos-keyboard.sh` (`0eaba47`) | App path, `KLABAUTERMANN_USE_CONTROLLER`, temporary directory name and controller file. Same shape as Poltergeist's adaptation. |
| `klabautermann/scripts/test-macos-keyboard.mm` | `seance/scripts/test-macos-keyboard.mm` (`79a5679`) | Selects the renamed controller. The checks are not copied: it includes the suite's `scripts/macos-keyboard-fixture.mm`. |
| `klabautermann/scripts/test-macos-accessibility.sh` | `seance/scripts/test-macos-accessibility.sh` (`0eaba47`) | App path, `KLABAUTERMANN_USE_GUARD`, temporary directory name and controller file. |

`MainFlutterWindow.swift` is not a copy: it keeps the `flutter create`
window and swaps in the controller. Séance hosts its controller inside
`MacOSWindowUtilsViewController` for the integrated titlebar, which
Klabautermann gets later through `ghost_desktop` (03 §10.2).

Not copied, because Klabautermann does not need them yet:

- Séance's terminal Edit-menu routing in `MainFlutterWindow.swift`; the
  app has no terminal.
- The controller's use in Séance's `SettingsWindow.swift`; the desktop
  settings window and its runners arrive in their own PR (D32).
- Poltergeist's multi-view semantics routing in
  `PoltergeistFlutterViewController.m`; Klabautermann shows one Flutter
  view per engine.

This is the suite's fourth copy of the controller (after Séance,
Poltergeist and Planchette). A shared macOS plugin that exports the
controller class to each runner is feasible, as `macos_window_utils`
exports the view controller Séance's runner creates. That extraction
changes all four products and is left to a separate suite PR.

`klabautermann/app/klabautermann_app/test/macos_runner_test.dart` checks
the wiring on Linux; only macOS compiles the controller and runs the
fixtures.
