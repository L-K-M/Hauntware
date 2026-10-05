#!/usr/bin/env bash
# Launch the built release app and check that Dart starts it: the hidden
# main window comes on screen and the app's own menus replace the stock ones.
# Unit tests run with asserts on and cannot see a release-only startup
# failure, which leaves a running app with no window.
# Requires macOS and flutter build macos --release (or pass the .app).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "This launch test requires macOS." >&2
  exit 1
fi

app="${1:-$repo_root/app/planchette_app/build/macos/Build/Products/Release/Planchette.app}"
binary="$app/Contents/MacOS/Planchette"
if [[ ! -x "$binary" ]]; then
  echo "Missing $binary. Run flutter build macos --release first." >&2
  exit 1
fi

# Generous for a cold first launch on a CI runner; a healthy one takes seconds.
launch_timeout=60

test_dir="$(mktemp -d "${TMPDIR:-/tmp}/planchette-launch.XXXXXX")"
pid=
cleanup() {
  if [[ -n "$pid" ]]; then
    kill -9 "$pid" 2>/dev/null || true
  fi
  rm -rf "$test_dir"
}
trap cleanup EXIT

xcrun swiftc \
  "$repo_root/app/planchette_app/macos/RunnerTests/LaunchProbe.swift" \
  -o "$test_dir/launch-probe"

# A throwaway HOME keeps this machine's settings and remembered window frame
# out of the test, and the test's out of them.
mkdir "$test_dir/home"
HOME="$test_dir/home" "$binary" >"$test_dir/output.txt" 2>&1 &
pid=$!

status=0
"$test_dir/launch-probe" "$pid" "$launch_timeout" || status=$?
# The engine prints what escapes Dart's main() and keeps the process alive.
if grep -q 'Unhandled Exception' "$test_dir/output.txt"; then
  echo "Dart reported an unhandled exception during launch." >&2
  status=1
fi
if [[ "$status" -ne 0 ]]; then
  echo "--- Planchette output" >&2
  cat "$test_dir/output.txt" >&2
fi
exit "$status"
