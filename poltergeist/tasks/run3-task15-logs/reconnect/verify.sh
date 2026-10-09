#!/usr/bin/env bash
set -euo pipefail
root=/home/paseo/workspace/Poltergeist
out="$root/tasks/run3-task15-logs/reconnect"
export PATH=/home/paseo/opt/flutter/bin:$PATH
run() {
  local name=$1; shift
  printf '%q ' "$@" > "$out/$name.command"
  printf '\n' >> "$out/$name.command"
  local rc=0
  timeout --kill-after=15s 8m "$@" > "$out/$name.log" 2>&1 || rc=$?
  printf '%s\n' "$rc" > "$out/$name.log.exit"
  printf '%s: %s\n' "$name" "$rc"
  return "$rc"
}
cd "$root/app/poltergeist_app"
run supervisor-after flutter test --reporter expanded /home/paseo/.paseo/poltergeist-loop/tasks/pr84-supervisor-reconnect_test.dart
run focused-final flutter test --reporter expanded test/services/pane_reconnect_test.dart test/services/pane_cancel_regressions_test.dart test/services/pane_controller_test.dart test/ui/panes/pane_view_test.dart test/ui/panes/workspace_panes_test.dart test/ui/panes/pane_session_lifetime_test.dart test/ui/connections/open_inpane_pop_test.dart
run retained-lifecycle flutter test --reporter expanded "$out/../recovery4/route_lifecycle_test.dart" "$out/../recovery4/cleanup_ownership_test.dart"
run app-final flutter test --reporter expanded
run analyze-final flutter analyze
run capture-final flutter test --reporter expanded "$out/readable_capture_test.dart"
