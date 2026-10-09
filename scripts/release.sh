#!/usr/bin/env bash
# Cuts the coordinated Hauntware suite release: bumps `version:` in the
# root manifest and every owned pubspec in lockstep, commits, tags
# "v<version>", and with --push pushes branch + tag — which triggers
# .github/workflows/release.yml to build every client and the Séance
# sync server and publish the GitHub Release.
#
#   scripts/release.sh 1.2.0          # bump + commit, tag v1.2.0
#   scripts/release.sh 1.2.0 --push   # …also push (CI then publishes)
#   scripts/release.sh                # tag the current committed version
#   scripts/release.sh --check        # resolved config + tree consistency
#
# Usage: scripts/release.sh [X.Y.Z] [--push|--check]
# Shared engine: https://github.com/L-K-M/release-tool — this stub wires
# the suite configuration only; tool/release_version owns the contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export RELEASE_APP_NAME="Hauntware"
export RELEASE_KIND="pubspec"
export RELEASE_VERSION_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

DART_BIN="${DART_BIN:-dart}"
VERSION_TOOL="tool/release_version/bin/release_version.dart"
run_version_tool() { (cd "$ROOT" && "$DART_BIN" run "$VERSION_TOOL" "$@"); }

# Which engine entry points need the version tool resolved first.
has_version=false
requested_version=""
check_only=false
tool_free=false
for argument in "$@"; do
  case "$argument" in
    --check) check_only=true ;;
    --help|-h|--version) tool_free=true ;;
    -*) ;;
    *)
      if $has_version; then
        echo "error: only one release version is allowed" >&2
        exit 1
      fi
      has_version=true
      requested_version="$argument" ;;
  esac
done

if ! $tool_free; then
  command -v "$DART_BIN" >/dev/null 2>&1 || {
    echo "error: Dart SDK not found" >&2
    exit 1
  }
  if $check_only; then
    run_version_tool check
  else
    preflight_arguments=(preflight)
    $has_version && preflight_arguments+=(--version "$requested_version")
    run_version_tool "${preflight_arguments[@]}"
  fi
  RELEASE_PUBSPECS="$(run_version_tool pubspecs)"
  export RELEASE_PUBSPECS
fi
# `--help`/`--version` reach the engine without the tool; the variable
# still must exist for `set -u` consumers.
export RELEASE_PUBSPECS="${RELEASE_PUBSPECS:-}"

export RELEASE_DART_BIN="$DART_BIN"
# The hook runs the tool file directly (not `dart run`) so its package
# resolution walks up from the file's location — correct no matter which
# directory the engine runs the hook from.
# shellcheck disable=SC2016 # The engine expands hook variables at invocation.
export RELEASE_POST_BUMP='"${RELEASE_DART_BIN}" "'"$ROOT"'/tool/release_version/bin/release_version.dart" post-bump --version "${RELEASE_NEW_VERSION}"'
# The pre-tag hook refreshes the Séance release-audit record and commits it;
# the engine then tags whatever HEAD the hook leaves. DART_EXECUTABLE hands
# the configured Dart binary to the audit driver.
# shellcheck disable=SC2016 # The engine expands hook variables at invocation.
export RELEASE_PRE_TAG='DART_EXECUTABLE="${RELEASE_DART_BIN}" "'"$ROOT"'/scripts/refresh-seance-release-audit.sh"'
export RELEASE_CI_NOTE="CI (release.yml) will now test, build every client (Planchette desktop, the Séance and Poltergeist apps incl. APK/IPA) plus the Séance sync server + Docker image, and publish the GitHub Release for <tag>."
export RELEASE_INVOKED_AS="scripts/release.sh"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}
# An engine too old for RELEASE_PRE_TAG would run the release while silently
# ignoring the audit hook — worse than refusing. Probe support before the
# engine gets to mutate; read-only entry points never reach the hook, so
# they skip the probe entirely.
if ! $tool_free && ! $check_only; then
  capabilities=$("$BIN" --capabilities) || {
    echo "error: $BIN did not report RELEASE_PRE_TAG — update lkm-release before releasing" >&2
    exit 1
  }
  grep -qx 'RELEASE_PRE_TAG' <<<"$capabilities" || {
    echo "error: $BIN does not support RELEASE_PRE_TAG — update lkm-release before releasing" >&2
    exit 1
  }
fi
cd "$ROOT"
exec "$BIN" "$@"
