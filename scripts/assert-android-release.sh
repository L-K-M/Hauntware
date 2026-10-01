#!/usr/bin/env bash
# Verifies that a release APK can upgrade every prior Poltergeist rehearsal.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly EXPECTED_APPLICATION_ID="com.lkm.poltergeist_app"
readonly PACKAGE_PATTERN="^package: name='([^']*)' versionCode='([^']*)' versionName='([^']*)'"
readonly CERTIFICATE_PATH="$ROOT/app/poltergeist_app/android/ci-signing-certificate.sha256"
readonly VERSION_TOOL="$ROOT/tool/release_version/bin/release_version.dart"
readonly AAPT_BIN="${AAPT_BIN:-aapt}"
readonly APKSIGNER_BIN="${APKSIGNER_BIN:-apksigner}"
readonly DART_BIN="${DART_BIN:-dart}"

fail() {
  printf 'error: %s\n' "$1" >&2
  exit 1
}

[[ $# -eq 2 ]] || fail \
  "usage: scripts/assert-android-release.sh APK VERSION"

readonly APK_PATH="$1"
readonly EXPECTED_VERSION="$2"
[[ -s "$APK_PATH" ]] || fail "APK is missing or empty: $APK_PATH"
[[ -s "$CERTIFICATE_PATH" ]] || fail \
  "signing certificate fingerprint is missing"

for tool in "$AAPT_BIN" "$APKSIGNER_BIN" "$DART_BIN"; do
  command -v "$tool" >/dev/null 2>&1 || fail "required tool not found: $tool"
done

readonly APP_VERSION="$("$DART_BIN" run "$VERSION_TOOL" validate \
  --version "$EXPECTED_VERSION")"
readonly EXPECTED_VERSION_NAME="${APP_VERSION%+*}"
readonly EXPECTED_VERSION_CODE="${APP_VERSION##*+}"
readonly EXPECTED_CERTIFICATE="$(tr -d '[:space:]:' < "$CERTIFICATE_PATH" | \
  tr '[:lower:]' '[:upper:]')"
[[ "$EXPECTED_CERTIFICATE" =~ ^[0-9A-F]{64}$ ]] || fail \
  "signing certificate fingerprint is malformed"

readonly PACKAGE_OUTPUT="$("$AAPT_BIN" dump badging "$APK_PATH")"
readonly PACKAGE_LINE="$(printf '%s\n' "$PACKAGE_OUTPUT" | \
  sed -n "/^package: /{p;q;}")"
[[ -n "$PACKAGE_LINE" ]] || fail "APK package metadata is absent"
[[ "$PACKAGE_LINE" =~ $PACKAGE_PATTERN ]] || fail \
  "APK package metadata is malformed"
readonly ACTUAL_APPLICATION_ID="${BASH_REMATCH[1]}"
readonly ACTUAL_VERSION_CODE="${BASH_REMATCH[2]}"
readonly ACTUAL_VERSION_NAME="${BASH_REMATCH[3]}"
[[ "$ACTUAL_APPLICATION_ID" == "$EXPECTED_APPLICATION_ID" ]] || fail \
  "applicationId is '$ACTUAL_APPLICATION_ID', expected '$EXPECTED_APPLICATION_ID'"
[[ "$ACTUAL_VERSION_NAME" == "$EXPECTED_VERSION_NAME" ]] || fail \
  "versionName is '$ACTUAL_VERSION_NAME', expected '$EXPECTED_VERSION_NAME'"
[[ "$ACTUAL_VERSION_CODE" == "$EXPECTED_VERSION_CODE" ]] || fail \
  "versionCode is '$ACTUAL_VERSION_CODE', expected '$EXPECTED_VERSION_CODE'"

readonly SIGNING_OUTPUT="$("$APKSIGNER_BIN" verify --verbose --print-certs \
  "$APK_PATH")"
printf '%s\n' "$SIGNING_OUTPUT" | grep -Fqx \
  'Verified using v2 scheme (APK Signature Scheme v2): true' || fail \
  "APK has no valid v2 signature"
printf '%s\n' "$SIGNING_OUTPUT" | grep -Fqx 'Number of signers: 1' || fail \
  "APK must have exactly one signer"

# Build-tools 37 labels scheme-specific signers (for example, `V2 Signer`),
# while older releases use `Signer #1`. Collapse identical scheme reports.
readonly CERTIFICATE_DIGESTS="$(printf '%s\n' "$SIGNING_OUTPUT" | \
  sed -nE \
    's/^(Signer #[0-9]+|V[0-9]+([.][0-9]+)* Signer):? certificate SHA-256 digest: //p' | \
  sed 's/[[:space:]:]//g' | tr '[:lower:]' '[:upper:]' | sort -u)"
readonly CERTIFICATE_COUNT="$(printf '%s\n' "$CERTIFICATE_DIGESTS" | \
  sed '/^$/d' | wc -l | tr -d '[:space:]')"
[[ "$CERTIFICATE_COUNT" == "1" ]] || fail \
  "APK must report exactly one signing certificate"
readonly ACTUAL_CERTIFICATE="$CERTIFICATE_DIGESTS"
[[ "$ACTUAL_CERTIFICATE" == "$EXPECTED_CERTIFICATE" ]] || fail \
  "APK signing certificate does not match the committed identity"

printf 'Android release verified: %s (%s, versionCode %s)\n' \
  "$APK_PATH" "$EXPECTED_VERSION_NAME" "$EXPECTED_VERSION_CODE"
