#!/usr/bin/env bash
# Checks the third-party notices in a client leg's release assets, as users
# download them (release.yml runs it after each Package step):
#
#   android  the APK's flutter_assets/NOTICES.Z and its Maven library
#            definitions (scripts/android_notices.py)
#   linux    LICENSE and Third-Party-Notices.txt at the tarball's top, the
#            .deb's and the AppImage's /usr/share/doc/<package>/ files
#   macos    <App>.app/Contents/Resources/Third-Party-Notices.txt
#   ios      the IPA's NOTICES.Z and Payload/<App>.app/Third-Party-Notices.txt
#   windows  LICENSE and Third-Party-Notices.txt at the zip's top
#
#   scripts/check-release-notices.sh PRODUCT STEM TARGET
#
# PRODUCT names the Debian package and selects the components
# scripts/check-flutter-notices.sh requires; STEM is the asset stem
# (klabautermann-preview for Klabautermann). Run it in the directory that
# holds the assets.
set -euo pipefail

[[ $# -eq 3 ]] || { echo "usage: $0 PRODUCT STEM TARGET" >&2; exit 2; }
product="$1" stem="$2" target="$3"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
check() { bash "$here/check-flutter-notices.sh" "$product" "$@"; }
present() { [[ -s "$1" ]] || { echo "error: $1 is missing or empty" >&2; exit 1; }; }
only() {  # $1 = description, rest = glob matches; prints the single match
  local what="$1"
  shift
  [[ $# -eq 1 && -e "$1" ]] || { echo "error: expected one $what, found $#: $*" >&2; exit 1; }
  printf '%s\n' "$1"
}

# A relative directory: Git Bash's tar reads "D:" as a remote host.
work=notices-check
rm -rf "$work"
mkdir "$work"

case "$target" in
  android)
    check "$stem-android.apk"
    # The Maven libraries: AboutLibraries' definitions in the APK, and the
    # NOTICE files of the resolved jars and aars (from this job's Gradle
    # cache, or fetched from the apps' repositories when it lacks them).
    python3 -I "$here/android_notices.py" check "$stem-android.apk" --config "$here/android-notices.toml"
    python3 -I "$here/android_notices.py" scan "$stem-android.apk" --config "$here/android-notices.toml" \
      --fetch-from https://dl.google.com/dl/android/maven2 \
      --fetch-from https://repo.maven.apache.org/maven2
    ;;
  linux)
    tar -xzf "$stem-linux-x64.tar.gz" -C "$work"
    present "$work/$stem-linux-x64/LICENSE"
    check "$work/$stem-linux-x64/Third-Party-Notices.txt"

    deb="$(only .deb "$product"_*.deb)"
    dpkg-deb -x "$deb" "$work/deb"
    copyright="$work/deb/usr/share/doc/$product/copyright"
    present "$copyright"
    grep -q 'Third-Party-Notices.txt next to this file' "$copyright"
    check "$work/deb/usr/share/doc/$product/Third-Party-Notices.txt"

    # --appimage-extract unpacks without running the app.
    (cd "$work" && "../$stem-linux-x64.AppImage" --appimage-extract >/dev/null)
    present "$work/squashfs-root/usr/share/doc/$product/copyright"
    check "$work/squashfs-root/usr/share/doc/$product/Third-Party-Notices.txt"
    ;;
  macos)
    ditto -x -k "$stem-macos-universal.zip" "$work"
    app="$(only .app "$work"/*.app)"
    check "$app/Contents/Resources/Third-Party-Notices.txt"
    ;;
  ios)
    check "$stem-ios-unsigned.ipa"
    unzip -q "$stem-ios-unsigned.ipa" -d "$work"
    app="$(only .app "$work"/Payload/*.app)"
    check "$app/Third-Party-Notices.txt"
    ;;
  windows)
    7z x -bd "-o$work" "$stem-windows-x64.zip" >/dev/null
    present "$work/$stem-windows-x64/LICENSE"
    check "$work/$stem-windows-x64/Third-Party-Notices.txt"
    ;;
  *)
    echo "unknown target: $target" >&2
    exit 2
    ;;
esac
rm -rf "$work"
