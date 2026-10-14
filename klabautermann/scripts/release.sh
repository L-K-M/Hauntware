#!/usr/bin/env bash
# Klabautermann does not release on its own: the Hauntware suite ships one
# version and one v<version> tag covering all products. This forwards the
# whole-suite release to the root orchestrator
# (../../scripts/release.sh); child builds stay product-scoped via
# scripts/build.sh here.
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/release.sh" "$@"
