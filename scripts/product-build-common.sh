# shellcheck shell=bash
# The body of the client products' scripts/build.sh: argument parsing, the
# app, apk and flatpak targets, staging into dist/, --install and the
# summary. Séance, Poltergeist and Klabautermann source it; Planchette's
# shorter build.sh is its own. Each wrapper documents its targets, usage
# and outputs in its header comment, which is also what --help prints.
#
# The wrapper runs under `set -uo pipefail` (no -e: a failed target is
# recorded and the run goes on to the summary), cds to ROOT, and sets:
#
#   SELF             absolute path of the wrapper (--help prints its header)
#   ROOT             product root; artifacts are staged in $ROOT/dist
#   PRODUCT_NAME     display name for the banner
#   APP_DIR          the Flutter app, relative to ROOT
#   ASSET_STEM       staged names: <stem>-linux, <stem>-windows, <stem>.apk,
#                    and the AppImage <stem>-linux-<arch>.AppImage
#   PACKAGE_NAME     Debian package name (dist/<name>_*.deb) and the Linux
#                    install directory ~/.local/opt/<name>
#   BINARY_NAME      the Linux bundle's executable, named in the summary
#   MACOS_APP_NAME   staged and installed macOS bundle name
#   SCAFFOLD_HINT    where a missing APP_DIR is explained (read only by
#                    this file's build_app and build_apk)
#   ALL_TARGETS      every target, in build order; `all` selects these
#   DEFAULT_TARGETS  the targets of a run that names none
#
# then sources this file, defines any build_<target> function this file
# lacks or redefines one it has (Séance overrides ensure_platform,
# build_app and build_apk), and calls product_build_main "$@".

PROFILE="release"
INSTALL=false
declare -a REQUESTED=()
EXPLICIT=0

usage() {
  # Print the leading comment block (the file header), minus the shebang.
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SELF"
  exit "${1:-0}"
}

have() { command -v "$1" >/dev/null 2>&1; }

declare -a RESULTS=()
record() { RESULTS+=("$1"); }   # "app: built -> …" | "app: skipped (…)" | "apk: FAILED"

# Collect a finished artifact into dist/ (file or directory). The staged copy
# is what the summary points at — one folder with everything this run built.
DIST="$ROOT/dist"
STAGED=0
stage() {
  local src="$1" name="${2:-$(basename "$1")}"
  mkdir -p "$DIST"
  rm -rf "${DIST:?}/$name"
  cp -R "$src" "$DIST/$name" || return 1
  STAGED=$((STAGED + 1))
  echo "-- staged dist/$name"
}

# Was a given target explicitly named on the command line?
was_named() {
  [[ $EXPLICIT -eq 1 ]] || return 1
  local t
  for t in "${REQUESTED[@]}"; do [[ "$t" == "$1" ]] && return 0; done
  return 1
}

# Skip a target: a soft skip on a default run, a hard error when named.
skip_or_fail() {
  local target="$1" reason="$2"
  if was_named "$target"; then
    echo "!! $target: cannot build on this host — $reason" >&2
    record "$target: FAILED ($reason)"
    return 1
  fi
  echo ".. $target: skipped — $reason"
  record "$target: skipped ($reason)"
  return 0
}

