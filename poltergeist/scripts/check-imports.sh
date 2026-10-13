#!/usr/bin/env bash
# Parse imports and resolved dependencies; grep cannot classify plugins.
# The guard itself lives at the suite root since F1a; this forwards to it.
set -euo pipefail

suite_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for package_config in \
  "$suite_root/.dart_tool/package_config.json" \
  "$suite_root/poltergeist/.dart_tool/package_config.json"; do
  if [ ! -f "$package_config" ]; then
    echo "error: missing $package_config; run dart pub get" >&2
    exit 2
  fi
done

cd "$suite_root"
exec dart --packages="$suite_root/.dart_tool/package_config.json" \
  tool/import_guard/bin/check.dart --product poltergeist
