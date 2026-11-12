#!/usr/bin/env bash
#
# Build every Séance target this host can build, and print one clear summary.
# The single local entry point; CI builds the same targets in
# .github/workflows/ci.yml and release.yml.
#
#   server — sync server as a native binary (dart compile exe) → build/seance-sync
#   docker — sync-server image (packages/seance_sync_server/Dockerfile, build
#            context = repo root) → seance-sync:local
#   app    — Flutter desktop app for THIS host (linux/macos/windows); platform
#            folders are committed (missing ones are regenerated as a fallback).
#            On Linux, release builds are also packaged into installable
#            artifacts (.deb + AppImage) via scripts/package-linux.sh → dist/
#   apk    — Android APK (needs flutter + an Android SDK)
#   flatpak — repack the app's .deb as a Flatpak bundle (Linux; runs the
#            app target first when no dist/ .deb exists yet)
#
# Usage:
#   scripts/build.sh                 # every target this host can build
#   scripts/build.sh server docker   # just these (naming a target turns an
#                                    # infeasible target into an error, not a skip)
#   scripts/build.sh --debug app     # debug-mode Flutter builds (server/docker
#                                    # have no debug variant; flag ignored there)
#   scripts/build.sh --install       # build the app for THIS host and install
#                                    # it (macOS: /Applications/Séance.app;
#                                    # Linux: ~/.local/opt/seance), then reveal
#                                    # the installed copy
#
# Every produced file (server binary, .app bundle, APK, …) is also copied into
# dist/ at the repo root — one folder with the final artifacts — and on macOS
# dist/ is opened in the Finder when anything landed there.
#
# Exit status is non-zero if any requested target fails to build. Targets that
# simply can't build on this host (no dart/flutter/docker, no Android SDK) are
# reported as skipped, and only fail the run when you named them explicitly.
set -uo pipefail

# Absolute path to this script — usage() must find it after the cd below, even
# when invoked via a relative path from a subdirectory.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

PRODUCT_NAME="Séance"
APP_DIR="app/seance_app"
ASSET_STEM="seance"
PACKAGE_NAME="seance"
BINARY_NAME="seance_app"
# Xcode signs the ASCII "Seance.app" (codesign rejects accented file
# names); the user-facing copy is renamed — safe, the wrapper name
# isn't part of the signature seal.
MACOS_APP_NAME="Séance.app"
ALL_TARGETS=(server docker app apk flatpak)
DEFAULT_TARGETS=(server docker app apk flatpak)

# Argument handling, staging, the flatpak target, --install and the
# summary are shared with Poltergeist's and Klabautermann's build.sh.
# Séance adds the server and docker targets, and its app and apk targets
# below keep the CocoaPods check, the Apple configuration backup, the
# macOS signing fallback and the `flutter create` fallback for a missing
# platform folder.
# shellcheck source=SCRIPTDIR/../../scripts/product-build-common.sh
source "$ROOT/../scripts/product-build-common.sh" || exit 1

# `dart pub get` for the workspace, once, shared by targets that need it.
PUB_RESOLVED=0
resolve_workspace() {
  [[ $PUB_RESOLVED -eq 1 ]] && return 0
  echo "-- dart pub get (workspace)"
  dart pub get || return 1
  PUB_RESOLVED=1
}

# ---------------------------------------------------------------------------
build_server() {
  echo "== server (native sync-server binary) =="
  if ! have dart; then skip_or_fail server "Dart SDK (dart) not found"; return; fi
  if ! resolve_workspace; then
    echo "!! server: dart pub get failed" >&2
    record "server: FAILED (pub get)"; return 1
  fi
  local exe="build/seance-sync"
  [[ "$HOST" == "windows" ]] && exe="build/seance-sync.exe"
  mkdir -p build
  echo "-- dart compile exe → $exe"
  if dart compile exe packages/seance_sync_server/bin/seance_sync_server.dart -o "$exe"; then
    if ! stage "$exe"; then
      echo "!! server: copying the binary into dist/ failed" >&2
      record "server: FAILED (copy to dist/)"; return 1
    fi
    record "server: built -> dist/$(basename "$exe")"
  else
    echo "!! server: dart compile exe failed" >&2
    record "server: FAILED (compile)"; return 1
  fi
}

