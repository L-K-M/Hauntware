#!/usr/bin/env bash
# Cuts a release: bumps the `version:` in every pubspec in lockstep (the
# packages + the app once it exists), keeps the app lockfile and the README
# version line in step, commits, tags "v<version>", and with --push pushes
# branch + tag — which triggers .github/workflows/release.yml to test, build
# the app clients (Android APK, Linux/macOS/Windows desktop bundles, unsigned
# iOS IPA), and assemble one hidden draft for local verification and signing.
#
#   scripts/release.sh 0.2.0          # bump pubspecs + README, commit, tag v0.2.0
#   scripts/release.sh 1.0.0-rc1      # pre-release with a lower Android code
#   scripts/release.sh 0.2.0 --push   # also push; CI assembles the hidden draft
#   scripts/release.sh                # tag the current committed version as-is
#
# Usage: scripts/release.sh [X.Y.Z[-betaN|-rcN]] [--push]
# POLTERGEIST_RELEASE_FINGERPRINT must contain the independently published
# OpenPGP primary fingerprint.
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export RELEASE_APP_NAME="Poltergeist"
export RELEASE_KIND="pubspec"
export RELEASE_VERSION_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(beta|rc)([1-9][0-9]*))?$'

VERSION_TOOL="tool/release_version/bin/release_version.dart"
DART_BIN="${DART_BIN:-dart}"
GIT_BIN="${GIT_BIN:-git}"

run_version_tool() {
  (
    cd "$ROOT"
    "$DART_BIN" run "$VERSION_TOOL" "$@"
  )
}

# The Dart parser enforces component and qualifier bounds that Bash ERE cannot.
has_version=false
skip_repository_check=false
for argument in "$@"; do
  case "$argument" in
    --help|-h|--version) skip_repository_check=true ;;
    -*) ;;
    *)
      has_version=true
      command -v "$DART_BIN" >/dev/null 2>&1 || {
        echo "error: Dart SDK not found" >&2
        exit 1
      }
      run_version_tool validate --version "$argument"
      run_version_tool check-transition --version "$argument"
      ;;
  esac
done
if ! $has_version && ! $skip_repository_check; then
  command -v "$DART_BIN" >/dev/null 2>&1 || {
    echo "error: Dart SDK not found" >&2
    exit 1
  }
  run_version_tool check
fi
export RELEASE_DART_BIN="$DART_BIN"

