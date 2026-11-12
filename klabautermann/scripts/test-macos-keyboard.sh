#!/usr/bin/env bash
# Compiles Klabautermann's native view controller into the shared keyboard
# fixture (../../scripts/macos-keyboard-fixture.mm) and runs it. macOS
# only; --stock-engine runs the same checks against the stock controller.
# The body is shared by the four products:
# ../../scripts/macos-native-fixtures.sh.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_PRODUCT=klabautermann
FIXTURE_APP=app/klabautermann_app
FIXTURE_CONTROLLER=KlabautermannFlutterViewController

# shellcheck source=SCRIPTDIR/../../scripts/macos-native-fixtures.sh
source "$repo_root/../scripts/macos-native-fixtures.sh"
macos_keyboard_fixture "$@"
