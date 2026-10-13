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
