# Klabautermann app

The Flutter client for Klabautermann, built for Android, iOS, Linux,
macOS and Windows. The engine and the host and Docker logic live in the
pure-Dart packages under `../../packages`; this app holds the widgets,
controllers and platform services. [../../AGENTS.md](../../AGENTS.md) has
the architecture boundaries and [../../docs/STATUS.md](../../docs/STATUS.md)
what is built.

Resolve the workspace before the app, and run each command from this
directory:

```bash
(cd ../.. && dart pub get)
flutter pub get
flutter analyze
flutter test
```

Generated localization Dart files are committed. Run `flutter gen-l10n`
and require a clean tree whenever an ARB file or `l10n.yaml` changes.
Golden images are compared on Linux only; regenerate one there with
`flutter test --update-goldens <test file>`.

The launcher icons come from `../../media-sources/`; regenerate them with
`dart run flutter_launcher_icons`. `../../scripts/build.sh` builds and
packages the app.
