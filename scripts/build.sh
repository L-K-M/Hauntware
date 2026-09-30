#!/usr/bin/env bash
# Build the desktop app for this host and stage it under dist/.
# Usage: scripts/build.sh [--debug] [--install] [--flatpak] [app]
# --install additionally installs the app for the current user/host.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode=release
install=false
flatpak=false
for argument in "$@"; do
  case "$argument" in
    --debug) mode=debug ;;
    --install) install=true ;;
    --flatpak) flatpak=true ;;
    app) ;;
    --help|-h)
      echo 'Usage: scripts/build.sh [--debug] [--install] [--flatpak] [app]'
      exit 0 ;;
    *) echo "Unknown argument: $argument" >&2; exit 1 ;;
  esac
done
case "$(uname -s)" in
  Darwin) target=macos ;;
  Linux) target=linux ;;
  MINGW*|MSYS*|CYGWIN*) target=windows ;;
  *) echo 'This host is not a supported desktop platform.' >&2; exit 1 ;;
esac
command -v flutter >/dev/null || { echo 'Flutter is required.' >&2; exit 1; }
app="$root/app/planchette_app"
[[ -d "$app/$target" ]] || { echo "Missing committed $target scaffold." >&2; exit 1; }
(
  cd "$app"
  flutter pub get
  flutter build "$target" "--$mode"
)
mkdir -p "$root/dist"
case "$target" in
  macos)
    configuration=Release
    [[ "$mode" == debug ]] && configuration=Debug
    source="$app/build/macos/Build/Products/$configuration/Planchette.app"
    destination="$root/dist/Planchette.app"
    rm -rf "$destination"
    ditto "$source" "$destination"
    if $install; then
      ditto "$destination" /Applications/Planchette.app
      echo 'Installed /Applications/Planchette.app'
    fi ;;
  linux)
    source="$app/build/linux/x64/$mode/bundle"
    destination="$root/dist/planchette-linux-x64"
    rm -rf "$destination"
    cp -R "$source" "$destination"
    cp "$root/media-sources/icon.png" "$destination/planchette.png"
    if [[ "$mode" == release ]]; then
      "$root/scripts/package-linux.sh" --bundle "$source" --appimage=best-effort
    elif $flatpak; then
      "$root/scripts/package-linux.sh" --bundle "$source" --skip-appimage
    fi
    if $flatpak; then
      "$root/scripts/build-flatpak.sh" "$(find "$root/dist" -maxdepth 1 -type f -name 'planchette_*.deb' -printf '%T@\t%p\n' | sort -rn | head -n1 | cut -f2-)"
    fi
    if $install; then
      installed="$HOME/.local/opt/planchette"
      mkdir -p "$HOME/.local/opt" "$HOME/.local/share/applications" "$HOME/.local/share/icons/hicolor/256x256/apps"
      rm -rf "$installed"
      cp -R "$destination" "$installed"
      cp "$root/media-sources/icon.png" "$HOME/.local/share/icons/hicolor/256x256/apps/planchette.png"
      cat > "$HOME/.local/share/applications/com.lkm.planchette_app.desktop" <<DESKTOP
[Desktop Entry]
Type=Application
Name=Planchette
GenericName=Text Editor
Exec="$installed/planchette" %F
Icon=planchette
Terminal=false
Categories=Utility;TextEditor;
MimeType=text/plain;text/x-source;
StartupWMClass=Com.lkm.planchette_app
DESKTOP
      if command -v update-desktop-database >/dev/null; then
        update-desktop-database "$HOME/.local/share/applications"
      fi
      echo "Installed $installed"
    fi ;;
  windows)
    configuration=Release
    [[ "$mode" == debug ]] && configuration=Debug
    source="$app/build/windows/x64/runner/$configuration"
    destination="$root/dist/planchette-windows-x64"
    rm -rf "$destination"
    cp -R "$source" "$destination"
    if $install; then
      echo 'The Windows build is portable. Run dist/planchette-windows-x64/planchette.exe.'
    fi ;;
esac
echo "Built $destination"
