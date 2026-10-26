# shellcheck shell=bash
# The Linux packager shared by the products' scripts/package-linux.sh
# wrappers: it turns a built Flutter Linux bundle into a .deb and an
# AppImage. Each wrapper sets its identities, defines its desktop entry,
# sources this file and calls package_linux_main "$@"; the arguments,
# environment and outputs are documented in the wrapper's own header,
# which is also what --help prints. Sourcing only defines functions,
# constants and the soname table, so tests can source it on its own.
#
# The wrapper sets, before calling package_linux_main:
#
#   SELF                 absolute path of the wrapper (--help prints its
#                        header comment)
#   ROOT                 product root; artifacts go to $ROOT/dist unless
#                        --output-dir says otherwise
#   APP_DIR              the Flutter app (bundle search, pubspec version)
#   PRODUCT_NAME         display name for progress and error messages
#   PACKAGE_NAME         Debian package name; also /usr/bin/<name>,
#                        /usr/lib/<name>/, the doc directory, the icon
#                        name and the appimagetool cache ~/.cache/<name>
#   ASSET_STEM           release asset stem: <stem>-linux-<arch>.AppImage
#   BUNDLE_EXECUTABLE    the runner binary inside the bundle
#   LINUX_DESKTOP_FILE   desktop entry file name (the application id plus
#                        .desktop; Wayland matches it to the GApplication id)
#   MASTER_ICON          square PNG resized into the hicolor sizes
#   LICENSE_FILE         embedded verbatim in the Debian copyright file
#   DEB_SECTION          Debian Section field
#   DEB_DESCRIPTION      Debian Description field: the synopsis, then
#                        extended lines each starting with one space
#   DEB_COPYRIGHT_TITLE  first line of the Debian copyright file
#   EXTRA_DEPENDS        optional array of Depends entries for runtime tools
#                        the app spawns (invisible to the ELF scan)
#
# and defines write_desktop_file <path> <exec>, which writes the desktop
# entry with Exec=<exec> and Icon=$PACKAGE_NAME. A product that links a
# system library missing from SONAME_TO_DEP below adds the entry here, so
# every product shares one table.
#
# Everything else is derived from the actual build output: the .deb's
# dependency list from the ELF headers of the bundle (readelf NEEDED + the
# soname→package table, with the Ubuntu 24.04 "t64" rename handled as dpkg
# alternatives), and the glibc/libstdc++ floors from the symbol versions the
# bundle references, so a plugin or toolchain change can't silently make the
# shipped Depends stale. Unknown sonames fail the build on purpose: adding a
# plugin that links a new system library must force a conscious table update.

PACKAGE_LINUX_COMMON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# The ABI-tag → GCC mapping is shared with the other Linux packagers.
# shellcheck source=package-linux-gcc-floors.sh
source "$(dirname "$PACKAGE_LINUX_COMMON")/package-linux-gcc-floors.sh"

# Every product's package names the same suite maintainer and homepage.
readonly DEB_MAINTAINER="L-K-M <l-k-m@users.noreply.github.com>"
readonly DEB_HOMEPAGE="https://github.com/L-K-M/Hauntware"
readonly ICON_SIZES=(16 24 32 48 64 96 128 256 512)

