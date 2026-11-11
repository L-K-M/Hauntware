# shellcheck shell=bash
# The body of the products' scripts/build-flatpak.sh: parse the
# arguments, build the .deb when none is given, then repack it as the
# Flatpak bundle (scripts/flatpak-repack.sh) and optionally install it.
# Each wrapper documents its arguments in its header comment, which is
# what --help prints, sets the values below, cds to ROOT, sources this
# file and calls build_flatpak_main "$@".
#
#   ROOT          product root; the bundle goes to $ROOT/dist
#   APP_ID        Flatpak app id; the manifest is flatpak/<APP_ID>.yml
#   ASSET_STEM    release asset stem: dist/<stem>-linux-x64.flatpak
#   APP_DIR       the Flutter app, relative to ROOT
#   PACKAGE_NAME  Debian package name: the .deb is dist/<name>_*.deb

readonly MANIFEST="$ROOT/flatpak/$APP_ID.yml"
readonly FLATHUB_REPO=https://dl.flathub.org/repo/flathub.flatpakrepo
readonly WORK="$ROOT/dist/flatpak"

die() { echo "build-flatpak.sh: $*" >&2; exit 1; }

build_flatpak_main() {
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
  # repository root the wrapper cd'd into.
  if [[ -n "$DEB" && "$DEB" != /* ]]; then DEB="$OLDPWD/$DEB"; fi

  command -v flatpak-builder >/dev/null 2>&1 ||
    die "flatpak-builder not found: install flatpak and flatpak-builder"
  command -v dpkg-deb >/dev/null 2>&1 ||
    die "dpkg-deb not found: install dpkg"

  if [[ -z "$DEB" ]]; then
    (cd "$APP_DIR" && flutter build linux --release)
    scripts/package-linux.sh --skip-appimage
    DEB="$(find dist -maxdepth 1 -name "${PACKAGE_NAME}_*.deb" -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2- || true)"
  fi
  [ -f "$DEB" ] || die ".deb not found: $DEB"

  # The repack and build are shared with flatpak_repack_test.dart, which
  # sources the helper on its own.
  # shellcheck source=SCRIPTDIR/flatpak-repack.sh
  source "$ROOT/../scripts/flatpak-repack.sh"
  flatpak_stage_deb "$DEB" "$WORK" "$APP_ID"
  flatpak_build "$WORK" "$MANIFEST" "$FLATHUB_REPO"

  BUNDLE="$ROOT/dist/$ASSET_STEM-linux-x64.flatpak"
  flatpak build-bundle --runtime-repo="$FLATHUB_REPO" \
    "$WORK/repo" "$BUNDLE" "$APP_ID"
  if ((INSTALL)); then
    flatpak install --user -y --noninteractive "$BUNDLE"
  fi
  echo "Built ${BUNDLE#"$ROOT"/}"
}
