# Hauntware

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

**Current version:** v<!-- version -->1.9.3<!-- /version --> · [Releases](https://github.com/L-K-M/Hauntware/releases)

Desktop apps are ad-hoc signed and not notarized. After moving one to
Applications, clear its quarantine flag, for example:

```bash
xattr -dr com.apple.quarantine "/Applications/Seance.app"
```

Free to use. Haunting included.

One repository, one version and one release cadence:

| Product | Purpose | Clients |
| --- | --- | --- |
| [Planchette](planchette/README.md) | Text editor and shared editor/UI packages | Android, Linux, macOS, Windows |
| [Séance](seance/README.md) | SSH client and optional local terminal | Android, iOS, Linux, macOS, Windows |
| [Poltergeist](poltergeist/README.md) | File transfer and folder synchronization | Android, iOS, Linux, macOS, Windows |
| [Klabautermann](klabautermann/README.md) | Server management and Docker | Android, iOS, Linux, macOS, Windows |

Séance also supplies the shared encrypted sync server. Product names,
application IDs, storage locations and keystore namespaces stay distinct.
Klabautermann is in preview: suite releases ship its five clients under
asset names that carry the preview label until v1, except the .deb,
which keeps Debian's versioned name.

## Develop

Use Flutter **3.47.2** and its bundled Dart, Python 3 for history checks,
and the native toolchains documented in each product's `AGENTS.md`.
The sync-server tests also need the SQLite shared library.

```bash
scripts/test.sh dart       # Pure-Dart packages, guards and tooling
scripts/test.sh flutter    # Shared Flutter packages and applications
scripts/build.sh --check   # Inspect available products/toolchains
scripts/build.sh seance    # Build the selected product
scripts/build.sh --install # Build all four apps and install them (macOS: /Applications)
python3 scripts/check-history.py
```

Each project retains its pure-Dart workspace. Flutter packages resolve
separately; internal dependencies use local paths. Run commands in their
actual working directories and resolve dependencies sequentially.

## Release

`scripts/release.sh` uses the shared [release-tool](https://github.com/L-K-M/release-tool)
engine. It synchronizes all owned package/app versions, Android build codes,
Apple metadata, lockfiles and README markers. Child release scripts forward
to the whole suite.

Update `release-tool` before releasing: the required pre-tag hook refreshes
and commits the Séance provenance proof after the version-bump commit.

```bash
scripts/release.sh --check
scripts/release.sh 1.2.0 --push  # Explicit future release, not part of migration
```

One `vX.Y.Z` tag drives all 19 released client targets, sync-server binaries
and its container image. One publish point follows every required test/build
and artifact/checksum check.
Android keeps the existing committed sideload signing keys; desktop bundles
remain unsigned/ad-hoc and iOS bundles unsigned.
Vendored package versions and historical benchmark measurements stay intact.

## Migration and history

[Source history](docs/history/README.md) records the reviewed source heads,
407 captured refs and exact historical tag metadata. Full-history imports
retain original commit IDs; rejected/experimental trees remain historical.

The standalone repositories are archived. Their final releases point here,
so standalone installs see the suite release through their update check.
Séance 0.9.2, Poltergeist 1.0.1 and earlier used `com.lkm.*` application
IDs; suite builds use `ch.lkmc.*`, install as new apps and start without
the old apps' data. Séance's macOS sandbox migration covers only sandboxed
builds with the current bundle ID; see its [status](seance/docs/STATUS.md).

## License

Hauntware's own code is released under the [Unlicense](LICENSE). The builds
bundle third-party code that keeps its own licenses:

- Every client bundles the Flutter engine and Dart runtime, its pub packages
  (among them Séance's vendored xterm and flutter_pty and Poltergeist's
  vendored pdfium_dart, all under the MIT License) and 23 monospace fonts,
  under the SIL Open Font License 1.1 except 3270 (BSD-3-Clause, with a
  Debian logo glyph under CC BY-SA 3.0 or LGPL-3.0-or-later).
- Poltergeist also bundles the PDFium library and the code compiled into it
  (FreeType, libjpeg-turbo, OpenJPEG, Little CMS, libpng, zlib, ICU and
  others).
- The Android apps also bundle AndroidX, Kotlin and other Maven libraries;
  Klabautermann's also bundles desugar_jdk_libs (GPL-2.0 with the Classpath
  Exception). Séance and Klabautermann for Windows also bundle Microsoft's
  WIL and C++/WinRT. Séance and Poltergeist for iOS also bundle
  DKImagePickerController, DKCamera, DKPhotoGallery, TOCropViewController,
  SwiftyGif and SDWebImage, which file_picker pulls in.
- The Linux AppImages also carry the AppImage runtime, which statically
  links libfuse (LGPL-2.1), squashfuse, musl, zstd and zlib.
- The sync server bundles the Dart runtime (with BoringSSL, ICU, zlib and
  other code it embeds) and its pub packages; its Docker image adds Debian
  packages.

Their notices ship inside each artifact:

- In every app: Settings > Open-source licenses (Klabautermann: About >
  View licenses).
- Linux tarballs and Windows zips: `Third-Party-Notices.txt` and `LICENSE`
  at the top.
- macOS apps: `<App>.app/Contents/Resources/Third-Party-Notices.txt`; iOS
  apps: `Third-Party-Notices.txt` in the app bundle.
- Linux packages: `copyright` and `Third-Party-Notices.txt` in
  `/usr/share/doc/<package>/` (Flatpak: `/app/share/doc/<package>/`). The
  AppImage's notices also cover its runtime, with source links in
  `SOURCES.txt` beside them.
- Sync-server tarballs: `Third-Party-Notices.txt` and `LICENSE` beside the
  binary. Docker image: `Third-Party-Notices.txt`, `OS-Packages.txt` and
  `LICENSE` in `/usr/share/doc/seance-sync/`; system packages from the base
  image keep their notices in `/usr/share/doc/*/copyright`.

The Unlicense covers Hauntware's own code only, which `planchette/LICENSE`,
`seance/LICENSE`, `poltergeist/LICENSE` and `klabautermann/LICENSE` repeat
per product. These files hold third-party texts, not the project's license:
the `LICENSE` files under `*/third_party/` (with PDFium's notices appended
to pdfium_dart's), `planchette/packages/ghost_fonts/LICENSE` (the fonts'
licenses), `seance/app/seance_app/LICENSE`,
`poltergeist/app/poltergeist_app/LICENSE` and
`klabautermann/app/klabautermann_app/LICENSE` (the NuGet and Swift packages
above, after the app's own Unlicense), the Unicode License V3 for the
generated Unicode tables in `poltergeist/packages/poltergeist_core/LICENSE`,
`poltergeist/packages/poltergeist_core/tool/unicode/LICENSE.txt` and
`poltergeist/app/poltergeist_app/tool/unicode/LICENSE.txt`, and the license
texts under `*/app/*/android/app/config/licenses/` and
`scripts/licenses/`.
