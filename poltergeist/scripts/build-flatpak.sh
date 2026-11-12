#!/usr/bin/env bash
set -euo pipefail
# Build dist/poltergeist-linux-x64.flatpak by repacking the release .deb
# under flatpak's /app prefix — the bundle ships byte-for-byte what the .deb
# installs. Usage:
#   scripts/build-flatpak.sh [--install]     # build the .deb first, then repack
#   scripts/build-flatpak.sh path/to.deb     # repack an existing .deb (CI)
#
# The bundle names Flathub as its runtime's source, so installing it fetches
# the GNOME runtime from there. Needs flatpak and flatpak-builder; both come
# from Flathub (user installation) on the first build.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
readonly APP_ID=ch.lkmc.poltergeist
readonly ASSET_STEM=poltergeist
readonly APP_DIR=app/poltergeist_app
readonly PACKAGE_NAME=poltergeist

# The arguments, the .deb build, the repack and the bundle are shared
# with the other products' Flatpaks.
# shellcheck source=SCRIPTDIR/../../scripts/build-flatpak-common.sh
source "$ROOT/../scripts/build-flatpak-common.sh"
build_flatpak_main "$@"
