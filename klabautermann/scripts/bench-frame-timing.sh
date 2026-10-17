#!/usr/bin/env bash
# Spike S5 part 2's entry point (03 §11.4, §11.6): builds the app for the
# Linux desktop in profile mode and runs its frame-timing test
# (app/klabautermann_app/integration_test/frame_timing_test.dart) under
# Xvfb through `flutter drive`, as Poltergeist's tier-B bench does. CI's
# klabautermann_frame_timing leg runs it from klabautermann/ with
# LIBGL_ALWAYS_SOFTWARE=1, so Mesa's llvmpipe renders: the numbers are
# provisional and never a device's (06, manual gates).
#
# The report goes to $KLABAUTERMANN_EVIDENCE_DIR/frame-timing.json with
# the drive's log beside it, or to the app's build/ without that
# variable. The script exits non-zero when the build or the test fails,
# never on a slow number. It expects the app's dependencies resolved.
#
#   FLUTTER_BIN                  the flutter binary (default: flutter)
#   XVFB_RUN                     the display wrapper (default: xvfb-run -a;
#                                `env` when a display already exists)
#   KLABAUTERMANN_FRAME_SECONDS  seconds each surface is measured (20)
set -euo pipefail

readonly klab_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly app_dir="$klab_root/app/klabautermann_app"
readonly flutter_bin="${FLUTTER_BIN:-flutter}"
readonly xvfb_prefix="${XVFB_RUN:-xvfb-run -a}"
evidence_dir="${KLABAUTERMANN_EVIDENCE_DIR:-}"
readonly seconds="${KLABAUTERMANN_FRAME_SECONDS:-20}"

if ! command -v "$flutter_bin" >/dev/null; then
  echo "flutter binary not found: $flutter_bin" >&2
  exit 127
fi
if [[ ! "$seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "KLABAUTERMANN_FRAME_SECONDS takes a whole number of seconds" >&2
  exit 64
fi

log=/dev/null
if [[ -n "$evidence_dir" ]]; then
  mkdir -p "$evidence_dir"
  # Absolute, since the driver that writes the report runs in the app.
  evidence_dir="$(cd "$evidence_dir" && pwd)"
  export KLABAUTERMANN_EVIDENCE_DIR="$evidence_dir"
  # A failed drive must not leave an earlier run's report behind.
  rm -f "$evidence_dir/frame-timing.json"
  log="$evidence_dir/frame-timing.log"
fi

# The report records what it ran on; an unparsed version stays empty.
flutter_version="$(
  "$flutter_bin" --version --machine 2>/dev/null |
    sed -n 's/.*"frameworkVersion": *"\([^"]*\)".*/\1/p' || true
)"
display="$xvfb_prefix; LIBGL_ALWAYS_SOFTWARE=${LIBGL_ALWAYS_SOFTWARE:-unset}"

cd "$app_dir"
# shellcheck disable=SC2086 # XVFB_RUN intentionally carries arguments.
$xvfb_prefix "$flutter_bin" drive \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/frame_timing_test.dart \
  --device-id=linux --profile --no-pub \
  "--dart-define=KLABAUTERMANN_REPLAY_FIXTURES=$klab_root/packages/klabautermann_host/test/fixtures" \
  "--dart-define=KLABAUTERMANN_FRAME_SECONDS=$seconds" \
  "--dart-define=KLABAUTERMANN_FRAME_DISPLAY=$display" \
  "--dart-define=KLABAUTERMANN_FLUTTER_VERSION=$flutter_version" \
  2>&1 | tee "$log"
