#!/usr/bin/env bash
#
# Turn a built Flutter Linux bundle (app/seance_app/build/linux/<arch>/release/
# bundle) into installable Linux artifacts:
#
#   seance_<version>-1_<arch>.deb  — Debian/Ubuntu package (dpkg-deb; no
#                                    fakeroot needed, --root-owner-group is
#                                    used). Skipped, with a notice, on hosts
#                                    without dpkg-deb (Arch/Fedora/…) — the
#                                    AppImage below is what covers those.
#   seance-linux-<x64|arm64>.AppImage  — distro-independent portable image
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
#                     [default: pinned 1.9.1 release, cached in ~/.cache/seance]
#
# The packaging logic is shared with the other products in
# ../../scripts/package-linux-common.sh (its header lists the parameters);
# this wrapper carries Séance's identities, desktop entry and package
# metadata.
#
# CI (.github/workflows/{ci,release}.yml) runs this right after
# `flutter build linux --release`; scripts/build.sh runs it from its `app`
# target on Linux hosts. The .rpm/Flatpak formats are deliberately not built —
# non-Debian users get the AppImage (see docs/STATUS.md).
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/app/seance_app"
PRODUCT_NAME="Séance"
PACKAGE_NAME="seance"
ASSET_STEM="seance"
BUNDLE_EXECUTABLE="seance_app"
LINUX_APPLICATION_ID="ch.lkmc.seance"
# The packaged build reports the GApplication id as GTK's prgname, so the
# desktop entry keeps the lowercase id as its StartupWMClass.
LINUX_STARTUP_WM_CLASS="ch.lkmc.seance"
LINUX_DESKTOP_FILE="$LINUX_APPLICATION_ID.desktop"
MASTER_ICON="$ROOT/media-sources/seance-icon.png"
LICENSE_FILE="$ROOT/LICENSE"
DEB_SECTION="net"
DEB_DESCRIPTION="Séance — a personal cross-platform SSH client
 SSH client with trust-on-first-use host keys, an E2E-encrypted optional
 sync server, SFTP file browsing, and a built-in LLM assistant.
 You summon remote machines and talk to them."
DEB_COPYRIGHT_TITLE="Séance — a personal cross-platform SSH client"

# Runtime tools the app spawns would go here: binaries the app runs are
# invisible to the ELF scan because nothing links them. Séance shells out to
# none locally; add the first one with the first spawn, as Poltergeist does
# for gio.
EXTRA_DEPENDS=()

write_desktop_file() {  # $1 = path, $2 = Exec value
  cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=Séance
GenericName=SSH Client
Comment=Summon remote machines and talk to them
Exec=$2 %u
Icon=$PACKAGE_NAME
Terminal=false
Categories=Network;System;Utility;
MimeType=x-scheme-handler/seance;
# The GApplication id is also the prgname GTK reports to the session (seen
# in its warnings: "(ch.lkmc.seance:pid): …"), hence StartupWMClass —
# that's what lets desktops map windows onto this entry.
StartupWMClass=$LINUX_STARTUP_WM_CLASS
EOF
}

# shellcheck source=../../scripts/package-linux-common.sh
source "$(dirname "$SELF")/../../scripts/package-linux-common.sh"
package_linux_main "$@"
