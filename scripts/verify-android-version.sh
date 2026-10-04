#!/usr/bin/env bash
# Proves Gradle consumed the synchronized pubspec version code: the
# built release APK's versionCode must equal the build number in the
# app's pubspec.yaml (1.9.0+1090099 -> 1090099).
#
#   scripts/verify-android-version.sh [app-dir]
#
# app-dir defaults to the current directory (the release and CI legs
# run it from seance/app/seance_app or poltergeist/app/poltergeist_app)
# and must hold pubspec.yaml plus the built
# build/app/outputs/flutter-apk/app-release.apk. Needs apkanalyzer from
# the Android command-line tools ($ANDROID_HOME or PATH).
set -euo pipefail

readonly app_root="$(cd -- "${1:-.}" && pwd)"
readonly pubspec="$app_root/pubspec.yaml"
readonly apk="$app_root/build/app/outputs/flutter-apk/app-release.apk"
readonly version_code_sed='s/^version:[[:blank:]]*[^+[:blank:]]+\+([0-9]+)[[:blank:]]*(#.*)?$/\1/p'

if [[ ! -f "$pubspec" ]]; then
  echo "expected app pubspec not found: $pubspec" >&2
  exit 1
fi

analyzer=""
if [[ -n "${ANDROID_HOME:-}" ]]; then
  candidate="$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer"
  [[ -x "$candidate" ]] && analyzer="$candidate"
fi
if [[ -z "$analyzer" ]]; then
  analyzer="$(command -v apkanalyzer || true)"
fi
if [[ -z "$analyzer" ]]; then
  echo "apkanalyzer not found; set ANDROID_HOME or PATH" >&2
  exit 1
fi
readonly analyzer

expected_code="$(sed -En "$version_code_sed" "$pubspec")"
if [[ ! "$expected_code" =~ ^[0-9]+$ ]]; then
  echo "app pubspec has no numeric version code" >&2
  exit 1
fi

if [[ ! -f "$apk" ]]; then
  echo "expected APK not found: $apk" >&2
  exit 1
fi

actual_code="$("$analyzer" manifest version-code "$apk")"
if [[ "$actual_code" == "$expected_code" ]]; then
  exit 0
fi

echo "APK versionCode $actual_code, expected $expected_code" >&2
exit 1