declare -gA SONAME_TO_DEP=(
  # glibc + toolchain runtimes
  [ld-linux-x86-64.so.2]='libc6'  [ld-linux-aarch64.so.1]='libc6'
  [libc.so.6]='libc6'  [libm.so.6]='libc6'  [libdl.so.2]='libc6'
  [libpthread.so.0]='libc6'  [librt.so.1]='libc6'  [libresolv.so.2]='libc6'
  [libgcc_s.so.1]='libgcc-s1'
  [libstdc++.so.6]='libstdc++6'
  # GTK stack
  [libgtk-3.so.0]='libgtk-3-0 | libgtk-3-0t64'
  [libgdk-3.so.0]='libgtk-3-0 | libgtk-3-0t64'
  [libglib-2.0.so.0]='libglib2.0-0 | libglib2.0-0t64'
  [libgio-2.0.so.0]='libglib2.0-0 | libglib2.0-0t64'
  [libgobject-2.0.so.0]='libglib2.0-0 | libglib2.0-0t64'
  [libgmodule-2.0.so.0]='libglib2.0-0 | libglib2.0-0t64'
  [libatk-1.0.so.0]='libatk1.0-0 | libatk1.0-0t64'
  [libcairo.so.2]='libcairo2'
  [libcairo-gobject.so.2]='libcairo2'
  [libgdk_pixbuf-2.0.so.0]='libgdk-pixbuf-2.0-0 | libgdk-pixbuf-2.0-0t64'
  [libpango-1.0.so.0]='libpango-1.0-0 | libpango-1.0-0t64'
  [libpangocairo-1.0.so.0]='libpangocairo-1.0-0 | libpangocairo-1.0-0t64'
  [libharfbuzz.so.0]='libharfbuzz0b'
  [libfontconfig.so.1]='libfontconfig1'
  [libepoxy.so.0]='libepoxy0'
  [libz.so.1]='zlib1g'
  # flutter_secure_storage's keyring backend
  [libsecret-1.so.0]='libsecret-1-0'
  # libsecret pulls gcrypt via pinentry on some setups; harmless if unused.
  [libgcrypt.so.20]='libgcrypt20'
)

# Sonames that are deliberately NOT Depends entries — known-conditional deps
# of vendored native assets, loaded lazily and only if the app ever uses the
# owning package. libjvm.so: needed by libdartjni.so (package:jni's native
# asset, which enters the graph via path_provider_android but is never used
# on Linux) — a JRE in Depends would be absurd for these apps. If JNI ever
# becomes a real dependency, drop the entry and depend on a JRE instead.
declare -gA SONAME_OPTIONAL=([libjvm.so]='package:jni native asset; lazily dlopen-ed, unused on Linux')

usage() {
  awk 'NR==1 && /^#!/ {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "$SELF"
  exit "${1:-0}"
}

die() { echo "package-linux: $*" >&2; exit 1; }

# A wrapper that forgets an identity must stop here, not ship a package
# with an empty name or path in it.
package_linux_require() {
  local name
  for name in SELF ROOT APP_DIR PRODUCT_NAME PACKAGE_NAME ASSET_STEM \
      BUNDLE_EXECUTABLE LINUX_DESKTOP_FILE MASTER_ICON LICENSE_FILE \
      DEB_SECTION DEB_DESCRIPTION DEB_COPYRIGHT_TITLE; do
    [[ -n "${!name:-}" ]] || die "the wrapper did not set $name (see $PACKAGE_LINUX_COMMON)"
  done
  declare -F write_desktop_file >/dev/null \
    || die "the wrapper did not define write_desktop_file (see $PACKAGE_LINUX_COMMON)"
}

dep_add() {  # $1 = dependency string; may be "pkg | pkg-t64" (contains spaces)
  local key="${1%% |*}"   # dedupe on the first package name
  if [[ -n "${DEP_SEEN[$key]:-}" ]]; then return 0; fi
  DEP_SEEN["$key"]=1
  DEP_STRS+=("$1")
}
dep_version() {  # $1 = package (never carries alternatives), $2 = versioned string
  local i found=0
  for i in "${!DEP_STRS[@]}"; do
    if [[ "${DEP_STRS[$i]}" == "$1" || "${DEP_STRS[$i]}" == "$1 "* ]]; then
      DEP_STRS[$i]="$2"; found=1; break
    fi
  done
  if [[ $found -eq 0 ]]; then dep_add "$2"; fi
}

# Version floors from the symbol versions actually referenced — what
# dh_shlibdeps would compute for us. Only meaningful for the base runtimes.
floor_of() {  # $1 = objdump tag prefix (e.g. GLIBC_), max across all ELFs
  # sort -Vu is version-aware (2.14 > 2.9); trust it instead of re-comparing.
  # `|| true`: grep exits 1 when a file references none of the tags, and
  # `set -e` would turn that into an abort mid-loop. A failed
  # or empty objdump run instead means a bad ELF — die rather than let the
  # floor silently drop. The loop must accumulate, not pipe: inside a
  # pipeline it runs in a subshell whose exit cannot abort the script.
  local tag="$1" f symbols versions=""
  for f in "${ELFS[@]}"; do
    symbols="$(objdump -T "$f")" \
      || die "objdump failed on $(basename "$f") — cannot compute $tag floor"
    [[ -n $symbols ]] \
      || die "no dynamic symbols in $(basename "$f") — cannot compute $tag floor"
    versions+="$(grep -o "${tag}[0-9.]*" <<<"$symbols" || true)"$'\n'
  done
  sed "s/^$tag//" <<<"$versions" | sort -Vu | tail -1
}