# ---------------------------------------------------------------------------
# Platform folders carry identity, icons, and entitlements. Never replace a
# missing committed scaffold with Flutter's stock output.
ensure_platform() {
  local platform="$1"
  [[ -d "$APP_DIR/$platform" ]] && return 0

  echo "!! $APP_DIR/$platform platform scaffold is missing; restore it from git" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Linux installers (.deb + AppImage) for a just-built bundle. build.sh stays
# the orchestrator; the actual packaging logic lives in package-linux.sh.
package_linux() {
  # Debug builds aren't for distributing, and the .deb needs dpkg-deb.
  if [[ "$PROFILE" != "release" ]]; then
    record "packages: skipped (debug profile)"
    return 0
  fi
  if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo ".. packages: .deb unavailable without dpkg-deb — scripts/package-linux.sh builds the AppImage anyway"
    # No dpkg-deb → package-linux.sh itself falls back to AppImage-only.
  fi
  echo "== packages (deb + AppImage, via scripts/package-linux.sh) =="
  # best-effort AppImage: fetching appimagetool can fail on an offline host,
  # and the local path shouldn't hard-fail on that — CI runs the same script
  # in required mode and catches real breakage.
  if scripts/package-linux.sh --appimage=best-effort; then
    local f staged=""
    for f in dist/"$PACKAGE_NAME"_*.deb dist/"$ASSET_STEM"-linux-*.AppImage; do
      [[ -e "$f" ]] || continue
      record "packages: $(basename "$f") -> dist/"
      staged=1
    done
    [[ -n "$staged" ]] || record "packages: built (nothing staged?)"
  else
    echo "!! packages: package-linux.sh failed" >&2
    record "packages: FAILED"
    return 1
  fi
}

# The newest staged .deb, or nothing.
latest_deb() {
  find dist -maxdepth 1 -type f -name "${PACKAGE_NAME}_*.deb" -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2- || true
}

build_flatpak() {
  if [[ "$HOST" != "linux" ]]; then
    record "flatpak: skipped (Linux only)"
    return 0
  fi
  if ! have flatpak-builder; then
    skip_or_fail flatpak "flatpak-builder not found"; return
  fi
  # Reuse the .deb the app target just packaged; rebuild when absent or
  # stale. (SECONDS is this script's runtime, so `start` is its launch time.)
  local deb start
  start=$(( $(date +%s) - SECONDS ))
  deb="$(latest_deb)"
  if [[ -z "$deb" || "$(stat -c %Y "$deb" 2>/dev/null || echo 0)" -lt "$start" ]]; then
    build_app || { record "flatpak: FAILED (app build)"; return 1; }
    deb="$(latest_deb)"
    if [[ -z "$deb" || "$(stat -c %Y "$deb" 2>/dev/null || echo 0)" -lt "$start" ]]; then
      record "flatpak: FAILED (no fresh .deb produced; a release 'app' build is required)"
      return 1
    fi
  fi
  if scripts/build-flatpak.sh "$deb"; then
    record "flatpak: built -> dist/"
  else
    record "flatpak: FAILED (repack)"
    return 1
  fi
}

# Stage the app `flutter build` just produced ($1 is the Xcode/MSBuild
# configuration), package it on Linux, and install it under --install.
finish_app() {
  local cfg="$1" out="" name=""
  # Stage the final product; the nested output path differs per platform
  # (and per arch on linux), so glob for it.
  case "$HOST" in
    macos)
      out=$(ls -d "$APP_DIR"/build/macos/Build/Products/"$cfg"/*.app 2>/dev/null | head -1)
      name="$MACOS_APP_NAME"
      ;;
    linux)
      out=$(ls -d "$APP_DIR"/build/linux/*/"$PROFILE"/bundle 2>/dev/null | head -1)
      name="$ASSET_STEM-linux"
      ;;
    windows)
      out=$(ls -d "$APP_DIR"/build/windows/*/runner/"$cfg" 2>/dev/null | head -1)
      name="$ASSET_STEM-windows"
      ;;
  esac
  if [[ -n "$out" ]] && ! stage "$out" "$name"; then
    echo "!! app: copying the build into dist/ failed" >&2
    record "app: FAILED (copy to dist/)"; return 1
  fi
  if [[ -n "$out" ]]; then
    record "app: built ($HOST, $PROFILE) -> dist/"
  else
    record "app: built ($HOST, $PROFILE) — product not found to stage"
  fi
  # Propagate packaging failure to the exit status (FAILED is the global the
  # target loop reads) while still letting a subsequent --install proceed —
  # installing the freshly built bundle is independent of .deb/AppImage
  # packaging.
  if [[ "$HOST" == "linux" ]]; then package_linux || FAILED=1; fi
  if $INSTALL; then
    if [[ -z "$out" ]]; then
      echo "!! app: nothing to install (product not found)" >&2
      record "app: install FAILED (product not found)"; return 1
    fi
    case "$HOST" in
      macos)
        echo "-- installing /Applications/$MACOS_APP_NAME"
        rm -rf "/Applications/${MACOS_APP_NAME:?}"
        # ditto preserves the signature, resource forks, and permissions.
        if ditto "$out" "/Applications/$MACOS_APP_NAME"; then
          INSTALLED="/Applications/$MACOS_APP_NAME"
          record "app: installed -> /Applications/$MACOS_APP_NAME"
          # Replacing a bundle in place leaves LaunchServices with the OLD
          # registration for the path (e.g. a renamed CFBundleExecutable);
          # it then refuses to open the app with error -10810 even though
          # the bundle runs fine. Force a re-registration on every install.
          LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
          if [[ -x "$LSREG" ]]; then
            "$LSREG" -f "$INSTALLED" >/dev/null 2>&1 || true
          fi
          # Post-install sanity: surface the known "can't be opened" causes
          # here, instead of leaving Finder's generic refusal as the only
          # signal.
          local verify_output
          if ! verify_output=$(codesign --verify --deep --strict --verbose=2 "$INSTALLED" 2>&1); then
            echo "!! app: $INSTALLED fails codesign verification — it will not launch." >&2
            sed 's/^/   /' <<<"$verify_output" >&2
            record "app: WARNING — installed app fails codesign verify"
          fi
          if codesign -d --entitlements - "$INSTALLED" 2>/dev/null \
              | grep -q keychain-access-groups; then
            echo "!! app: the installed build still carries the restricted" >&2
            echo "   keychain-access-groups entitlement, which blocks ad-hoc-signed" >&2
            echo "   launches — the checkout or build is stale. Fix with:" >&2
            echo "     git pull && (cd $APP_DIR && flutter clean) && scripts/build.sh --install" >&2
            record "app: WARNING — stale build with keychain-access-groups"
          fi
        else
          record "app: install FAILED (ditto)"; return 1
        fi
        ;;
      linux)
        echo "-- installing $HOME/.local/opt/$PACKAGE_NAME"
        rm -rf "$HOME/.local/opt/$PACKAGE_NAME" && mkdir -p "$HOME/.local/opt"
        if cp -R "$out" "$HOME/.local/opt/$PACKAGE_NAME"; then
          INSTALLED="$HOME/.local/opt/$PACKAGE_NAME"
          record "app: installed -> ~/.local/opt/$PACKAGE_NAME (binary: $BINARY_NAME)"
        else
          record "app: install FAILED (copy)"; return 1
        fi
        ;;
      *)
        echo "!! app: --install is not supported on $HOST" >&2
        record "app: install FAILED (unsupported on $HOST)"; return 1
        ;;
    esac
  fi
}

build_app() {
  echo "== app (Flutter desktop, this host) =="
  if [[ "$HOST" == "unknown" ]]; then
    skip_or_fail app "unrecognized host platform"; return
  fi
  if [[ ! -d "$APP_DIR" ]]; then
    skip_or_fail app "$APP_DIR not scaffolded yet (see $SCAFFOLD_HINT)"; return
  fi
  if ! have flutter; then skip_or_fail app "Flutter SDK (flutter) not found"; return; fi
  if ! ensure_platform "$HOST"; then
    record "app: FAILED (platform scaffold missing)"; return 1
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
    rm -rf "$APP_DIR"/build/macos/Build/Products/"$cfg"/*.app
  fi
  echo "-- flutter build $HOST ${mode_flag}"
  if ( cd "$APP_DIR" && flutter pub get && flutter build "$HOST" $mode_flag ); then
    finish_app "$cfg"
  else
    echo "!! app: flutter build $HOST failed" >&2
    record "app: FAILED (flutter build $HOST)"; return 1
  fi
}

# ---------------------------------------------------------------------------
# An installed Android SDK is what separates "can build the APK" from a long
# doomed Gradle run; probe the usual locations like `flutter doctor` does.
detect_android_sdk() {
  local c
  for c in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" \
           "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    [[ -n "$c" && -d "$c/platforms" ]] && { echo "$c"; return 0; }
  done
  return 1
}

# Build the APK in $APP_DIR and stage it as dist/<stem>.apk.
flutter_build_apk() {
  local mode_flag=""
  [[ "$PROFILE" == "debug" ]] && mode_flag="--debug"
  echo "-- flutter build apk ${mode_flag}"
  if ( cd "$APP_DIR" && flutter pub get && flutter build apk $mode_flag ); then
    # Named by profile: Flutter leaves the other profile's APK beside it.
    local apk="$APP_DIR/build/app/outputs/flutter-apk/app-$PROFILE.apk"
    if [[ ! -f "$apk" ]]; then
      echo "!! apk: flutter build apk produced no app-$PROFILE.apk" >&2
      record "apk: FAILED (no app-$PROFILE.apk)"; return 1
    fi
    if ! stage "$apk" "$ASSET_STEM.apk"; then
      echo "!! apk: copying the APK into dist/ failed" >&2
      record "apk: FAILED (copy to dist/)"; return 1
    fi
    record "apk: built ($PROFILE) -> dist/$ASSET_STEM.apk"
  else
    echo "!! apk: flutter build apk failed" >&2
    record "apk: FAILED (flutter build apk)"; return 1
  fi
}

build_apk() {
  echo "== apk (Android) =="
  if [[ ! -d "$APP_DIR" ]]; then
    skip_or_fail apk "$APP_DIR not scaffolded yet (see $SCAFFOLD_HINT)"; return
  fi
  if ! have flutter; then skip_or_fail apk "Flutter SDK (flutter) not found"; return; fi
  local sdk
  if ! sdk="$(detect_android_sdk)"; then
    skip_or_fail apk "no Android SDK found (set ANDROID_SDK_ROOT, or install one via Android Studio)"; return
  fi
  echo "-- Android SDK: $sdk"
  if ! ensure_platform android; then
    record "apk: FAILED (platform scaffold missing)"; return 1
  fi
  flutter_build_apk
}

# ---------------------------------------------------------------------------
product_build_main() {
  local t
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage 0 ;;
      --debug) PROFILE="debug"; shift ;;
      --install) INSTALL=true; shift ;;
      all) REQUESTED=("${ALL_TARGETS[@]}"); EXPLICIT=1; shift ;;
      *)
        for t in "${ALL_TARGETS[@]}"; do
          [[ "$1" == "$t" ]] || continue
          REQUESTED+=("$1"); EXPLICIT=1; shift; continue 2
        done
        echo "unknown argument: $1" >&2; usage 1
        ;;
    esac
  done

  # --install is about the host platform's app: with no explicit targets it
  # builds just that (not the whole matrix), and with explicit targets it makes
  # sure `app` is among them.
  if $INSTALL; then
    if [[ ${#REQUESTED[@]} -eq 0 ]]; then
      REQUESTED=(app); EXPLICIT=1
    else
      local found=0
      for t in "${REQUESTED[@]}"; do [[ "$t" == "app" ]] && found=1; done
      [[ $found -eq 0 ]] && REQUESTED+=(app)
    fi
  fi

  # Feasibility of the default targets is decided per target below.
  if [[ ${#REQUESTED[@]} -eq 0 ]]; then
    REQUESTED=("${DEFAULT_TARGETS[@]}")
  fi

  case "$(uname -s)" in
    Darwin) HOST="macos" ;;
    Linux) HOST="linux" ;;
    MINGW*|MSYS*|CYGWIN*) HOST="windows" ;;
    *) HOST="unknown" ;;
  esac

  echo "$PRODUCT_NAME build"
  echo "  host:    $HOST ($(uname -s))"
  echo "  profile: $PROFILE"
  echo "  targets: ${REQUESTED[*]}"
  echo

  FAILED=0
  INSTALLED=""
  local target line
  for target in "${REQUESTED[@]}"; do
    "build_$target" || FAILED=1
    echo
  done

  echo "Summary"
  for line in "${RESULTS[@]}"; do echo "  $line"; done

  # Reveal the result: the installed copy when --install ran, else the dist/
  # folder with everything this run produced (macOS only — elsewhere the paths
  # in the summary are the deliverable).
  # Under the root scripts/build.sh the root reveals the whole run instead.
  if [[ -n "${HAUNTWARE_BUILD_ORCHESTRATED:-}" ]]; then
    [[ -n "$INSTALLED" ]] && echo "  installed: $INSTALLED"
    [[ "$STAGED" -gt 0 ]] && echo "  artifacts: $DIST"
  elif [[ -n "$INSTALLED" ]]; then
    echo "  installed: $INSTALLED"
    if [[ "$(uname -s)" == "Darwin" ]]; then
      open -R "$INSTALLED"          # Finder, with the app selected
    elif have xdg-open; then
      xdg-open "$INSTALLED" >/dev/null 2>&1 || true
    fi
  elif [[ "$STAGED" -gt 0 ]]; then
    echo "  artifacts: $DIST"
    if [[ "$(uname -s)" == "Darwin" ]]; then open "$DIST"; fi
  fi

  exit "$FAILED"
}
