#!/usr/bin/env bash
# Checks the third-party notices inside a built client artifact. Flutter
# writes the license texts of the engine, the Dart runtime, every package
# and the fonts to flutter_assets/NOTICES.Z (gzip); the release archives,
# the Linux packages and the macOS app also carry them readable as
# Third-Party-Notices.txt. CI and release legs run this after the build or
# packaging step, on what ships.
#
#   scripts/check-flutter-notices.sh PRODUCT FILE...
#
# Each FILE is a NOTICES.Z, a readable notices file, or an APK or IPA
# holding a flutter_assets/NOTICES.Z. It must not be empty and must name
# the components PRODUCT bundles from outside the pub graph or under terms
# that need their text: the OFL fonts every app bundles (ghost_fonts) and
# the CC BY-SA credit for the Debian logo glyph in its 3270 font,
# Séance's vendored xterm and flutter_pty, the NuGet libraries the Séance
# and Klabautermann Windows builds compile in, the Swift packages
# file_picker adds to the Séance and Poltergeist iOS builds, Poltergeist's
# PDFium and the Unicode data tables. Exits 1 on any miss.
set -euo pipefail

[[ $# -ge 2 ]] || { echo "usage: $0 PRODUCT FILE..." >&2; exit 2; }
product="$1"
shift

required=('Iosevka Term' 'SIL Open Font License' 'Software in the Public Interest')
case "$product" in
  planchette) ;;
  seance)
    required+=('xterm' 'flutter_pty' 'Windows Implementation Libraries' 'C++/WinRT')
    required+=('DKImagePickerController' 'SDWebImage')
    ;;
  klabautermann) required+=('Windows Implementation Libraries' 'C++/WinRT') ;;
  poltergeist)
    required+=('PDFium' 'PDFium: FreeType' 'UNICODE LICENSE V3')
    required+=('DKImagePickerController' 'SDWebImage')
    ;;
  *) echo "unknown product: $product" >&2; exit 2 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

status=0
for file in "$@"; do
  if [[ ! -s "$file" ]]; then
    echo "error: $file is missing or empty" >&2
    status=1
    continue
  fi

  # Decompress to a file first: grep -q closing a pipe early would fail
  # the pipeline under pipefail.
  notices="$tmp/notices.txt"
  case "$file" in
    *.apk | *.ipa)
      unzip -Z1 "$file" > "$tmp/entries"
      member="$(grep -m1 'flutter_assets/NOTICES\.Z$' "$tmp/entries" || true)"
      if [[ -z "$member" ]]; then
        echo "error: $file holds no flutter_assets/NOTICES.Z" >&2
        status=1
        continue
      fi
      unzip -p "$file" "$member" > "$tmp/notices.z"
      gzip -dc "$tmp/notices.z" > "$notices"
      ;;
    *.Z) gzip -dc "$file" > "$notices" ;;
    *) cp "$file" "$notices" ;;
  esac

  missing=0
  for name in "${required[@]}"; do
    if ! grep -qF -- "$name" "$notices"; then
      echo "error: $file does not name $name" >&2
      missing=1
    fi
  done
  if [[ $missing -eq 0 ]]; then
    echo "ok: $file"
  else
    status=1
  fi
done
exit "$status"
