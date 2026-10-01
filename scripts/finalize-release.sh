#!/usr/bin/env bash
# Finalizes one CI-created draft using the maintainer's local OpenPGP key.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly DART_BIN="${DART_BIN:-dart}"
readonly GIT_BIN="${GIT_BIN:-git}"

release_tag=""
previous_argument=""
for argument in "$@"; do
  if [[ "$previous_argument" == "--tag" ]]; then
    release_tag="$argument"
    break
  fi

  previous_argument="$argument"
done
if [[ -z "$release_tag" ]]; then
  echo "error: --tag is required" >&2
  exit 64
fi

checkout_status=""
if ! checkout_status="$(
  "$GIT_BIN" -C "$ROOT" status --porcelain=v1 --untracked-files=all
)"; then
  echo "error: could not inspect the release checkout" >&2
  exit 1
fi
if [[ -n "$checkout_status" ]]; then
  echo "error: finalization requires a clean tagged checkout" >&2
  exit 1
fi

head_commit="$("$GIT_BIN" -C "$ROOT" rev-parse --verify HEAD)"
tag_commit="$(
  "$GIT_BIN" -C "$ROOT" rev-parse --verify "${release_tag}^{commit}"
)"
if [[ "$head_commit" != "$tag_commit" ]]; then
  echo "error: finalization requires the exact tagged commit" >&2
  exit 1
fi

exec "$DART_BIN" run \
  "$ROOT/tool/release_finalize/bin/finalize_release.dart" \
  --repo-root "$ROOT" "$@"
