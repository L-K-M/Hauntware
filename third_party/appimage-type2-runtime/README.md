# AppImage type2-runtime

The runtime is the ELF header in front of every AppImage's squashfs.
`scripts/package-linux-common.sh` passes the file for the target arch to
appimagetool with `--runtime-file`, so the packager never downloads one.
It checks the file against the SHA-256 pinned in the script
(`APPIMAGE_RUNTIME_PINNED_SHA256`) and stops if it is missing or differs.

| File | Target | SHA-256 |
| --- | --- | --- |
| `runtime-x86_64` | x86_64 | `617aa77314d57c8b8e4fae9c3f0b35af7b30d5529cb69e98f64f92510ed98a46` |
| `runtime-aarch64` | aarch64 | `9a72a744d221576c9347ec074243acc5c3c7568896b12714e0e82e9f0bf47900` |

- Source: the `continuous` release of
  https://github.com/AppImage/type2-runtime, assets `runtime-x86_64` and
  `runtime-aarch64` (built by upstream on 2026-10-19).
- Upstream commit: `fedfad5`, embedded in the binaries as
  `type2-runtime/commit/fedfad5`. It includes 8f39b89, which creates
  extraction directories with mode 0700. The dated `20251108` release
  predates that fix, so it is not used.
- Fetched: 2026-11-12.
- Statically linked: musl, libfuse 3.15.0, squashfuse 0.5.2, zstd 1.5.6
  and zlib 1.3.2. libfuse and zstd are only identified in the x86_64 build,
  the aarch64 strings do not carry their versions.
- Licenses: `LICENSE` is upstream's MIT license. The texts of the
  statically linked libraries are in `scripts/licenses/appimage-type2-runtime/`
  (see `scripts/licenses/README.md`), and `scripts/appimage-notices.py`
  bundles them into each AppImage's notices.

## Updating

1. Download both assets from the `continuous` release (or a dated release
   once upstream publishes one that carries the fix above):
   `curl -fLO https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-x86_64`
   and the same for `runtime-aarch64`.
2. Build a probe AppImage with each (`appimagetool --runtime-file`) and run
   `python3 scripts/appimage-notices.py runtime-info <probe>.AppImage`. Note
   the commit and library versions. If a version changed, refresh the texts
   in `scripts/licenses/appimage-type2-runtime/` and the table in
   `scripts/licenses/README.md`.
3. Replace the two files here and run `sha256sum runtime-*`.
4. Update `APPIMAGE_RUNTIME_PINNED_SHA256` in
   `scripts/package-linux-common.sh` and the table, commit and fetch date
   above.
5. Run `scripts/check-release-notices.sh` and the packager tests in
   `poltergeist/tool/release_version/test/package_linux_wrapper_test.dart`.

The files are marked binary in the root `.gitattributes`.
