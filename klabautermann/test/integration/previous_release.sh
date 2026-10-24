#!/usr/bin/env bash
# Builds the previous release's Séance and Poltergeist as one harness
# (M5 plan M08b, 03 §4.8 and §11.2 item 2) and prints its path. run.sh
# runs it after the sync service is up and hands the path to the
# convergence suite, which proves that the last release skips
# Klabautermann's records: it neither applies nor re-pushes them.
#
# The previous release is the highest vMAJOR.MINOR.PATCH tag on origin.
# Its seance_core, seance_protocol and poltergeist_core (with the
# planchette_core it depends on by path) come out with `git archive`, and
# previous_release_harness/bin/harness.dart is compiled against them,
# with a pubspec written here: the harness is not a package of this
# checkout, and the analyzer leaves it out. Needs git, tar, network
# access to origin and pub.dev, and the Dart SDK.
#
# Usage: previous_release.sh WORK_DIR
set -euo pipefail

readonly integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly harness_source="$integration_dir/previous_release_harness/bin/harness.dart"
readonly dart_binary="${DART_BIN:-dart}"
readonly fetch_attempts=3
# The released packages the harness compiles against, as the tag lays
# them out, so their relative path dependencies resolve.
readonly packages=(
  seance/packages/seance_core
  seance/packages/seance_protocol
  poltergeist/packages/poltergeist_core
  planchette/packages/planchette_core
)

if [[ "$#" -ne 1 ]]; then
  echo 'usage: test/integration/previous_release.sh WORK_DIR' >&2
  exit 2
fi
mkdir -p "$1"
work_dir="$(cd "$1" && pwd)"
repo_dir="$(git -C "$integration_dir" rev-parse --show-toplevel)"
readonly work_dir repo_dir

# A CI checkout is shallow and carries no tags, so the remote names them.
tag="$(git -C "$repo_dir" ls-remote --tags --refs origin 'v*' \
  | sed -n 's#^[0-9a-f]*[[:space:]]*refs/tags/\(v[0-9]*\.[0-9]*\.[0-9]*\)$#\1#p' \
  | sort -V | tail -n 1)"
if [[ -z "$tag" ]]; then
  echo 'origin has no vMAJOR.MINOR.PATCH release tag' >&2
  exit 1
fi
echo "previous release: $tag" >&2

# A local clone may hold the tag already. Only a shallow one fetches with
# --depth, which would otherwise make a full clone shallow.
if ! commit="$(git -C "$repo_dir" rev-parse -q --verify "refs/tags/$tag^{commit}")"; then
  depth=()
  if [[ "$(git -C "$repo_dir" rev-parse --is-shallow-repository)" == true ]]; then
    depth=(--depth 1)
  fi
  for ((attempt = 1; ; attempt++)); do
    git -C "$repo_dir" fetch --quiet --no-tags "${depth[@]}" origin \
      "refs/tags/$tag:refs/tags/$tag" && break
    if ((attempt == fetch_attempts)); then
      echo "cannot fetch $tag from origin" >&2
      exit 1
    fi
    sleep $((attempt * 5))
  done
  commit="$(git -C "$repo_dir" rev-parse --verify "refs/tags/$tag^{commit}")"
fi

rm -rf -- "${work_dir:?}/src" "${work_dir:?}/harness"
mkdir -p "$work_dir/src" "$work_dir/harness/bin"
git -C "$repo_dir" archive "$commit" "${packages[@]}" | tar -x -C "$work_dir/src"
cp "$harness_source" "$work_dir/harness/bin/harness.dart"
cat >"$work_dir/harness/pubspec.yaml" <<EOF
name: previous_release_harness
publish_to: none
environment:
  sdk: ^3.12.0
dependencies:
  seance_core:
    path: $work_dir/src/seance/packages/seance_core
  seance_protocol:
    path: $work_dir/src/seance/packages/seance_protocol
  poltergeist_core:
    path: $work_dir/src/poltergeist/packages/poltergeist_core
EOF

(
  cd "$work_dir/harness"
  "$dart_binary" pub get >&2
  "$dart_binary" compile exe bin/harness.dart -o harness >&2
)
printf '%s\n' "$work_dir/harness/harness"
