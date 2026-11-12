#!/usr/bin/env bash
#
# Build every Klabautermann target this host can build, and print one clear
# summary. The single local entry point; CI builds the same targets in the
# klabautermann_client legs of .github/workflows/ci.yml, and release.yml
# gains them with the preview release job at M4 (04 §12.1, decision 16).
# Klabautermann has no server component, so like Poltergeist's
# build.sh (the pattern this follows) there are only client targets:
#
#   app    — Flutter desktop app for THIS host (linux/macos/windows); platform
#            folders are committed once the app is scaffolded. On Linux,
#            release builds are also packaged into installable artifacts
#            (.deb + AppImage) via
#            scripts/package-linux.sh → dist/
#            (the shared ../../scripts/package-linux-common.sh)
#   apk    — Android APK (needs flutter + an Android SDK)
#   flatpak — repack the app's .deb as a Flatpak bundle (Linux; runs the
#            app target first when no dist/ .deb exists yet)
#
# Usage:
#   scripts/build.sh                 # every target this host can build
#   scripts/build.sh app             # just this one (naming a target turns an
#                                    # infeasible target into an error, not a skip)
#   scripts/build.sh --debug app     # debug-mode Flutter builds
#   scripts/build.sh --install       # build the app for THIS host and install
#                                    # it (macOS: /Applications/Klabautermann.app;
#                                    # Linux: ~/.local/opt/klabautermann), then
#                                    # reveal the installed copy
#
# Every produced file (.app bundle, APK, …) is also copied into dist/ at the
# product root (one folder with the final artifacts), and on macOS dist/ is
# opened in the Finder when anything landed there. Until v1 the staged names
# carry the preview label like the release assets (04 §12.1, decision 16):
# klabautermann-preview.apk, klabautermann-preview-linux and so on. The .app
# keeps its bundle name and the .deb Debian's versioned file name.
#
# Exit status is non-zero if any requested target fails to build. Targets that
# simply can't build on this host (no flutter, no Android SDK, app not yet
# scaffolded) are reported as skipped, and only fail the run when you named
# them explicitly.
set -uo pipefail

# Absolute path to this script — usage() must find it after the cd below, even
# when invoked via a relative path from a subdirectory.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PRODUCT_NAME="Klabautermann"
APP_DIR="app/klabautermann_app"
# The preview label of the staged names; dropped at v1 (M7).
ASSET_STEM="klabautermann-preview"
PACKAGE_NAME="klabautermann"
BINARY_NAME="klabautermann"
MACOS_APP_NAME="Klabautermann.app"
SCAFFOLD_HINT="docs/STATUS.md"
ALL_TARGETS=(app apk flatpak)
# A run that names no target builds these; `all` adds the Flatpak.
DEFAULT_TARGETS=(app apk)

# The targets, staging, --install and the summary are shared with
# Séance's and Poltergeist's build.sh.
# shellcheck source=SCRIPTDIR/../../scripts/product-build-common.sh
source "$ROOT/../scripts/product-build-common.sh" || exit 1
product_build_main "$@"
