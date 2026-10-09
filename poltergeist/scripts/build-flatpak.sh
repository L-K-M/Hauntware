#!/usr/bin/env bash
set -euo pipefail
# Build dist/poltergeist-linux-x64.flatpak by repacking the release .deb
# under flatpak's /app prefix — the bundle ships byte-for-byte what the .deb
# installs. Usage:
#   scripts/build-flatpak.sh [--install]     # build the .deb first, then repack
#   scripts/build-flatpak.sh path/to.deb     # repack an existing .deb (CI)
#
# The bundle names Flathub as its runtime's source, so installing it fetches
# the GNOME runtime from there. Needs flatpak and flatpak-builder; both come
# from Flathub (user installation) on the first build.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
readonly APP_ID=ch.lkmc.poltergeist
readonly MANIFEST="$ROOT/flatpak/$APP_ID.yml"
readonly FLATHUB_REPO=https://dl.flathub.org/repo/flathub.flatpakrepo
readonly WORK="$ROOT/dist/flatpak"

die() { echo "build-flatpak.sh: $*" >&2; exit 1; }

INSTALL=0
DEB=""
for argument in "$@"; do
  case "$argument" in
    --install) INSTALL=1 ;;
    -h|--help) awk 'NR==1&&/^#!/{next} /^set -euo pipefail/{next} /^#/{sub(/^# ?/,"");print;next} {exit}' "$0"; exit 0 ;;
    *.deb) [ -z "$DEB" ] || die "pass at most one .deb"; DEB="$argument" ;;
    *) echo "Unknown argument: $argument" >&2; exit 2 ;;
  esac
done

# A relative .deb argument names the caller's directory, not the
# repository root we cd'd into above.
if [[ -n "$DEB" && "$DEB" != /* ]]; then DEB="$OLDPWD/$DEB"; fi

command -v flatpak-builder >/dev/null 2>&1 ||
  die "flatpak-builder not found: install flatpak and flatpak-builder"
command -v dpkg-deb >/dev/null 2>&1 ||
  die "dpkg-deb not found: install dpkg"

if [[ -z "$DEB" ]]; then
  (cd app/poltergeist_app && flutter build linux --release)
  scripts/package-linux.sh --skip-appimage
  DEB="$(find dist -maxdepth 1 -name 'poltergeist_*.deb' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2- || true)"
fi
[ -f "$DEB" ] || die ".deb not found: $DEB"

# The repack and build are shared with the other products' Flatpaks.
# shellcheck source=../../scripts/flatpak-repack.sh
source "$ROOT/../scripts/flatpak-repack.sh"
flatpak_stage_deb "$DEB" "$WORK" "$APP_ID"
flatpak_build "$WORK" "$MANIFEST" "$FLATHUB_REPO"

BUNDLE="$ROOT/dist/poltergeist-linux-x64.flatpak"
flatpak build-bundle --runtime-repo="$FLATHUB_REPO" \
  "$WORK/repo" "$BUNDLE" "$APP_ID"
if ((INSTALL)); then
  flatpak install --user -y --noninteractive "$BUNDLE"
fi
echo "Built ${BUNDLE#"$ROOT"/}"