# Every versioned package, tool, and app pubspec stays in release lockstep.
PUBSPECS=""
for p in \
  "$ROOT"/packages/*/pubspec.yaml \
  "$ROOT"/tool/*/pubspec.yaml \
  "$ROOT"/app/*/pubspec.yaml; do
  [[ -f "$p" ]] || continue
  grep -q '^version:' "$p" || continue
  PUBSPECS+="${PUBSPECS:+ }${p#"$ROOT"/}"
done
[[ -n "$PUBSPECS" ]] || { echo "error: no pubspecs found to bump" >&2; exit 1; }
export RELEASE_PUBSPECS="$PUBSPECS"

# The app's committed lockfile pins the workspace packages' versions; keep it
# in step so the post-release `flutter pub get` is a no-op. The package list
# is derived from packages/*/ at run time (directory basename = package name,
# per this repo family's convention), mirroring the RELEASE_PUBSPECS glob, so
# a new workspace package needs no edit here either. Each lockfile entry's
# block ends at its `version:` line, so the range substitution touches
# exactly that line; a package absent from the lockfile makes its range a
# harmless no-op. The engine runs this via bash -c with RELEASE_NEW_VERSION
# exported — hence the single quotes — from the repo root on whatever host
# invoked the stub; probe GNU vs BSD sed exactly like the engine
# (`sed -i ""` is BSD-only syntax, and plain `sed -i` breaks macOS).
# ${RELEASE_NEW_VERSION} expands when the engine runs this, not here. A no-op
# until the app (and its lockfile) exist.
# shellcheck disable=SC2016
export RELEASE_POST_BUMP='
  set -euo pipefail

  "${RELEASE_DART_BIN}" run tool/release_version/bin/release_version.dart \
    sync \
    --version "${RELEASE_NEW_VERSION}" \
    --pubspec app/poltergeist_app/pubspec.yaml

  LOCK=app/poltergeist_app/pubspec.lock
  if [ -f "$LOCK" ]; then
    if sed --version 2>/dev/null | head -n 1 | grep -q "GNU sed"; then
      SED_I=(sed -i)
    else
      SED_I=(sed -i "")
    fi
    SED_EXPRS=()
    for d in packages/*/; do
      pkg="$(basename "$d")"
      SED_EXPRS+=(-e "/^  ${pkg}:/,/^    version:/ s/^(    version: \")[^\"]*(\")/\1${RELEASE_NEW_VERSION}\2/")
    done
    if [ "${#SED_EXPRS[@]}" -gt 0 ]; then
      "${SED_I[@]}" -E "${SED_EXPRS[@]}" "$LOCK"
    fi
  fi

  "${RELEASE_DART_BIN}" run tool/release_version/bin/release_version.dart \
    check \
    --version "${RELEASE_NEW_VERSION}"'
export RELEASE_CI_NOTE="CI (release.yml) will test, build the clients, and assemble a hidden draft for <tag>; finalize it locally with scripts/finalize-release.sh."
export RELEASE_INVOKED_AS="scripts/release.sh"
export RELEASE_SIGN_TAG="required"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}

readonly REQUIRED_SIGNING_FORMAT="openpgp"
# GitHub's draft gate and the local finalizer both require OpenPGP.
git_signing_format="$("$GIT_BIN" -C "$ROOT" config --get gpg.format || true)"
git_signing_format="${git_signing_format:-$REQUIRED_SIGNING_FORMAT}"
if [[ "$git_signing_format" != "$REQUIRED_SIGNING_FORMAT" ]]; then
  echo "error: release tags require OpenPGP; Git uses $git_signing_format" >&2
  exit 1
fi

readonly REQUIRED_TAG_MODE="  tag mode:  signed (required)"
engine_check_output=""
if ! engine_check_output="$("$BIN" --check 2>&1)"; then
  printf '%s\n' "$engine_check_output" >&2
  echo "error: lkm-release 1.1.0+ with signed-tag support is required" >&2
  exit 1
fi
if ! grep -Fqx -- "$REQUIRED_TAG_MODE" <<<"$engine_check_output"; then
  echo "error: lkm-release 1.1.0+ with signed-tag support is required" >&2
  exit 1
fi

if ! $skip_repository_check; then
  readonly FINGERPRINT_PATTERN='^[[:xdigit:]]{40}$'
  readonly SIGNING_PROBE_PREFIX="poltergeist-release-signing-probe"
  release_fingerprint="${POLTERGEIST_RELEASE_FINGERPRINT:-}"
  if [[ ! "$release_fingerprint" =~ $FINGERPRINT_PATTERN ]]; then
    echo "error: set POLTERGEIST_RELEASE_FINGERPRINT to the independently published 40-hex OpenPGP primary fingerprint" >&2
    exit 1
  fi
  release_fingerprint="$(printf '%s' "$release_fingerprint" | tr '[:lower:]' '[:upper:]')"

  signing_probe_tag="${SIGNING_PROBE_PREFIX}-$$-${RANDOM}"
  signing_probe_created=false
  cleanup_signing_probe() {
    if ! $signing_probe_created; then return; fi

    "$GIT_BIN" -C "$ROOT" tag -d "$signing_probe_tag" >/dev/null 2>&1 || true
  }
  trap cleanup_signing_probe EXIT
  trap 'cleanup_signing_probe; exit 1' HUP INT TERM

  if ! "$GIT_BIN" -C "$ROOT" tag -s "$signing_probe_tag" \
    -m "Poltergeist release signing probe" HEAD; then
    echo "error: OpenPGP release signing probe failed" >&2
    exit 1
  fi
  signing_probe_created=true

  signing_probe_output=""
  if ! signing_probe_output="$(
    "$GIT_BIN" -C "$ROOT" verify-tag --raw "$signing_probe_tag" 2>&1
  )"; then
    printf '%s\n' "$signing_probe_output" >&2
    echo "error: OpenPGP release signing probe could not be verified" >&2
    exit 1
  fi
  read -r valid_signature_count signing_fingerprint <<<"$(
    printf '%s\n' "$signing_probe_output" | awk '
      $1 == "[GNUPG:]" && $2 == "VALIDSIG" {
        count++
        fingerprint = NF >= 12 ? $12 : $3
      }
      END { print count + 0, fingerprint }
    '
  )"
  signing_fingerprint="$(
    printf '%s' "$signing_fingerprint" | tr '[:lower:]' '[:upper:]'
  )"
  if [[ "$valid_signature_count" != "1" ||
        ! "$signing_fingerprint" =~ $FINGERPRINT_PATTERN ]]; then
    echo "error: signing probe did not yield one OpenPGP primary fingerprint" >&2
    exit 1
  fi
  if [[ "$signing_fingerprint" != "$release_fingerprint" ]]; then
    echo "error: signing probe was signed with $signing_fingerprint; expected $release_fingerprint" >&2
    exit 1
  fi

  if ! "$GIT_BIN" -C "$ROOT" tag -d "$signing_probe_tag" >/dev/null; then
    echo "error: could not remove the signing probe tag" >&2
    exit 1
  fi
  signing_probe_created=false
  trap - EXIT HUP INT TERM
fi

exec "$BIN" "$@"