# ---------------------------------------------------------------------------
# Icon generation — the one vector-of-truth master, resized into hicolor.
# image magick: prefer `magick` (IM7), fall back to `convert` (IM6). Without
# either, fall back to shipping the master as a pixmaps icon (every desktop
# environment finds /usr/share/pixmaps) and say so.
# ---------------------------------------------------------------------------
make_icon() {  # $1 src, $2 out png, $3 size
  if command -v magick >/dev/null 2>&1; then
    magick "$1" -resize "${3}x${3}" "$2"
  elif command -v convert >/dev/null 2>&1; then
    convert "$1" -resize "${3}x${3}" "$2"
  else
    return 1
  fi
}

install_icons() {  # $1 = destination usr/ root (deb tree or AppDir)
  local usr="$1" ok=1 size
  for size in "${ICON_SIZES[@]}"; do
    mkdir -p "$usr/share/icons/hicolor/${size}x${size}/apps"
    make_icon "$MASTER_ICON" "$usr/share/icons/hicolor/${size}x${size}/apps/$PACKAGE_NAME.png" "$size" || { ok=0; break; }
  done
  if [[ $ok -eq 1 ]]; then
    return 0
  fi
  echo ".. package-linux: no ImageMagick found — installing the unresized master icon to pixmaps" >&2
  rm -rf "$usr/share/icons/hicolor"
  mkdir -p "$usr/share/pixmaps"
  cp "$MASTER_ICON" "$usr/share/pixmaps/$PACKAGE_NAME.png"
}

# --- copyright file writer (tests extract this block; keep the markers) -----
# The Debian copyright file must carry the license text verbatim — a bare
# pointer to the repository leaves the .deb's licensing undiscoverable
# offline. The Unlicense covers the package's own code only; the bundled
# components keep their own licenses, whose texts write_third_party_notices
# puts next to this file. Uses $DEB_COPYRIGHT_TITLE, $VERSION and
# $LICENSE_FILE.
write_copyright() {  # $1 = destination
  {
    cat <<EOF
$DEB_COPYRIGHT_TITLE
Source: https://github.com/L-K-M/Hauntware
Upstream-Version: $VERSION
License: Unlicense — the full text follows. It covers this package's own
code; the bundled third-party components below keep their own licenses.

EOF
    cat "$LICENSE_FILE"
    cat <<EOF

Bundled third-party components: the Flutter engine, the Dart runtime, the
pub packages and native libraries the app compiles in (vendored ones
included) and the bundled fonts keep their own licenses. Their license and
notice texts are in Third-Party-Notices.txt next to this file.
EOF
  } > "$1"
}
# --- end copyright file writer ----------------------------------------------

# --- third-party notices writer (tests extract this block; keep the markers)
# Flutter collects the license texts of the engine, the Dart runtime, every
# package (with any extra chunks in their LICENSE files) and the fonts into
# the bundle's data/flutter_assets/NOTICES.Z, gzip-compressed. The package
# ships them readable; a bundle without them must not be packaged.
write_third_party_notices() {  # $1 = bundle, $2 = destination
  local notices="$1/data/flutter_assets/NOTICES.Z"
  [[ -s "$notices" ]] \
    || die "$notices not found — the package must carry the bundled components' notices"
  gzip -dc "$notices" > "$2" || die "cannot decompress $notices"
  [[ -s "$2" ]] || die "$notices holds no notices"
}
# --- end third-party notices writer -----------------------------------------

