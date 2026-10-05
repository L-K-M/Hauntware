#!/usr/bin/env bash
# Checks a built Flutter macOS app the way macOS treats it once installed.
#
#   scripts/verify-macos-app.sh [products-dir]
#
# products-dir defaults to build/macos/Build/Products/Release under the
# current directory (CI runs it from each app directory) and must hold
# exactly one .app.
#
# 1. Every native-asset framework keeps its own directory. Flutter's embed
#    step rsyncs each native_assets/<name>.framework into
#    Contents/Frameworks/. On a case-insensitive volume (the macOS default)
#    a name that differs only in case from a framework Xcode already
#    embedded, such as pdfium vs PDFium, is written into that framework
#    instead. Whether the result still verifies then depends on build
#    order and incremental state, so this check does not rely on codesign.
# 2. codesign --verify --deep --strict passes: an app whose nested code
#    fails it is refused at launch.
set -euo pipefail
shopt -s nullglob

readonly products="${1:-build/macos/Build/Products/Release}"

apps=("$products"/*.app)
if [[ ${#apps[@]} -ne 1 ]]; then
  echo "expected one .app in $products, found ${#apps[@]}" >&2
  exit 1
fi
readonly app="${apps[0]}"
readonly embedded="$(ls "$app/Contents/Frameworks")"

status=0
for framework in "$products"/native_assets/*.framework; do
  name="$(basename "$framework")"
  if ! grep -qxF "$name" <<<"$embedded"; then
    landed="$(grep -ixF "$name" <<<"$embedded" || echo 'nothing')"
    echo "native asset $name was copied onto $landed in $app" >&2
    status=1
  fi
done

codesign --verify --deep --strict --verbose=2 "$app" || status=1
exit "$status"
