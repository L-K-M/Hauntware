#!/usr/bin/env bash
# Compiles Poltergeist's native view controller into the app's
# macos/RunnerTests/AccessibilityLifecycleTest.mm and runs it. macOS only;
# --stock-engine builds the test without the controller's guard.
# The body is shared by the four products:
# ../../scripts/macos-native-fixtures.sh.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_PRODUCT=poltergeist
FIXTURE_APP=app/poltergeist_app
FIXTURE_CONTROLLER=PoltergeistFlutterViewController
FIXTURE_DEFINE=POLTERGEIST

# shellcheck source=SCRIPTDIR/../../scripts/macos-native-fixtures.sh
source "$repo_root/../scripts/macos-native-fixtures.sh"
macos_accessibility_fixture "$@"