# Sets APPIMAGE_TOOL: the env override (path or URL) or the pinned release
# asset for this build host, downloaded once into ~/.cache/$PACKAGE_NAME.
resolve_appimagetool() {
  local host_arch url
  case "$(uname -m)" in
    x86_64) host_arch="x86_64" ;;
    aarch64|arm64) host_arch="aarch64" ;;
    *) die "appimagetool has no build for $(uname -m)" ;;
  esac
  url="${APPIMAGETOOL:-https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-$host_arch.AppImage}"
  if [[ "$url" != http* ]]; then   # a path, not a URL
    [[ -x "$url" ]] || die "APPIMAGETOOL=$url is not executable"
    APPIMAGE_TOOL="$url"; return 0
  fi
  local cache
  cache="$HOME/.cache/$PACKAGE_NAME/$(basename "$url")"
  if [[ ! -x "$cache" ]]; then
    echo "-- fetching appimagetool ($url)"
    mkdir -p "$(dirname "$cache")"
    command -v curl >/dev/null 2>&1 || die "curl not found (set APPIMAGETOOL to a local appimagetool)"
    curl -fL --retry 3 -o "$cache.part" "$url" && chmod 755 "$cache.part" && mv "$cache.part" "$cache"
  fi
  APPIMAGE_TOOL="$cache"
}

# appimagetool shells out to `file` (and to mksquashfs, which it bundles);
# check upfront so the failure is a clear message, not a mid-build one.
appimage_prereqs() {
  command -v file >/dev/null 2>&1 \
    || die "'file' not found — appimagetool requires it (apt install file / dnf install file / …)"
}

# ---------------------------------------------------------------------------
# The AppImage: same payload as the deb (shares the staged usr/), an AppRun
# wrapper instead of /usr/bin, and the desktop entry at the AppDir root.
# ---------------------------------------------------------------------------
build_appimage() {
  local appdir="$WORK/appimage" out="$OUT_DIR/$ASSET_STEM-linux-$FLUTTER_ARCH.AppImage"
  install -d "$appdir/usr"
  cp -a "$DEBROOT/usr/." "$appdir/usr/"
  rm -rf "${appdir:?}/usr/bin"   # the deb's wrapper hardcodes /usr/lib — dead
                               # weight here; AppRun is the entry point

  write_desktop_file "$appdir/$LINUX_DESKTOP_FILE" "AppRun"
  # appimagetool wants the icon named after Icon= at the AppDir root, plus
  # .DirIcon for file managers.
  make_icon "$MASTER_ICON" "$appdir/$PACKAGE_NAME.png" 512 \
    || cp "$MASTER_ICON" "$appdir/$PACKAGE_NAME.png"
  cp "$appdir/$PACKAGE_NAME.png" "$appdir/.DirIcon"

  cat > "$appdir/AppRun" <<EOF
#!/bin/sh
# AppImages mount read-only at a random path; resolve through symlinks so the
# runner's \$ORIGIN-relative lib/ and data/ lookups work.
HERE="\$(dirname "\$(readlink -f "\$0")")"
exec "\$HERE/usr/lib/$PACKAGE_NAME/$BUNDLE_EXECUTABLE" "\$@"
EOF
  chmod 755 "$appdir/AppRun"

  # appimagetool: a pinned release asset, cached across runs. The tool's arch
  # is the BUILD host's (it embeds the target runtime per ARCH=, so an x86_64
  # tool packages arm64 images fine). APPIMAGETOOL may be a path or a URL.
  resolve_appimagetool   # sets APPIMAGE_TOOL
  appimage_prereqs
  local tool="$APPIMAGE_TOOL"

  echo "-- appimagetool → $(basename "$out")"
  # No AppStream metainfo yet — pass --no-appstream rather than shipping an
  # empty one. EXTRACT_AND_RUN keeps the tool working where FUSE can't mount
  # (CI containers, this dev container, …).
  if ARCH="$APPIMAGE_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 "$tool" \
      --no-appstream "$appdir" "$out" >/dev/null 2>&1; then
    :
  else
    # Retry once with output visible so the failure is diagnosable.
    ARCH="$APPIMAGE_ARCH" APPIMAGE_EXTRACT_AND_RUN=1 "$tool" \
      --no-appstream "$appdir" "$out"
  fi
}

