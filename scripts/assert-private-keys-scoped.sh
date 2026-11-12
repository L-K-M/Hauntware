#!/usr/bin/env bash
# Private-key scope: no PEM private key may exist anywhere in the
# repository outside the allowlist below. Scans the whole monorepo (the
# F1a generalization; it used to scan poltergeist/ only). Run from
# anywhere; every reported path is repository-relative.
set -euo pipefail

readonly repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Every committed path that legitimately carries a private-key header
# today, found with the same detection the scan below uses. The three
# sshd keys are real fixture keys; the Séance Dart files carry the header
# only as a test-fixture string.
readonly -a allowed=(
  'poltergeist/test/integration/keys/ssh_host_ed25519_key'
  'poltergeist/test/integration/keys/ssh_host_ed25519_key_swap'
  'poltergeist/test/integration/keys/ssh_host_rsa_key'
  'seance/app/seance_app/test/command_stats_privacy_test.dart'
  'seance/packages/seance_core/test/pure_logic_test.dart'
  'seance/packages/seance_core/test/quoted_secret_redaction_test.dart'
)

readonly openssh_header="BEGIN OPENSSH"' PRIVATE KEY'
readonly rsa_header="BEGIN RSA"' PRIVATE KEY'
readonly ec_header="BEGIN EC"' PRIVATE KEY'
readonly pkcs8_header="BEGIN"' PRIVATE KEY'
readonly encrypted_pkcs8_header="BEGIN ENCRYPTED"' PRIVATE KEY'
readonly dsa_header="BEGIN DSA"' PRIVATE KEY'

# Scan what git tracks plus untracked files it does not ignore, so a key
# is caught before its commit wherever it sits (a tracked file under a
# directory named build/ included), while ignored outputs such as build
# trees and the integration runtime stay out. A tracked file deleted
# from the worktree has nothing left to leak, so grep skips it (-s).
mapfile -t detected < <(
  cd "$repo_root"
  git ls-files -z --cached --others --exclude-standard \
    | xargs -0 grep -Ils \
      -e "$openssh_header" \
      -e "$rsa_header" \
      -e "$ec_header" \
      -e "$pkcs8_header" \
      -e "$encrypted_pkcs8_header" \
      -e "$dsa_header" \
      -- \
    | sort -u
)

mapfile -t expected < <(printf '%s\n' "${allowed[@]}" | sort)

if [[ "${detected[*]}" == "${expected[*]}" ]]; then
  exit 0
fi

echo 'private-key scope mismatch' >&2
printf 'expected: %s\n' "${expected[*]}" >&2
printf 'detected: %s\n' "${detected[*]}" >&2
exit 1
