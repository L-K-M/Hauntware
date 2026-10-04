#!/usr/bin/env bash
# Root test orchestrator for the Hauntware monorepo.
#
# Runs the root suite tooling plus the pure-Dart and Flutter suites of
# all three subtrees (planchette/, seance/, poltergeist/) from their
# actual working
# directories — each subtree keeps its own pub workspace, and pub
# resolves per subtree root, so dependencies are resolved SEQUENTIALLY
# inside each `cd` block rather than through a shared or parallel
# resolution. `dart --directory` is deliberately not used: several
# suites (tool tests, benchmark contract tests, fixture validators)
# resolve inputs relative to the subtree root.
#
# Usage:
#   scripts/test.sh          # every suite below
#   scripts/test.sh dart     # pure-Dart packages and tools only
#   scripts/test.sh flutter  # Flutter packages and apps only
#
# Requires the Dart SDK (3.12+) for `dart` and Flutter 3.47.2 for
# `flutter` — its bundled Dart drives the app packages. The `dart`
# scope also needs Linux (the Poltergeist benchmark harness reads
# /proc/uptime) and Docker with the Compose plugin (the integration
# fixture checks render the compose file; no container is started).
# Host-bound gates stay in CI, not here: the compiled-PTY lifecycle test
# (SEANCE_NATIVE_PTY_REQUIRED), the macOS keyboard/accessibility
# fixtures, the SSH/sync-server integration fixtures, and the D12
# benchmark collectors.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

scope="${1:-all}"
case "$scope" in
  all|dart|flutter) ;;
  *)
    echo "usage: $0 [all|dart|flutter]" >&2
    exit 2
    ;;
esac

run() {
  echo "=== $*" >&2
  "$@"
}

if [[ "$scope" != flutter ]]; then
  # ---- Suite tooling: the root `hauntware` manifest is the single
  # versioned artifact; tool/release_version keeps every owned
  # package/app pubspec, README marker and Apple bundle declaration in
  # lockstep. The root resolves like the subtrees do — sequential,
  # inside its own working directory, not a workspace member.
  (
    run dart pub get
    run dart test tool/release_version/test
    run dart run tool/release_version/bin/release_version.dart check
  )

  # ---- Planchette: pure-Dart core (the Flutter packages are below).
  (
    cd planchette
    run dart pub get
    run dart analyze packages/planchette_core
    run dart test packages/planchette_core
  )

  # ---- Séance: protocol, core, sync server. The server's SQLite
  # storage test loads libsqlite3 at runtime (CI installs it).
  (
    cd seance
    run dart pub get
    run dart analyze \
      packages/seance_protocol packages/seance_core packages/seance_sync_server
    run dart test \
      packages/seance_protocol packages/seance_core packages/seance_sync_server
  )

  # ---- Poltergeist: workspace packages plus the tooling suites the
  # repo gates on (import/protocol guards, license gate, release
  # version tool, pin audit, benchmark harness + contract tests,
  # integration fixture tools). The bench harness and legacy bench
  # entrypoint resolve standalone, outside the workspace lock.
  (
    cd poltergeist
    run dart pub get
    (cd packages/poltergeist_bench && run dart pub get)
    (cd tool/bench && run dart pub get)

    for package in packages/*; do
      [[ -d "$package" ]] || continue
      run dart analyze "$package"
    done
    dirs=()
    for package in packages/*; do
      [[ -d "$package/test" ]] || continue
      # Linux-bound: the harness reads /proc/uptime. Its suite runs
      # below through its own package config.
      [[ "$package" == 'packages/poltergeist_bench' ]] && continue
      dirs+=("$package")
    done
    ((${#dirs[@]} > 0)) || { echo "no package has a test/ directory" >&2; exit 1; }
    run dart test --reporter expanded "${dirs[@]}"

    run dart analyze tool/import_guard
    run dart test tool/import_guard/test
    run bash scripts/check-imports.sh
    run dart analyze tool/protocol_guard
    run dart test tool/protocol_guard/test
    run dart run tool/protocol_guard/bin/check.dart .
    run dart analyze tool/license_gate
    run dart analyze tool/release_version
    run dart analyze tool/seance_pin_audit
    run dart test tool/license_gate/test
    run dart test tool/release_version/test
    run dart run tool/release_version/bin/release_version.dart check
    run dart test tool/seance_pin_audit/test
    run bash scripts/audit-seance-pin.sh

    (cd packages/poltergeist_bench && run dart analyze && run dart test test)
    (
      cd packages/poltergeist_bench
      run dart run benchmark/validate_bundle.dart \
        --bundle ../../docs/evidence/m0 \
        --report ../../docs/M0-DARTSSH2-REPORT.md \
        --repo ../..
    )
    run dart test test/benchmarks
    run dart analyze test/benchmarks
    run dart analyze test/integration
    run dart test test/integration
    run test/integration/test-fixture-safety.sh
    run bash -c 'source test/integration/lib/fixture.sh && check_rendered_config'
    run dart run tool/license_gate/bin/check.dart --marker-only
  )
fi

if [[ "$scope" != dart ]]; then
  # ---- Planchette: shared Flutter packages + standalone app.
  (
    cd planchette
    # planchette_core is pure Dart; the rest resolve through Flutter.
    (cd packages/planchette_core && run dart pub get)
    for dir in packages/ghost_ui packages/planchette_editor \
               packages/ghost_desktop app/planchette_app; do
      (cd "$dir" && run flutter pub get)
    done
    for dir in packages/ghost_ui packages/planchette_editor \
               packages/ghost_desktop app/planchette_app; do
      (cd "$dir" && run flutter analyze && run flutter test)
    done
    run dart format --set-exit-if-changed --output=none \
      packages/planchette_core packages/planchette_editor \
      packages/ghost_ui packages/ghost_desktop app/planchette_app
  )

  # ---- Séance: app plus the vendored xterm fork (its tests are not
  # discovered through the app suite).
  (
    cd seance
    (cd app/seance_app && run flutter pub get && run flutter analyze && run flutter test)
    (cd third_party/xterm && run flutter pub get && run flutter test)
  )

  # ---- Poltergeist app.
  (
    cd poltergeist
    (cd app/poltergeist_app && run flutter pub get && run flutter analyze && run flutter test)
  )
fi

echo "=== all requested suites passed" >&2
