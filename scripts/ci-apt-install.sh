#!/usr/bin/env bash
# Provides the Debian packages a CI step needs.
#
#   scripts/ci-apt-install.sh [--no-install-recommends] <package>...
#
# GitHub-hosted runners install them with sudo, as the steps always did.
# Self-hosted runner images bake them in and give jobs no sudo: their
# containers allow the user namespaces bubblewrap builds Flatpaks in, and
# root there could reach the host. So on self-hosted runners this only
# checks the packages are present and names any the image lacks.
set -euo pipefail

options=()
if [[ "${1:-}" == --no-install-recommends ]]; then
  options+=("$1")
  shift
fi
if (($# == 0)); then
  echo "usage: ${0##*/} [--no-install-recommends] <package>..." >&2
  exit 2
fi

if [[ "${RUNNER_ENVIRONMENT:-}" != self-hosted ]]; then
  sudo apt-get update
  sudo apt-get install -y "${options[@]}" "$@"
  exit 0
fi

# One status line per installed architecture; any "installed" counts.
missing=()
for package in "$@"; do
  dpkg-query -W -f='${db:Status-Status}\n' "$package" 2>/dev/null |
    grep -x installed >/dev/null || missing+=("$package")
done
if ((${#missing[@]})); then
  echo "::error::The runner image lacks ${missing[*]}; add them to its apt-get install" >&2
  exit 1
fi
echo "The runner image provides all $# packages"
