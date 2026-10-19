#!/usr/bin/env bash
# Checks that every image the integration fixture and captures pin by
# digest still resolves on its registry. quay.io dropped the pinned
# fedora:44 digest twice within days (#259, #313), and each time the
# klabautermann_integration CI job broke on every branch at once. The
# weekly `Image pins` workflow runs this so a dead pin shows up there
# first; it runs the same way locally, given Docker with buildx.
#
# It reads each pin's manifest (`docker buildx imagetools inspect`) and
# never pulls. A pin is dead once every attempt fails; the failures name
# the pin and the files that pin it. `--list` prints the pins and the
# files they come from, and needs neither Docker nor the network.
set -euo pipefail

readonly integration_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly pin_pattern='[a-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._/-]+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}'
readonly inspect_attempts=3
readonly retry_delay_seconds=10

usage() {
  echo "usage: $0 [--list]" >&2
  exit 2
}

list_only=0
case "${1:-}" in
  '') ;;
  --list) list_only=1 ;;
  *) usage ;;
esac
(($# <= 1)) || usage

# The files whose images CI pulls or builds on. The Dart tests are left
# out: their digests are placeholders.
cd "$integration_dir"
shopt -s nullglob
files=(*.sh docker-compose*.yml sshd/Dockerfile*)
shopt -u nullglob

mapfile -t pins < <(grep -ohE "$pin_pattern" -- "${files[@]}" | sort -u)
if ((${#pins[@]} == 0)); then
  echo "no digest-pinned images found in ${files[*]}" >&2
  exit 1
fi

# The files that pin [ref], space-separated, relative to this directory.
pinned_by() {
  grep -lF -- "$1" "${files[@]}" | paste -sd ' ' -
}

if ((list_only)); then
  for ref in "${pins[@]}"; do
    printf '%s\t%s\n' "$ref" "$(pinned_by "$ref")"
  done
  exit 0
fi

# Prints the last error line of a failed inspect of [ref] and returns
# non-zero, or returns zero once one attempt resolves it. Registries
# blip, so one failed lookup is not yet a dead pin.
inspect() {
  local ref="$1" attempt error
  for ((attempt = 1; attempt <= inspect_attempts; attempt++)); do
    if error="$(docker buildx imagetools inspect "$ref" 2>&1 >/dev/null)"; then
      return 0
    fi
    ((attempt < inspect_attempts)) && sleep "$retry_delay_seconds"
  done
  printf '%s\n' "$error" | tail -n 1
  return 1
}

dead_refs=()
dead_where=()
for ref in "${pins[@]}"; do
  if reason="$(inspect "$ref")"; then
    echo "ok    $ref"
    continue
  fi

  where="$(pinned_by "$ref")"
  echo "DEAD  $ref ($where): $reason"
  dead_refs+=("$ref")
  dead_where+=("$where")
  if [[ "${GITHUB_ACTIONS:-}" == true ]]; then
    echo "::error title=Dead image pin::$ref no longer resolves (pinned in $where): $reason"
  fi
done

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  {
    echo "### Image pins"
    echo
    echo "${#dead_refs[@]} of ${#pins[@]} digest-pinned images no longer resolve."
    for i in "${!dead_refs[@]}"; do
      echo "- \`${dead_refs[i]}\` (${dead_where[i]})"
    done
  } >>"$GITHUB_STEP_SUMMARY"
fi

if ((${#dead_refs[@]} > 0)); then
  echo >&2
  echo "${#dead_refs[@]} of ${#pins[@]} digest-pinned images no longer resolve:" >&2
  for i in "${!dead_refs[@]}"; do
    echo "  ${dead_refs[i]} (${dead_where[i]})" >&2
  done
  echo "Repin each to a digest its registry still serves, and recapture" \
    "any fixture recorded from it." >&2
  exit 1
fi
echo "all ${#pins[@]} digest-pinned images resolve"
