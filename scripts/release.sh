#!/usr/bin/env bash
# Cuts a release: bumps the `version:` in every pubspec in lockstep (the
# packages + the app once it exists), keeps the committed lockfiles and the
# README version line in step, commits, tags "v<version>", and with --push
# pushes branch + tag — which triggers .github/workflows/release.yml to test,
# build the app clients (Android APK, Linux/macOS/Windows desktop bundles,
# unsigned iOS IPA), and publish the GitHub Release.
#
#   scripts/release.sh 0.2.0          # bump pubspecs + README, commit, tag v0.2.0
#   scripts/release.sh 0.2.0 --push   # …also push the commit + tag (CI then publishes)
#   scripts/release.sh                # tag the current committed version as-is
#
# Usage: scripts/release.sh [X.Y.Z] [--push]
# Shared engine: https://github.com/L-K-M/release-tool (this stub only sets config).
#
# Note: Séance/Poltergeist run a Dart pre-flight (tool/release_version) that
# validates the version shape and orders it against prior tags. This stub
# skips that — it isn't ported yet because Planchette has no tool/ directory;
# the engine's own checks still apply.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export RELEASE_APP_NAME="Planchette"
export RELEASE_KIND="pubspec"
export RELEASE_VERSION_REGEX='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

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

# Every committed lockfile that path-depends on a package the release bumps
# pins that package's version. Keep them in step so the post-release
# `dart pub get` is a no-op. The locks are the ones beside the pubspecs bumped
# above (packages/*, tool/*, app/*); the pinned packages are read by their
# `name:`, not their directory. The app is left out of pinning: its version
# carries a build code and nothing depends on it — when app/planchette_app
# exists with a `version: X.Y.Z+N` line, port the siblings' sync step
# (tool/release_version) so the engine's bump does not drop the +N.
# Each lockfile entry's block ends at its `version:` line, so the range
# substitution touches exactly that line; a package absent from a lockfile
# makes its range a harmless no-op. The engine runs this via bash -c with
# RELEASE_NEW_VERSION exported — hence the single quotes — from the repo root
# on whatever host invoked the stub, then commits every tracked file it
# changed (`git commit -am`); probe GNU vs BSD sed exactly like the engine
# (`sed -i ""` is BSD-only syntax, and plain `sed -i` breaks macOS).
# ${RELEASE_NEW_VERSION} expands when the engine runs this, not here.
# shellcheck disable=SC2016
export RELEASE_POST_BUMP='
  set -euo pipefail

  if sed --version 2>/dev/null | head -n 1 | grep -q "GNU sed"; then
    SED_I=(sed -i)
  else
    SED_I=(sed -i "")
  fi
  SED_EXPRS=()
  for pubspec in packages/*/pubspec.yaml tool/*/pubspec.yaml; do
    [ -f "$pubspec" ] || continue
    grep -q "^version:" "$pubspec" || continue
    pkg="$(sed -n -E "s/^name:[[:space:]]*([A-Za-z0-9_]+).*/\1/p" "$pubspec")"
    [ -n "$pkg" ] || continue
    SED_EXPRS+=(-e "/^  ${pkg}:/,/^    version:/ s/^(    version: \")[^\"]*(\")/\1${RELEASE_NEW_VERSION}\2/")
  done
  if [ "${#SED_EXPRS[@]}" -gt 0 ]; then
    # One lock per call, so no range carries over into the next file.
    for lock in packages/*/pubspec.lock tool/*/pubspec.lock app/*/pubspec.lock; do
      [ -f "$lock" ] || continue
      "${SED_I[@]}" -E "${SED_EXPRS[@]}" "$lock"
    done
  fi'
export RELEASE_CI_NOTE="CI (release.yml) will now test, build the app clients (APK, Linux/macOS/Windows, iOS IPA), and publish the GitHub Release for <tag>."
export RELEASE_INVOKED_AS="scripts/release.sh"

BIN="${LKM_RELEASE_BIN:-lkm-release}"
command -v "$BIN" >/dev/null 2>&1 || {
  echo "error: lkm-release not found — clone https://github.com/L-K-M/release-tool and run ./install.sh" >&2
  exit 1
}

# The engine discovers its target from cwd, including for absolute invocations.
cd "$ROOT"
exec "$BIN" "$@"
