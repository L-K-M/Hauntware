# shellcheck shell=bash
# The native macOS fixtures shared by the products'
# scripts/test-macos-keyboard.sh and scripts/test-macos-accessibility.sh.
# Each wrapper sets its product's values, sources this file and calls
# macos_keyboard_fixture "$@" or macos_accessibility_fixture "$@":
#
#   repo_root           the product root
#   FIXTURE_PRODUCT     lower-case product name; prefixes the temporary
#                       directory
#   FIXTURE_APP         the Flutter app, relative to repo_root
#   FIXTURE_CONTROLLER  the Runner's FlutterViewController subclass; its
#                       .m and .h live in the app's macos/Runner
#   FIXTURE_DEFINE      the product's macro prefix: the app's
#                       macos/RunnerTests/AccessibilityLifecycleTest.mm
#                       reads <prefix>_USE_GUARD
#
# The keyboard checks are scripts/macos-keyboard-fixture.mm, compiled
# once per product against that product's controller; the accessibility
# checks are each app's own lifecycle test. Both build against the cached
# Flutter release engine, and neither starts a Dart application or posts
# input to the system.
# shellcheck disable=SC2154  # repo_root and FIXTURE_* come from the wrapper

MACOS_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Finds the Flutter SDK and its macOS release engine, or exits. Sets
# flutter_sdk and framework_dir; $1 names the test in the error.
_macos_fixture_engine() {
  if [[ "$(uname -s)" != Darwin ]]; then
    echo "This native $1 test requires macOS." >&2
    exit 1
  fi

  generated_config="$repo_root/$FIXTURE_APP/macos/Flutter/ephemeral/Flutter-Generated.xcconfig"
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
}

# The keyboard fixture; --stock-engine runs the same checks against the
# stock FlutterViewController (it must fail its first assertion).
macos_keyboard_fixture() {
  _macos_fixture_engine keyboard

  controller_flags=(-DFIXTURE_USE_CONTROLLER=1)
  if [[ $# == 1 && "$1" == --stock-engine ]]; then
    controller_flags=(-DFIXTURE_USE_CONTROLLER=0)
  elif [[ $# != 0 ]]; then
    echo "Usage: $0 [--stock-engine]" >&2
    exit 1
  fi
  # The fixture imports the product's controller through these two.
  controller_flags+=(
    "-DFIXTURE_CONTROLLER_HEADER=\"$FIXTURE_CONTROLLER.h\""
    "-DFIXTURE_CONTROLLER_CLASS=$FIXTURE_CONTROLLER"
  )

  test_dir="$(mktemp -d "${TMPDIR:-/tmp}/$FIXTURE_PRODUCT-keyboard.XXXXXX")"
  trap 'rm -rf "$test_dir"' EXIT
  runner_dir="$repo_root/$FIXTURE_APP/macos/Runner"
  # Compile the actual controller against the bundled engine. The executable
  # supplies only framework replies; it starts no Dart application or window,
  # and never posts input to the system.
  xcrun clang -fobjc-arc -F "$framework_dir" -I "$runner_dir" \
    -c "$runner_dir/$FIXTURE_CONTROLLER.m" \
    -o "$test_dir/controller.o"
  xcrun clang++ -std=c++17 -fobjc-arc -framework Cocoa -framework FlutterMacOS \
    -F "$framework_dir" -I "$flutter_sdk/engine/src" -I "$runner_dir" \
    -Wl,-rpath,"$framework_dir" "${controller_flags[@]}" -x objective-c++ \
    "$MACOS_FIXTURES_DIR/macos-keyboard-fixture.mm" \
    -x none "$test_dir/controller.o" \
    -o "$test_dir/keyboard-test"
  "$test_dir/keyboard-test"
}

# The accessibility lifecycle fixture; --stock-engine builds it without
# the controller's guard.
macos_accessibility_fixture() {
  _macos_fixture_engine accessibility

  test_dir="$(mktemp -d "${TMPDIR:-/tmp}/$FIXTURE_PRODUCT-accessibility.XXXXXX")"
  trap 'rm -rf "$test_dir"' EXIT
  runner_dir="$repo_root/$FIXTURE_APP/macos/Runner"
  guard_flags=("-D${FIXTURE_DEFINE}_USE_GUARD=1")
  if [[ $# == 1 && "$1" == --stock-engine ]]; then
    guard_flags=("-D${FIXTURE_DEFINE}_USE_GUARD=0")
  elif [[ $# != 0 ]]; then
    echo "Usage: $0 [--stock-engine]" >&2
    exit 1
  fi

  # Build the same controller used by the app against the real Flutter framework.
  # The fixture injects semantics directly; it never starts the Dart application.
  xcrun clang++ -std=c++17 -fobjc-arc -framework Cocoa -framework FlutterMacOS \
    -F "$framework_dir" -I "$flutter_sdk/engine/src" -I "$runner_dir" \
    -Wl,-rpath,"$framework_dir" "${guard_flags[@]}" \
    "$repo_root/$FIXTURE_APP/macos/RunnerTests/AccessibilityLifecycleTest.mm" \
    -x objective-c++ "$runner_dir/$FIXTURE_CONTROLLER.m" \
    -o "$test_dir/accessibility-test"
  "$test_dir/accessibility-test"
}
