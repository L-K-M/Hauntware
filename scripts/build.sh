#!/usr/bin/env bash
# Build every product feasible on this host and stage the products'
# artifacts under dist/.
#
# Usage:
#   scripts/build.sh                  # every product feasible on this host
#   scripts/build.sh seance           # only the named products (an
#                                     # explicit selection is mandatory)
#   scripts/build.sh --debug          # forward the debug build profile
#   scripts/build.sh --check          # print the resolved config; build nothing
#
# Each product keeps its own build (planchette/scripts/build.sh and
# siblings) — this orchestrator runs them in sequence and unions their
# product-prefixed artifacts into dist/ (the same names
# scripts/release-manifest.txt expects on a release). A product whose
# build script is absent is skipped on a default run and fails when named
# explicitly; tool/toolchain feasibility inside a product stays that
# product's own decision (see each <product>/scripts/build.sh).
#
# Environment: HAUNTWARE_BUILD_ROOT overrides the repository root (used by
# the contract tests).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${HAUNTWARE_BUILD_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
PRODUCTS="planchette seance poltergeist"
DIST="$ROOT/dist"
MODE=release
CHECK=false
SELECTED=""

for argument in "$@"; do
  case "$argument" in
    --debug) MODE=debug ;;
    --check) CHECK=true ;;
    --help|-h)
      sed -n '2,/^set -uo/p' "$SELF_DIR/build.sh" | sed 's/^# \?//;/^set -uo/d'
      exit 0 ;;
    planchette|seance|poltergeist) SELECTED="${SELECTED:+$SELECTED }$argument" ;;
    *)
      echo "Unknown argument: $argument" >&2
      echo "Try 'scripts/build.sh --help'." >&2
      exit 2 ;;
  esac
done

script_for() {
  printf '%s/%s/scripts/build.sh' "$ROOT" "$1"
}

if $CHECK; then
  echo "Host:  $(uname -s) $(uname -m)"
  echo "Mode:  $MODE"
  echo "Root:  $ROOT"
  echo "Dist:  $DIST"
  echo
  echo "Products:"
  for product in $PRODUCTS; do
    script="$(script_for "$product")"
    if [[ -f "$script" ]]; then
      echo "  $product  ready  ($product/scripts/build.sh)"
    else
      echo "  $product  missing  (no scripts/build.sh)"
    fi
  done
  echo
  echo "Tools (each product decides its own feasibility):"
  for tool in dart flutter docker; do
    found="$(command -v "$tool" 2>/dev/null || true)"
    echo "  $tool  ${found:-not found}"
  done
  exit 0
fi

explicit=false
[[ -n "$SELECTED" ]] && explicit=true
WANTED="${SELECTED:-$PRODUCTS}"

RESULTS=()
FAILED=0
BUILT=0
for product in $WANTED; do
  script="$(script_for "$product")"
  if [[ ! -f "$script" ]]; then
    if $explicit; then
      echo "!! $product: no build script at $product/scripts/build.sh" >&2
      RESULTS+=("$product  FAILED (missing)")
      FAILED=$((FAILED + 1))
    else
      echo ".. skip $product (no build script)"
      RESULTS+=("$product  skipped")
    fi
    continue
  fi

  echo "== Building $product ($MODE) =="
  child_args=()
  [[ "$MODE" == debug ]] && child_args+=(--debug)
  if (cd "$ROOT/$product" && scripts/build.sh ${child_args[@]+"${child_args[@]}"}); then
    RESULTS+=("$product  built")
    BUILT=$((BUILT + 1))
    if [[ -d "$ROOT/$product/dist" ]]; then
      mkdir -p "$DIST"
      cp -R "$ROOT/$product/dist/." "$DIST/"
    fi
  else
    RESULTS+=("$product  FAILED")
    FAILED=$((FAILED + 1))
  fi
done

echo
echo "Build summary ($MODE):"
for result in ${RESULTS[@]+"${RESULTS[@]}"}; do
  echo "  $result"
done
echo "Artifacts: $DIST"

if [[ $BUILT -gt 0 && "$(uname -s)" == Darwin ]]; then
  open "$DIST"
fi

[[ $FAILED -eq 0 ]] || exit 1
exit 0
