# Poltergeist's pdfium_dart fork: divergences from upstream 0.3.1

This package is a vendored copy of [pdfium_dart] 0.3.1 (MIT, see LICENSE),
as published on pub.dev: archive sha256
`e296a26c030e6e0fb34b32ce7481a3cfa0c2d35ce80f6269551c685759f4c91f`. The app
reaches it through `pdfrx` and selects this copy with `dependency_overrides`
in `app/poltergeist_app/pubspec.yaml`. Upstream's own commit is the
"Import pdfium_dart 0.3.1 unchanged" commit; `git diff` against it shows
every change below. All edits are marked `// Poltergeist:` (or `#` in YAML)
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

- `hook/link.dart`: omit the PDFium asset on macOS as well as iOS when
  `pdfium_flutter` reports that its XCFramework provides PDFium. Upstream
  keeps the macOS asset for `flutter test`, but Flutter runs link hooks
  only for profile and release builds, so test runs are unaffected.
  Release builds stop shipping the redundant copy.
- `hook/build.dart`: the macOS asset file is `libpdfium_dart.dylib`, so
  Flutter names its framework `pdfium_dart.framework`. Debug builds skip
  link hooks, so without this they would still collide.
- `pubspec.yaml`: `resolution: workspace` removed; this copy is not a
  member of upstream's pub workspace.
- `test/link_hook_test.dart`: the macOS case now expects the asset to be
  omitted, and a new case checks it is kept when no XCFramework provides
  PDFium.

## Removing this fork

Delete this directory and the `dependency_overrides` entry once an upstream
`pdfium_dart` release stops bundling a colliding macOS framework.
`scripts/verify-macos-app.sh`, run by the macOS client jobs in
`.github/workflows/ci.yml`, fails if the collision comes back.

[pdfium_dart]: https://pub.dev/packages/pdfium_dart
