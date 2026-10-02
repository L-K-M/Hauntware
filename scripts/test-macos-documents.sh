#!/usr/bin/env bash
# Verify Finder's preferred URL callback against the real Runner delegate and
# bundled Flutter engine. Requires macOS and flutter build macos (or FLUTTER_ROOT).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This native document-open test requires macOS." >&2
  exit 1
fi

generated_config="$repo_root/app/planchette_app/macos/Flutter/ephemeral/Flutter-Generated.xcconfig"
flutter_sdk="${FLUTTER_ROOT:-}"
if [[ -z "$flutter_sdk" && -f "$generated_config" ]]; then
  flutter_sdk="$(sed -n 's/^FLUTTER_ROOT=//p' "$generated_config")"
fi
if [[ -z "$flutter_sdk" ]]; then
  echo "Set FLUTTER_ROOT or run flutter build macos before this test." >&2
  exit 1
fi
framework_dir="$flutter_sdk/bin/cache/artifacts/engine/darwin-x64-release/FlutterMacOS.xcframework/macos-arm64_x86_64"
if [[ ! -d "$framework_dir" ]]; then
  echo "Missing macOS release engine. Run flutter precache --macos." >&2
  exit 1
fi

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/planchette-documents.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -DPLANCHETTE_DOCUMENT_OPEN_TEST \
  -F "$framework_dir" -framework Cocoa -framework FlutterMacOS \
  -Xlinker -rpath -Xlinker "$framework_dir" \
  "$repo_root/app/planchette_app/macos/Runner/AppDelegate.swift" \
  "$repo_root/app/planchette_app/macos/RunnerTests/DocumentOpenTest.swift" \
  -o "$test_dir/documents-test"
"$test_dir/documents-test"
