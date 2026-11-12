#!/usr/bin/env bash
#
# Build every Poltergeist target this host can build, and print one clear
# summary. The single local entry point; CI builds the same targets in
# .github/workflows/ci.yml and release.yml. Poltergeist has no server
# component, so unlike Séance's build.sh there are only client targets:
#
#   app    — Flutter desktop app for THIS host (linux/macos/windows); platform
#            folders are committed once the app is scaffolded. On Linux,
#            release builds are also packaged into installable artifacts
#            (.deb + AppImage) via
#            scripts/package-linux.sh → dist/
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
#                                    # it (macOS: /Applications/Poltergeist.app;
#                                    # Linux: ~/.local/opt/poltergeist), then
#                                    # reveal the installed copy
#
# Every produced file (.app bundle, APK, …) is also copied into dist/ at the
# repo root — one folder with the final artifacts — and on macOS dist/ is
# opened in the Finder when anything landed there.
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

PRODUCT_NAME="Poltergeist"
APP_DIR="app/poltergeist_app"
ASSET_STEM="poltergeist"
PACKAGE_NAME="poltergeist"
BINARY_NAME="poltergeist"
MACOS_APP_NAME="Poltergeist.app"
SCAFFOLD_HINT="docs/plan/"
ALL_TARGETS=(app apk flatpak)
# A run that names no target builds these; `all` adds the Flatpak.
DEFAULT_TARGETS=(app apk)

# The targets, staging, --install and the summary are shared with
# Séance's and Klabautermann's build.sh.
# shellcheck source=SCRIPTDIR/../../scripts/product-build-common.sh
source "$ROOT/../scripts/product-build-common.sh" || exit 1
product_build_main "$@"
