#!/usr/bin/env bash
#
# Turn a built Flutter Linux bundle (app/klabautermann_app/build/linux/<arch>/
# release/bundle) into installable Linux artifacts:
#
#   klabautermann_<version>-1_<arch>.deb
#       Debian/Ubuntu package (dpkg-deb; no fakeroot needed,
#       --root-owner-group is used). Skipped, with a notice, on hosts
#       without dpkg-deb (Arch/Fedora/...); the AppImage covers those.
#   klabautermann-preview-linux-<x64|arm64>.AppImage
#       distro-independent portable image (needs appimagetool; fetched
#       once and cached unless APPIMAGETOOL points at one)
#
# Until v1 the release asset names carry the preview label (04 §12.1,
# decision 16); the .deb keeps Debian's versioned file name and the
# package name klabautermann, and its description says preview. The
# identities (binary, application id, WM class, desktop file) never carry
# the label.
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
#                     [default: pinned 1.9.1 release, cached in ~/.cache/klabautermann]
#
# The packaging logic is the suite's shared Linux packager,
# ../../scripts/package-linux-common.sh (its header lists the parameters
# and how the dependency list is derived); this wrapper carries
# Klabautermann's identities (03 D38), desktop entry and package metadata.
#
# CI's klabautermann_client Linux leg runs this right after
# `flutter build linux --release`; scripts/build.sh runs it from its
# `app` target on Linux hosts, and scripts/build-flatpak.sh repacks its
# .deb as the Flatpak.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/app/klabautermann_app"
PRODUCT_NAME="Klabautermann"
PACKAGE_NAME="klabautermann"
# The preview label of the release asset names; dropped at v1 (M7).
ASSET_STEM="klabautermann-preview"
BUNDLE_EXECUTABLE="klabautermann"
LINUX_APPLICATION_ID="ch.lkmc.klabautermann"
LINUX_STARTUP_WM_CLASS="${LINUX_APPLICATION_ID^}"
LINUX_DESKTOP_FILE="$LINUX_APPLICATION_ID.desktop"
MASTER_ICON="$ROOT/media-sources/klabautermann-icon.png"
LICENSE_FILE="$ROOT/LICENSE"
DEB_SECTION="admin"
DEB_DESCRIPTION="Klabautermann (preview): agentless server and Docker manager
 Preview build of the fleet manager for servers and Docker over SSH:
 monitor hosts, read the Docker Engine, and run previewed, confirmed
 operations, without installing an agent on the hosts.
 The kobold that keeps the ship's engines lit."
DEB_COPYRIGHT_TITLE="Klabautermann: an agentless fleet manager for servers and Docker over SSH"

# Runtime tools the app spawns would go here: binaries the app runs are
# invisible to the ELF scan because nothing links them. Klabautermann
# spawns none locally (SSH runs in-process); add the first one with the
# first spawn, as Poltergeist does for gio.
EXTRA_DEPENDS=()

write_desktop_file() {  # $1 = path, $2 = Exec value
  cat > "$1" <<EOF
[Desktop Entry]
Type=Application
Name=Klabautermann
GenericName=Server Manager
Comment=The kobold that keeps the ship's engines lit
Exec=$2
Icon=$PACKAGE_NAME
Terminal=false
Categories=Network;System;Monitor;
Keywords=SSH;Server;Docker;Monitoring;Fleet;
# The packaged build reports this X11 WM_CLASS class (the instance is the
# lowercase application id); StartupWMClass is case-sensitive.
StartupWMClass=$LINUX_STARTUP_WM_CLASS
EOF
}

# shellcheck source=../../scripts/package-linux-common.sh
source "$(dirname "$SELF")/../../scripts/package-linux-common.sh"
package_linux_main "$@"