package_linux_main() {
  package_linux_require

  BUNDLE=""
  PROFILE="release"
  OUT_DIR="$ROOT/dist"
  APPIMAGE_MODE="required"   # required | best-effort | skip
  PRINT_DEPS=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage 0 ;;
      --bundle) BUNDLE="${2:?}"; shift 2 ;;
      --profile) PROFILE="${2:?}"; shift 2 ;;
      --output-dir) OUT_DIR="${2:?}"; shift 2 ;;
      --appimage) APPIMAGE_MODE="${2:?}"; shift 2 ;;
      --appimage=*) APPIMAGE_MODE="${1#*=}"; shift ;;
      --skip-appimage) APPIMAGE_MODE="skip"; shift ;;
      --print-deps) PRINT_DEPS=true; shift ;;
      *) echo "unknown argument: $1" >&2; usage 1 ;;
    esac
  done

  [[ "$APPIMAGE_MODE" =~ ^(required|best-effort|skip)$ ]] \
    || die "--appimage must be required|best-effort|skip (got: $APPIMAGE_MODE)"

  command -v readelf >/dev/null 2>&1 \
    || die "readelf not found — install binutils (the .deb dependency list is derived from the ELF headers)"
  # floor_of() calls objdump -T; a partial binutils install would leave
  # the glibc/libstdc++/libgcc floors silently empty and ship unversioned
  # runtime deps that install on systems too old to run the bundle.
  command -v objdump >/dev/null 2>&1 \
    || die "objdump not found — install binutils (the .deb version floors are derived from referenced symbol versions)"

  # -------------------------------------------------------------------------
  # Locate the bundle and derive the architecture from it (not from uname:
  # the point of packaging is what's IN the bundle).
  # -------------------------------------------------------------------------
  if [[ -z "$BUNDLE" ]]; then
    # Prefer the requested profile, fall back to the other one.
    local -a search
    if [[ "$PROFILE" == "debug" ]]; then search=(debug release); else search=(release debug); fi
    local p
    for p in "${search[@]}"; do
      BUNDLE="$(ls -d "$APP_DIR"/build/linux/*/"$p"/bundle 2>/dev/null | head -1 || true)"
      [[ -n "$BUNDLE" ]] && { PROFILE="$p"; break; }
    done
    [[ -n "$BUNDLE" ]] || die "no built bundle found under $APP_DIR/build/linux/*/…/bundle — run 'flutter build linux --release' first (or pass --bundle)"
  fi
  [[ -f "$BUNDLE/$BUNDLE_EXECUTABLE" ]] || die "$BUNDLE has no $BUNDLE_EXECUTABLE executable — not a $PRODUCT_NAME Linux bundle?"

  case "$BUNDLE" in
    */linux/x64/*|*/linux-x64/*) FLUTTER_ARCH="x64" ;;
    */linux/arm64/*|*/linux-arm64/*) FLUTTER_ARCH="arm64" ;;
    *) # Custom --bundle path: ask the ELF itself.
       case "$(readelf -h "$BUNDLE/$BUNDLE_EXECUTABLE" | sed -n 's/.*Machine:[[:space:]]*//p')" in
         *"X86-64"*) FLUTTER_ARCH="x64" ;;
         *"AArch64"*) FLUTTER_ARCH="arm64" ;;
         *) die "cannot determine architecture of $BUNDLE/$BUNDLE_EXECUTABLE" ;;
       esac ;;
  esac
  case "$FLUTTER_ARCH" in
    x64)   DEB_ARCH="amd64";  APPIMAGE_ARCH="x86_64" ;;
    arm64) DEB_ARCH="arm64";  APPIMAGE_ARCH="aarch64" ;;
  esac

  VERSION="$(sed -n 's/^version:[[:space:]]*//p' "$APP_DIR/pubspec.yaml" | head -1)"
  VERSION="${VERSION%%+*}"   # strip the Flutter build number, if any
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad/missing version in $APP_DIR/pubspec.yaml (got '${VERSION:-nothing}')"
  DEB_VERSION="$VERSION-1"

  echo "Packaging $PRODUCT_NAME $DEB_VERSION ($FLUTTER_ARCH → deb:$DEB_ARCH appimage:$APPIMAGE_ARCH)"
  echo "  bundle: $BUNDLE"

  # -------------------------------------------------------------------------
  # Dependency derivation. All ELFs in the bundle (exe + lib/*.so), their
  # DT_NEEDED entries mapped to Debian packages; sonames that ship *inside*
  # the bundle (plugins, the engine) are not dependencies. The "t64"
  # alternatives cover the 64-bit-time_t package renames in Ubuntu
  # 24.04/Debian 13 — the library files and sonames are identical, only the
  # package names changed.
  # -------------------------------------------------------------------------
  ELFS=("$BUNDLE/$BUNDLE_EXECUTABLE")
  local so
  while IFS= read -r so; do ELFS+=("$so"); done < <(find "$BUNDLE/lib" -name '*.so*' -type f | sort)

  local -a unknown=() unknown_detail=()   # detail: "file → soname" — attribution for the error message
  declare -gA DEP_SEEN=()
  DEP_STRS=()
  local f soname
  for f in "${ELFS[@]}"; do
    while IFS= read -r soname; do
      [[ -z "$soname" ]] && continue
      # Bundled, not a system dep: the engine and the plugins live in lib/.
      [[ -e "$BUNDLE/lib/$soname" ]] && continue
      if [[ -n "${SONAME_TO_DEP[$soname]:-}" ]]; then
        dep_add "${SONAME_TO_DEP[$soname]}"
      elif [[ -n "${SONAME_OPTIONAL[$soname]:-}" ]]; then
        continue   # documented non-dependency (see SONAME_OPTIONAL above)
      else
        unknown+=("$soname")
        unknown_detail+=("$(basename "$f") → $soname")
      fi
    done < <(readelf -d "$f" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
  done
  if ((${#unknown[@]})); then
    die "unmapped soname(s): ${unknown[*]} — add them to SONAME_TO_DEP in $PACKAGE_LINUX_COMMON (check: dpkg -S /usr/lib/*/libX.so.N). Needed by: ${unknown_detail[*]}"
  fi

  # Runtime tools the app spawns, from the wrapper's EXTRA_DEPENDS.
  local dep
  for dep in ${EXTRA_DEPENDS[@]+"${EXTRA_DEPENDS[@]}"}; do dep_add "$dep"; done

  # The tests assert by these names that a raw ABI tag never reaches
  # Depends; only its mapped GCC release may.
  local mapped
  GLIBC_FLOOR="$(floor_of GLIBC_)"
  GLIBCXX_TAG="$(floor_of GLIBCXX_)"
  GCC_TAG="$(floor_of GCC_)"

  [[ -z "$GLIBC_FLOOR" ]] || dep_version libc6 "libc6 (>= $GLIBC_FLOOR)"
  if [[ -n "$GLIBCXX_TAG" ]]; then
    mapped="$(glibcxx_gcc "$GLIBCXX_TAG")" \
      || die "no GCC mapping for GLIBCXX_$GLIBCXX_TAG — extend glibcxx_gcc in scripts/package-linux-gcc-floors.sh (source: GCC's ABI policy table)"
    # An empty mapping keeps the soname map's unversioned dependency —
    # "libstdc++6 (>= )" would not parse.
    [[ -n "$mapped" ]] && dep_version libstdc++6 "libstdc++6 (>= $mapped)"
  fi
  if [[ -n "$GCC_TAG" ]]; then
    mapped="$(gcc_gcc "$GCC_TAG")" \
      || die "no GCC mapping for GCC_$GCC_TAG — extend gcc_gcc in scripts/package-linux-gcc-floors.sh"
    [[ -n "$mapped" ]] && dep_version libgcc-s1 "libgcc-s1 (>= $mapped)"
  fi

  # dpkg control wants ", " separators, in a stable order (alternatives keep
  # their internal "|" order; sort only whole entries).
  local d
  DEPENDS=""
  while IFS= read -r d; do DEPENDS+=",$d"; done < <(printf '%s\n' "${DEP_STRS[@]}" | sort)
  DEPENDS="${DEPENDS#,}"
  DEPENDS="${DEPENDS//,/, }"

  if $PRINT_DEPS; then
    echo "Depends: $DEPENDS"
    exit 0
  fi
  echo "  depends: $DEPENDS"

  [[ -f "$MASTER_ICON" ]] || die "master icon not found: $MASTER_ICON"

  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT

  # -------------------------------------------------------------------------
  # The .deb. The staged usr/ tree is shared with the AppImage below, so a
  # host without dpkg-deb (Arch, Fedora, …) still gets that.
  # -------------------------------------------------------------------------
  local have_dpkg=false
  if command -v dpkg-deb >/dev/null 2>&1; then
    have_dpkg=true
  else
    if [[ "$APPIMAGE_MODE" == "skip" ]]; then
      die "dpkg-deb not found and the AppImage is skipped — nothing to build"
    fi
    echo ".. no dpkg-deb on this host — building the AppImage only (the .deb needs a Debian-family host)" >&2
  fi

  DEBROOT="$WORK/deb"
  install -d "$DEBROOT/usr/lib/$PACKAGE_NAME" "$DEBROOT/usr/bin" \
              "$DEBROOT/usr/share/applications" "$DEBROOT/usr/share/doc/$PACKAGE_NAME" \
              "$DEBROOT/DEBIAN"

  # The bundle is self-relocatable (RPATH $ORIGIN/lib), so /usr/lib/<name>
  # works anywhere; strip the runner's symbols (the engine and plugins come
  # stripped).
  cp -a "$BUNDLE/." "$DEBROOT/usr/lib/$PACKAGE_NAME/"
  if command -v strip >/dev/null 2>&1; then
    strip --strip-unneeded "$DEBROOT/usr/lib/$PACKAGE_NAME/$BUNDLE_EXECUTABLE" 2>/dev/null || true
  fi

  # A wrapper rather than a symlink: the runner computes its data/lib paths
  # from its own executable location, and a wrapper keeps the command on
  # PATH trivially.
  cat > "$DEBROOT/usr/bin/$PACKAGE_NAME" <<EOF
#!/bin/sh
exec /usr/lib/$PACKAGE_NAME/$BUNDLE_EXECUTABLE "\$@"
EOF
  chmod 755 "$DEBROOT/usr/bin/$PACKAGE_NAME"

  # Wayland matches the desktop-file id to GApplication's application id.
  write_desktop_file "$DEBROOT/usr/share/applications/$LINUX_DESKTOP_FILE" "$PACKAGE_NAME"
  install_icons "$DEBROOT/usr"

  [[ -f "$LICENSE_FILE" ]] \
    || die "LICENSE not found at $LICENSE_FILE — the .deb copyright file embeds it verbatim"
  write_copyright "$DEBROOT/usr/share/doc/$PACKAGE_NAME/copyright"
  write_third_party_notices "$BUNDLE" "$DEBROOT/usr/share/doc/$PACKAGE_NAME/Third-Party-Notices.txt"

  cat > "$DEBROOT/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
# Refresh the desktop/icon caches if the tools exist; a missing tool (or
# cache refresh failing) must never fail the package install.
if [ -x "$(command -v update-desktop-database)" ]; then
  update-desktop-database -q /usr/share/applications || true
fi
if [ -x "$(command -v gtk-update-icon-cache)" ]; then
  gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor || true
fi
EOF
  chmod 755 "$DEBROOT/DEBIAN/postinst"

  local installed_size
  installed_size="$(du -sk "$DEBROOT/usr" | cut -f1)"
  cat > "$DEBROOT/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $DEB_VERSION
Section: $DEB_SECTION
Priority: optional
Architecture: $DEB_ARCH
Installed-Size: $installed_size
Depends: $DEPENDS
Maintainer: $DEB_MAINTAINER
Homepage: $DEB_HOMEPAGE
Description: $DEB_DESCRIPTION
EOF

  local deb_name="${PACKAGE_NAME}_${DEB_VERSION}_${DEB_ARCH}.deb"
  if $have_dpkg; then
    echo "-- dpkg-deb → $deb_name"
    dpkg-deb --root-owner-group --build "$DEBROOT" "$WORK/$deb_name" >/dev/null
  fi

  APPIMAGE_TOOL=""
  mkdir -p "$OUT_DIR"
  if $have_dpkg; then
    mv "$WORK/$deb_name" "$OUT_DIR/"
    echo "✓ $OUT_DIR/$deb_name"
  fi

  if [[ "$APPIMAGE_MODE" != "skip" ]]; then
    if build_appimage; then
      echo "✓ $OUT_DIR/$ASSET_STEM-linux-$FLUTTER_ARCH.AppImage"
    elif [[ "$APPIMAGE_MODE" == "best-effort" ]]; then
      echo "!! package-linux: AppImage build failed (best-effort mode — continuing with the .deb only)" >&2
    else
      die "AppImage build failed"
    fi
  fi
}
