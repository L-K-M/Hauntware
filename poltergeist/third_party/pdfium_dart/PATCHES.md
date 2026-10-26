# Poltergeist's pdfium_dart fork: divergences from upstream 0.3.1

This package is a vendored copy of [pdfium_dart] 0.3.1 (MIT, see LICENSE),
as published on pub.dev: archive sha256
`e296a26c030e6e0fb34b32ce7481a3cfa0c2d35ce80f6269551c685759f4c91f`. The app
reaches it through `pdfrx` and selects this copy with `dependency_overrides`
in `app/poltergeist_app/pubspec.yaml`. Upstream's own commit is the
"Import pdfium_dart 0.3.1 unchanged" commit; `git diff` against it shows
every change below. Each edit is marked `// Poltergeist:` (or `#` in YAML)
at the site.

## Why

On macOS the app gets PDFium twice:

- `pdfium_flutter` embeds `PDFium.framework` from its XCFramework through
  Swift Package Manager or CocoaPods. At runtime `getPdfium()` resolves
  symbols from it with `DynamicLibrary.process()`.
- `pdfium_dart`'s build hook also bundles `libpdfium.dylib` as a native
  asset. Flutter wraps that in a framework named after the file:
  `pdfium.framework`.

On a case-insensitive volume (the macOS default), `pdfium.framework` and
`PDFium.framework` are the same directory. Flutter's embed step rsyncs the
native asset on top of the signed XCFramework bundle and re-signs it. A
clean build happens to end up valid; an incremental one can leave the
app's seal stale, and the installed app then fails
`codesign --verify --deep --strict` with "nested code is modified or
invalid … PDFium.framework". macOS refuses to load a framework whose
signature is broken.

## Changes

- `hook/build.dart`: the macOS asset file is `libpdfium_dart.dylib`, so
  Flutter names its framework `pdfium_dart.framework` and it no longer
  lands on `PDFium.framework`. The app still loads PDFium from the
  XCFramework through `DynamicLibrary.process()`; `flutter test` loads the
  asset by its id, which the rename does not change.
- `pubspec.yaml`: `resolution: workspace` removed; this copy is not a
  member of upstream's pub workspace.

The macOS app therefore still carries the asset as an unused second copy
of PDFium. Upstream's `hook/link.dart` is meant to drop it, but
`hook/build.dart` adds the asset with the default `ToAppBundle()` routing,
so it never reaches the link hook (upstream's iOS case works only because
the build hook returns early on iOS). Making the link hook effective
would change how every platform's release build routes PDFium, so this
fork leaves it alone.

## PDFium's notices

The build hook bundles PDFium from the pdfium-binaries archive but keeps
only the library, and upstream's LICENSE covers the Dart bindings alone.
So `LICENSE` names its MIT chunk `pdfium_dart` and appends one Flutter
license chunk per component of the archive's `LICENSE` and `licenses/`
texts: PDFium and the libraries compiled into it (FreeType, libjpeg-turbo,
OpenJPEG, Little CMS, libpng, zlib, ICU, Abseil and others). Flutter
copies them into every Poltergeist NOTICES; the macOS and iOS apps'
PDFium.xcframework is built from the same PDFium release.

`tool/pdfium_licenses.py` writes those chunks from the archives the apps
ship, pinned by SHA-256 in `tool/pdfium_licenses.json`, and fails on a
license file it does not know; `--check` compares instead. Rerun it when
`_pdfiumRelease` changes: `app/poltergeist_app/test/third_party_notices_test.dart`
fails until the recorded release matches the hook's.

## Removing this fork

Delete this directory and the `dependency_overrides` entry once an upstream
`pdfium_dart` release stops bundling a colliding macOS framework and ships
PDFium's notices; until then the chunks above need a home.
`scripts/verify-macos-app.sh`, run by the macOS client jobs in
`.github/workflows/ci.yml`, fails if the collision comes back.

[pdfium_dart]: https://pub.dev/packages/pdfium_dart
