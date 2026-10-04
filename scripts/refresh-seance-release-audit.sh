#!/usr/bin/env bash
# Refresh the committed Séance proof after the version bump, before tagging.
# Its history includes the bump commit's SHA, so it cannot run pre-commit.
# Called by RELEASE_PRE_TAG; requires Git and the resolved audit tool.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly RECORD_PATH='poltergeist/docs/PORTS.md'
readonly SUCCESS_EXIT_CODE=0 FAILURE_EXIT_CODE=1
cd "$ROOT"

pending_changes="$(git status --porcelain)"
if [[ -n "$pending_changes" ]]; then
  echo 'error: release audit requires a clean working tree' >&2
  exit "$FAILURE_EXIT_CODE"
fi

(cd poltergeist && bash scripts/audit-seance-pin.sh --write-record)

# Stage only the regenerated proof; a current record needs no extra commit.
changed_record="$(git diff --name-only -- "$RECORD_PATH")"
if [[ -z "$changed_record" ]]; then
  exit "$SUCCESS_EXIT_CODE"
fi

git add -- "$RECORD_PATH"
git commit -m 'Refresh Séance source audit record'
