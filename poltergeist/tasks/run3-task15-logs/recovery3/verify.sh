#!/usr/bin/env bash
set -euo pipefail
cd /home/paseo/workspace/Poltergeist
export PATH=/home/paseo/opt/flutter/bin:$PATH
logs="$PWD/tasks/run3-task15-logs/recovery3"
run() {
  local name="$1" seconds="$2" result=0
  shift 2
  timeout --kill-after=30s "${seconds}s" "$@" > "$logs/$name.log" 2>&1 || result=$?
  printf '%s\n' "$result" > "$logs/$name.log.exit"
  printf '%s exit=%s\n' "$name" "$result"
  return "$result"
}
run core-analyze 240 dart analyze packages/poltergeist_core
run core-tests 600 dart test --reporter expanded packages/poltergeist_core
run imports 180 bash scripts/check-imports.sh
run protocol-tests 180 dart test --reporter expanded tool/protocol_guard/test
run protocol 180 dart run tool/protocol_guard/bin/check.dart .
cd app/poltergeist_app
run app-analyze 300 flutter analyze
run app-tests 600 flutter test --reporter expanded
