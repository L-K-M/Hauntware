#!/usr/bin/env bash
# Rebuilds fonts/IosevkaTerm or fonts/IoskeleyMonoTerm from the upstream
# release.
#
# Iosevka's full character set costs about 8.4 MB per style; the terminal
# needs a fraction of it. This keeps the scripts, symbols and drawing
# characters a terminal shows and the default ligatures (calt), and drops
# the character-variant and stylistic-set glyphs nothing selects:
# about 480 KB per style. Characters left out fall back to the next
# family in the app's stack. Ioskeley Mono is an Iosevka build, so the
# same cut fits it.
#
# Needs curl, python3, sha256sum or shasum, and pyftsubset from fonttools 4.67.0
# (for example: uv tool install fonttools==4.67.0).
#
# Usage: tool/subset_iosevka.sh iosevka-term|ioskeley-mono-term [path/to/release.zip]
set -euo pipefail

# Each family's pinned release, where its styles sit in the archive, and
# the file name stem the archive and fonts/ share.
case "${1:-}" in
  iosevka-term)
    readonly version=34.9.0
    readonly archive_name="PkgTTF-Unhinted-IosevkaTerm-${version}.zip"
    readonly archive_sha256=b11472aab68b01d5936758962af8da5902ebbb7f8311303236f5e1023a4bee45
    readonly url="https://github.com/be5invis/Iosevka/releases/download/v${version}/${archive_name}"
    readonly member_dir=''
    readonly stem=IosevkaTerm
    ;;
  ioskeley-mono-term)
    readonly version=2.1.0
    readonly archive_name=IoskeleyMono-Term.zip
    readonly archive_sha256=a45f766d60fb7f1ed244ecd456a890d68cad8bd480f7803325d04133995bc000
    readonly url="https://github.com/ahatem/IoskeleyMono/releases/download/v${version}/${archive_name}"
    readonly member_dir=Normal/Unhinted/
    readonly stem=IoskeleyMonoTerm
    ;;
  *)
    echo "Usage: $0 iosevka-term|ioskeley-mono-term [path/to/release.zip]" >&2
    exit 2
    ;;
esac
readonly styles=(Regular Bold Italic BoldItalic)

# What a terminal draws, by block:
readonly unicodes=(
  U+0020-007E # Basic Latin
  U+00A0-024F # Latin-1, Latin Extended-A and -B
  U+0250-036F # IPA, spacing modifiers, combining diacritics
  U+0370-03FF # Greek
  U+0400-052F # Cyrillic and its supplement
  U+1E00-1EFF # Latin Extended Additional
  U+2000-206F # General Punctuation
  U+2070-209F # Superscripts and subscripts
  U+20A0-20CF # Currency
  U+2100-218F # Letterlike symbols, number forms
  U+2190-23FF # Arrows, math operators, technical (⌘ ⏎)
  U+2400-243F # Control pictures
  U+2460-24FF # Enclosed alphanumerics
  U+2500-25FF # Box drawing, blocks, geometric shapes
  U+2600-27BF # Miscellaneous symbols, dingbats (✓ ✗)
  U+27C0-27FF # Math symbols, supplemental arrows
  U+2800-28FF # Braille (terminal graphs)
  U+2900-2BFF # More arrows and math, miscellaneous symbols
  U+E0A0-E0D7 # Powerline
  U+FFFD      # Replacement character
  U+1FB00-1FBFF # Legacy computing (sextants)
)

# HarfBuzz's default features plus the marks: ligatures are calt.
readonly features=calt,ccmp,locl,mark,mkmk,kern,liga,rlig,clig

out="$(cd "$(dirname "$0")/.." && pwd)/fonts/$stem"
mkdir -p "$out"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

archive="${2:-}"
if [[ -z "$archive" ]]; then
  archive="$work/$archive_name"
  curl --fail --location --silent --show-error --output "$archive" "$url"
fi
# sha256sum is GNU coreutils; macOS has shasum instead.
if command -v sha256sum >/dev/null; then
  echo "$archive_sha256  $archive" | sha256sum --check --quiet
else
  echo "$archive_sha256  $archive" | shasum -a 256 --check --status
fi

ranges="$(IFS=,; echo "${unicodes[*]}")"
for style in "${styles[@]}"; do
  file="${stem}-${style}.ttf"
  python3 -I -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract(sys.argv[2], sys.argv[3])' \
    "$archive" "$member_dir$file" "$work"
  pyftsubset "$work/$member_dir$file" \
    --unicodes="$ranges" \
    --layout-features="$features" \
    --name-IDs='*' --name-languages='*' --name-legacy \
    --notdef-outline \
    --output-file="$out/$file"
done