# ---------------------------------------------------------------------------
build_docker() {
  echo "== docker (sync-server image) =="
  if ! have docker; then skip_or_fail docker "docker not found"; return; fi
  if ! docker info >/dev/null 2>&1; then
    skip_or_fail docker "docker daemon not reachable"; return
  fi
  # Build context MUST be the repo root so the pub workspace resolves.
  echo "-- docker build → seance-sync:local"
  if docker build -f packages/seance_sync_server/Dockerfile -t seance-sync:local .; then
    record "docker: built -> seance-sync:local"
  else
    echo "!! docker: image build failed" >&2
    record "docker: FAILED (docker build)"; return 1
  fi
}

# ---------------------------------------------------------------------------
# Flutter prepares both Apple platforms during pub get, then CocoaPods edits
# the macOS project in place. Keep only these integration files at their
# pre-build state, including local edits; never reset the checkout with Git.
APPLE_CONFIG_BACKUP=""
declare -a APPLE_CONFIG_PATHS=()

restore_apple_configs() {
  local status=$? index relative path failed=0
  trap - EXIT
  for ((index=0; index<${#APPLE_CONFIG_PATHS[@]}; index++)); do
    relative="${APPLE_CONFIG_PATHS[$index]}"
    path="$ROOT/app/seance_app/$relative"
    # Unlink first so a build-created symlink cannot redirect the restore.
    if ! rm -f "$path"; then
      failed=1
      continue
    fi
    if [[ -f "$APPLE_CONFIG_BACKUP/$relative" ]]; then
      if ! cp -p "$APPLE_CONFIG_BACKUP/$relative" "$path"; then failed=1; fi
    fi
  done
  if [[ $failed -ne 0 ]]; then
    echo "!! Apple configuration cleanup failed; originals saved in $APPLE_CONFIG_BACKUP" >&2
    [[ $status -ne 0 ]] || status=1
  elif ! rm -rf "$APPLE_CONFIG_BACKUP"; then
    echo "!! Could not remove Apple configuration backup: $APPLE_CONFIG_BACKUP" >&2
    [[ $status -ne 0 ]] || status=1
  fi
  exit "$status"
}

preserve_apple_configs() {
  [[ "$HOST" == "macos" ]] || return 0
  [[ -z "$APPLE_CONFIG_BACKUP" ]] || return 0
  local platform relative path backup_path debug_config release_config
  if ! APPLE_CONFIG_BACKUP=$(mktemp -d "${TMPDIR:-/tmp}/seance-apple-config.XXXXXX"); then
    echo "!! Could not create Apple configuration backup" >&2
    return 1
  fi
  for platform in ios macos; do
    # A missing platform folder is intentionally generated by ensure_platform;
    # retain that scaffolding rather than leaving a partly deleted new project.
    [[ -d "app/seance_app/$platform" ]] || continue
    if [[ "$platform" == ios ]]; then
      debug_config=Flutter/Debug.xcconfig
      release_config=Flutter/Release.xcconfig
    else
      debug_config=Flutter/Flutter-Debug.xcconfig
      release_config=Flutter/Flutter-Release.xcconfig
    fi
    for relative in Podfile Podfile.lock Runner.xcodeproj/project.pbxproj \
        Runner.xcworkspace/contents.xcworkspacedata \
        "$debug_config" "$release_config"; do
      path="app/seance_app/$platform/$relative"
      backup_path="$APPLE_CONFIG_BACKUP/$platform/$relative"
      # Flutter can write through symlinks, outside this fixed cleanup set.
      if [[ -L "$path" || ( -e "$path" && ! -f "$path" ) ]]; then
        echo "!! Cannot preserve Apple configuration that is not a regular file: $path" >&2
        rm -rf "$APPLE_CONFIG_BACKUP"
        APPLE_CONFIG_BACKUP=""
        APPLE_CONFIG_PATHS=()
        return 1
      fi
      if [[ -f "$path" ]] && ! { mkdir -p "$(dirname "$backup_path")" && cp -p "$path" "$backup_path"; }; then
        echo "!! Could not back up Apple configuration: $path" >&2
        rm -rf "$APPLE_CONFIG_BACKUP"
        APPLE_CONFIG_BACKUP=""
        APPLE_CONFIG_PATHS=()
        return 1
      fi
      APPLE_CONFIG_PATHS+=("$platform/$relative")
    done
  done
  trap restore_apple_configs EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# A valid code-signing identity's common-name suffix is the developer's
# personal ID, not necessarily the project's team. Resolve each identity's
# certificate and compare its subject OU with DEVELOPMENT_TEAM instead.
has_apple_development_identity_for_team() {
  local team="$1" identities line common certificate subject
  if ! identities="$(security find-identity -v -p codesigning 2>/dev/null)"; then
    return 1
  fi
  while IFS= read -r line; do
    common="${line#*\"}"
    [[ "$common" != "$line" ]] || continue
    common="${common%%\"*}"
    [[ "$common" == "Apple Development:"* ]] || continue
    if ! certificate="$(security find-certificate -c "$common" -p 2>/dev/null)"; then
      continue
    fi
    if ! subject="$(printf '%s\n' "$certificate" \
        | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null)"; then
      continue
    fi
    case ",${subject#subject=}," in
      *",OU=$team,"*) return 0 ;;
    esac
  done <<< "$identities"
  return 1
}

# Keep a contributor's matching Apple Development identity so permissions
# survive rebuilds. The committed project is the only configuration eligible
# for fallback: custom, Developer ID, and already ad-hoc signing stay intact.
prepare_macos_signing() {
  [[ "$HOST" == "macos" ]] || return 0
  local project="app/seance_app/macos/Runner.xcodeproj/project.pbxproj"
  local identities teams team patched
  if [[ ! -f "$project" ]]; then
    echo "!! macOS signing project is missing: $project" >&2
    return 1
  fi

  identities="$(sed -n \
    's/^[[:space:]]*"CODE_SIGN_IDENTITY\[sdk=macosx\*\]" = "\([^"]*\)";.*/\1/p' \
    "$project" | sort -u)"
  # No stock identity, or any custom/ad-hoc identity: do not rewrite it.
  [[ "$identities" == "Apple Development" ]] || return 0

  teams="$(sed -n \
    's/^[[:space:]]*DEVELOPMENT_TEAM = \([^;]*\);.*/\1/p' "$project" \
    | tr -d '"' | sort -u)"
  if [[ -z "$teams" || "$teams" == *$'\n'* ]]; then
    echo ".. macOS signing: preserving ambiguous custom team configuration"
    return 0
  fi
  team="$teams"

  # Every block that requests Apple Development must use the same automatic
  # team configuration. A manual or mixed block is a custom setup.
  if ! awk -v team="$team" '
    /buildSettings = \{/ {
      in_block = 1; has_identity = 0; automatic = 0; team_ok = 0; next
    }
    in_block && /"CODE_SIGN_IDENTITY\[sdk=macosx\*\]" = "Apple Development";/ {
      has_identity = 1
    }
    in_block && /CODE_SIGN_STYLE = Automatic;/ { automatic = 1 }
    in_block && index($0, "DEVELOPMENT_TEAM = " team ";") { team_ok = 1 }
    in_block && /^[[:space:]]*};/ {
      if (has_identity) {
        count++
        if (!automatic || !team_ok) bad = 1
      }
      in_block = 0
    }
    END { exit(count > 0 && !bad ? 0 : 1) }
  ' "$project"; then
    echo ".. macOS signing: preserving custom Apple Development configuration"
    return 0
  fi

  if has_apple_development_identity_for_team "$team"; then
    echo "-- macOS signing: using Apple Development identity for team $team"
    return 0
  fi

  echo "-- macOS signing: no valid Apple Development identity for team $team; using temporary ad-hoc signing"
  patched="$APPLE_CONFIG_BACKUP/ad-hoc-project.pbxproj"
  if ! sed \
      -e 's/"CODE_SIGN_IDENTITY\[sdk=macosx\*\]" = "Apple Development";/"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";/g' \
      -e 's/CODE_SIGN_STYLE = Automatic;/CODE_SIGN_STYLE = Manual;/g' \
      -e 's/DEVELOPMENT_TEAM = [^;]*;/DEVELOPMENT_TEAM = "";/g' \
      "$project" > "$patched"; then
    echo "!! Could not prepare temporary ad-hoc macOS signing" >&2
    return 1
  fi
  if grep -Fq '"CODE_SIGN_IDENTITY[sdk=macosx*]" = "Apple Development";' "$patched" \
      || grep -Fq 'CODE_SIGN_STYLE = Automatic;' "$patched" \
      || ! grep -Fq '"CODE_SIGN_IDENTITY[sdk=macosx*]" = "-";' "$patched"; then
    echo "!! Temporary ad-hoc signing did not replace the expected project settings" >&2
    return 1
  fi
  if ! cp "$patched" "$project"; then
    echo "!! Could not install temporary ad-hoc macOS signing" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# The platform folders are committed (they carry the app name, icons, and
# entitlements — AGENTS.md §3); regenerating here is only a fallback for a
# deleted folder, and such a regenerated folder loses those customizations.
ensure_platform() {
  local platform="$1"
  [[ -d "app/seance_app/$platform" ]] && return 0
  echo "-- platform folder app/seance_app/$platform missing; generating (flutter create)"
  ( cd app/seance_app && flutter create --platforms="$platform" --project-name seance_app . )
}

build_app() {
  echo "== app (Flutter desktop, this host) =="
  if [[ "$HOST" == "unknown" ]]; then
    skip_or_fail app "unrecognized host platform"; return
  fi
  if ! have flutter; then skip_or_fail app "Flutter SDK (flutter) not found"; return; fi
  # The vendored flutter_pty ships only a podspec (no Swift Package Manager
  # manifest), so Flutter integrates it through CocoaPods even though every
  # other plugin comes through SwiftPM. Without `pod` the build fails late
  # with a bare "CocoaPods not installed".
  if [[ "$HOST" == "macos" ]] && ! have pod; then
    skip_or_fail app "CocoaPods (pod) not found; flutter_pty needs it (brew install cocoapods)"
    return
  fi
  if ! preserve_apple_configs; then
    record "app: FAILED (Apple configuration backup)"; return 1
  fi
  if ! ensure_platform "$HOST"; then
    echo "!! app: flutter create failed" >&2
    record "app: FAILED (flutter create)"; return 1
  fi
  local mode_flag=""
  [[ "$PROFILE" == "debug" ]] && mode_flag="--debug"
  local cfg="Release"
  [[ "$PROFILE" == "debug" ]] && cfg="Debug"
  # Xcode re-signs an existing .app only when one of its own inputs
  # changed, but Flutter's embed phase rewrites App.framework and the
  # native-asset frameworks afterwards. An incremental build can then keep
  # a stale outer seal (codesign: "a sealed resource is missing or
  # invalid") and the old bundle date. Deleting the previous bundle makes
  # Xcode assemble and sign it afresh; compiled code stays cached.
  if [[ "$HOST" == "macos" ]]; then
    rm -rf app/seance_app/build/macos/Build/Products/"$cfg"/*.app
  fi
  echo "-- flutter pub get"
  if ! ( cd app/seance_app && flutter pub get ); then
    echo "!! app: flutter pub get failed" >&2
    record "app: FAILED (flutter pub get)"; return 1
  fi
  if ! prepare_macos_signing; then
    record "app: FAILED (macOS signing setup)"; return 1
  fi
  echo "-- flutter build $HOST ${mode_flag}"
  if ( cd app/seance_app && flutter build "$HOST" $mode_flag ); then
    finish_app "$cfg"
  else
    echo "!! app: flutter build $HOST failed" >&2
    record "app: FAILED (flutter build $HOST)"; return 1
  fi
}

build_apk() {
  echo "== apk (Android) =="
  if ! have flutter; then skip_or_fail apk "Flutter SDK (flutter) not found"; return; fi
  local sdk
  if ! sdk="$(detect_android_sdk)"; then
    skip_or_fail apk "no Android SDK found (set ANDROID_SDK_ROOT, or install one via Android Studio)"; return
  fi
  echo "-- Android SDK: $sdk"
  if ! preserve_apple_configs; then
    record "apk: FAILED (Apple configuration backup)"; return 1
  fi
  if ! ensure_platform android; then
    echo "!! apk: flutter create failed" >&2
    record "apk: FAILED (flutter create)"; return 1
  fi
  flutter_build_apk
}

product_build_main "$@"
