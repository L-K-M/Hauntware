# Poltergeist app

Flutter 3.47.2 scaffold for the Poltergeist client. M1 is implemented but
remains open pending green CI and the v0.1.0 rehearsal.

Runtime pins: `intl 0.20.3`, `macos_window_utils 1.9.1`,
`path 1.9.1`, `path_provider 2.1.6`, `screen_retriever 0.2.2`,
`uuid 4.6.0`, and `window_manager 0.5.2`. Development pins are
`flutter_launcher_icons 0.14.4` and `flutter_lints 6.0.0`.

The launcher source is `../../media-sources/poltergeist-icon.png` (1024×1024).
Regenerate platform icons with `dart run flutter_launcher_icons`.

Generated localization Dart files are committed. Run `flutter gen-l10n` and
require a clean tree whenever the ARB or `l10n.yaml` changes.

```bash
flutter pub get
flutter analyze
flutter test
```
