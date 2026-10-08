# shellcheck shell=bash
# Repacks a product's release .deb under flatpak's /app prefix and builds
# it, so the bundle ships byte-for-byte what the .deb installs. Sourced by
# planchette/, seance/ and poltergeist/scripts/build-flatpak.sh, which keep
# their arguments, the .deb build and the bundle name; callers define
# die(). tool/release_version/test/flatpak_repack_test.dart sources it
# directly.
#
#   .deb  usr/bin/<command>     wrapper: exec /usr/lib/<app>/<binary>
#         usr/lib/<app>/...     the Flutter bundle
#         usr/share/...         desktop entry and icons
#           |  flatpak_stage_deb: /usr -> /app, desktop and icon renamed
#           v  to the app id
#   $work/stage  ->  flatpak_build: flatpak-builder, then the smoke check
#                    inside the built sandbox

# The smoke check run inside the built sandbox, as `sh -c` with $1 the
# manifest's command and $2 the prefix (/app). The command is the .deb's
# wrapper script, so the check follows its exec line to the real binary:
# the binary must exist after the /usr -> /app remap, and every library it
# links must resolve. ldd on the wrapper itself proves nothing — it is not
# an ELF.
# shellcheck disable=SC2016  # expanded by the sandbox's sh, not here
FLATPAK_SMOKE_CHECK='
fail() { echo "flatpak smoke check: $*" >&2; exit 1; }
bin="$2/bin/$1"
[ -x "$bin" ] || { ls -l "$2/bin" >&2; fail "missing $bin"; }
target="$bin"
if [ "$(head -c 2 "$bin")" = "#!" ]; then
  target="$(sed -n "s/^exec \([^ ]*\).*/\1/p" "$bin" | head -n 1)"
  [ -n "$target" ] || fail "$bin is a script without an exec line"
  [ -x "$target" ] || fail "$bin runs $target, which is missing"
fi
libs="$(ldd "$target" 2>&1)" || fail "ldd cannot read $target: $libs"
bad="$(printf "%s\n" "$libs" | grep "not found" || true)"
[ -z "$bad" ] || fail "unresolved libraries in $target:
$bad"
'

# Extracts <deb> into <work>/stage with Debian's /usr remapped to /app and
# the desktop entry and icon named after <app-id>.
flatpak_stage_deb() {
  local deb="$1" work="$2" app_id="$3" extra f desktop icon
  rm -rf "$work/debroot" "$work/stage" "$work/build" "$work/repo"
  mkdir -p "$work"   # dpkg-deb creates the target dir but not its parents
  dpkg-deb -x "$deb" "$work/debroot"
  mkdir -p "$work/stage"
  extra="$(find "$work/debroot" -mindepth 1 -maxdepth 1 -not -name usr -not -name DEBIAN 2>/dev/null || true)"
  [ -z "$extra" ] || die "$deb ships paths outside /usr that staging would drop: $extra"
  cp -a "$work/debroot/usr/." "$work/stage/"

  # Shipped text files (wrappers, launchers, python) hardcode /usr; inside
  # flatpak the prefix is /app.
  while IFS= read -r f; do
    sed -i '/^#!/!s|/usr/|/app/|g' "$f"
  done < <(grep -rIl '/usr/' "$work/stage" 2>/dev/null || true)
  while IFS= read -r f; do
    sed -i -e 's|Exec=/usr/bin/|Exec=|g' -e 's|Exec=/opt/[^/]*/bin/|Exec=|g' -e 's|Exec=/app/bin/|Exec=|g' -e '/^TryExec=/d' "$f"
  done < <(find "$work/stage/share/applications" -type f -name '*.desktop' 2>/dev/null)

  # flatpak exports the desktop file and icons only when they are named
  # after the app id; the bundler names them after the binary instead.
  desktop="$(find "$work/stage/share/applications" -type f -name '*.desktop' -print -quit 2>/dev/null || true)"
  [ -n "$desktop" ] || die "no .desktop file inside $deb"
  [ "$(basename "$desktop")" = "$app_id.desktop" ] ||
    mv "$desktop" "$work/stage/share/applications/$app_id.desktop"
  desktop="$work/stage/share/applications/$app_id.desktop"
  # The launcher resolves Icon= through flatpak's exported name.
  sed -i "s|^Icon=.*|Icon=$app_id|" "$desktop"
  if ! find "$work/stage/share/icons" "$work/stage/share/pixmaps" -name "$app_id.*" -print -quit 2>/dev/null | grep -q .; then
    icon="$(find "$work/stage/share/icons" "$work/stage/share/pixmaps" -name '*.png' -printf '%s\t%p\n' 2>/dev/null | sort -rn | head -n1 | cut -f2- || true)"
    [ -n "$icon" ] || icon="$(find "$work/stage/share/icons" "$work/stage/share/pixmaps" \( -name '*.svg' -o -name '*.png' \) -print -quit 2>/dev/null || true)"
    [ -n "$icon" ] || die "no icon inside $deb"
    mkdir -p "$work/stage/share/icons/hicolor/256x256/apps"
    cp "$icon" "$work/stage/share/icons/hicolor/256x256/apps/$app_id.${icon##*.}"
  fi
}

# Builds <work>/stage per <manifest> into <work>/build and <work>/repo, with
# the runtime from <flathub-repo>, then runs the smoke check in the result.
flatpak_build() {
  local work="$1" manifest="$2" flathub_repo="$3" command_name
  flatpak remote-add --user --if-not-exists flathub "$flathub_repo"
  # --disable-rofiles-fuse: containers (CI) have no FUSE, and a copy-only
  # build gains nothing from it.
  flatpak-builder --user --install-deps-from=flathub --force-clean \
    --disable-rofiles-fuse \
    --state-dir="$work/state" --repo="$work/repo" \
    "$work/build" "$manifest"

  command_name="$(sed -n '/^command:[[:space:]]*/{s///;p;q}' "$manifest")"
  [ -n "$command_name" ] || die "no command: key in $manifest"
  flatpak-builder --run "$work/build" "$manifest" \
    sh -c "$FLATPAK_SMOKE_CHECK" _ "$command_name" /app
}
