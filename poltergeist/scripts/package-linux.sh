#!/usr/bin/env bash
#
# Turn a built Flutter Linux bundle (app/poltergeist_app/build/linux/<arch>/
# release/bundle) into installable Linux artifacts:
#
#   poltergeist_<version>-1_<arch>.deb — Debian/Ubuntu package (dpkg-deb; no
#                                    fakeroot needed, --root-owner-group is
#                                    used). Skipped, with a notice, on hosts
#                                    without dpkg-deb (Arch/Fedora/…) — the
#                                    AppImage below is what covers those.
#   poltergeist-linux-<x64|arm64>.AppImage — distro-independent portable image
#                                    (needs appimagetool; fetched once and
#                                    cached unless APPIMAGETOOL points at one)
#
# Everything is derived from the actual build output: the dependency list of
# the .deb is read from the ELF headers of the bundle (readelf NEEDED + a
# soname→package table, with the Ubuntu 24.04 "t64" rename handled as dpkg
# alternatives), and the glibc/libstdc++ floors from the symbol versions the
# bundle references — so a plugin or toolchain change can't silently make the
# shipped Depends stale. Unknown sonames fail the build on purpose: adding a
# plugin that links a new system library must force a conscious table update.
#
# Usage:
#   scripts/package-linux.sh                     # deb + AppImage → dist/
#   scripts/package-linux.sh --skip-appimage     # just the .deb
#   scripts/package-linux.sh --appimage=best-effort   # don't fail when the
#                                    appimagetool download can't be fetched
#   scripts/package-linux.sh --print-deps        # show the computed Depends
#   scripts/package-linux.sh --bundle <dir> --output-dir <dir>
#
# Environment:
#   APPIMAGETOOL      path to (or URL of) an appimagetool AppImage
#                     [default: pinned 1.9.1 release, cached in ~/.cache/poltergeist]
#
# The packaging logic is shared with the other products in
# ../../scripts/package-linux-common.sh (its header lists the parameters);
# this wrapper carries Poltergeist's identities, desktop entry and package
# metadata.
#
# CI (.github/workflows/{ci,release}.yml) runs this right after
# `flutter build linux --release`; scripts/build.sh runs it from its `app`
# target on Linux hosts. The .rpm/Flatpak formats are deliberately not built —
# non-Debian users get the AppImage (same call as Séance; see its
# docs/STATUS.md for the rationale).
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/app/poltergeist_app"
PRODUCT_NAME="Poltergeist"
PACKAGE_NAME="poltergeist"
ASSET_STEM="poltergeist"
BUNDLE_EXECUTABLE="poltergeist"
LINUX_APPLICATION_ID="ch.lkmc.poltergeist"
LINUX_STARTUP_WM_CLASS="${LINUX_APPLICATION_ID^}"
LINUX_DESKTOP_FILE="$LINUX_APPLICATION_ID.desktop"
MASTER_ICON="$ROOT/media-sources/icon.png"
LICENSE_FILE="$ROOT/LICENSE"
DEB_SECTION="net"
DEB_DESCRIPTION="Poltergeist — a two-pane file transfer client
 Dual-pane file manager and transfer client (SFTP first) with tabs per
 pane, a bookmarks sidebar, previewable sync, and a built-in editor.
 The ghost that moves your files."
DEB_COPYRIGHT_TITLE="Poltergeist — a cross-platform two-pane file transfer client"

# Runtime tools the app spawns — invisible to the ELF scan because nothing
# links them. gio (the D15 local trash backend, 03 §7.3) lives in
# libglib2.0-bin; the libglib2.0-0 *library* dependency does not pull in
# the binary package, so a desktop-lite install could otherwise ship a .deb
# whose trash reports "unavailable" where it should work.
EXTRA_DEPENDS=('libglib2.0-bin')

write_desktop_file() {  # $1 = path, $2 = Exec value
  cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=Poltergeist
GenericName=File Transfer Client
Comment=The ghost that moves your files
Exec=$2 %u
Icon=$PACKAGE_NAME
Terminal=false
Categories=Network;FileTransfer;FileManager;
MimeType=x-scheme-handler/poltergeist;
# The packaged build reports this X11 WM_CLASS class (the instance is the
# lowercase application id); StartupWMClass is case-sensitive.
StartupWMClass=$LINUX_STARTUP_WM_CLASS
EOF
}

# shellcheck source=../../scripts/package-linux-common.sh
source "$(dirname "$SELF")/../../scripts/package-linux-common.sh"
package_linux_main "$@"
