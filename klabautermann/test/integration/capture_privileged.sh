# shellcheck shell=bash
# Spike S6's privileged-file recipes in containers (03 §5.11, §8.5; M5
# plan M01), sourced by capture.sh, which owns the modes, the evidence
# directory, the labels and the teardown, and runs it only for
# --privileged-files-only. Defining things here runs nothing.
#
# Each case is a fresh container of a digest-pinned image with no
# network and nothing published: Debian 13's GNU coreutils with the
# pinned acl and attr packages unpacked (dpkg-deb, no maintainer
# scripts), Alpine's BusyBox as the image ships it, and UBI 9's
# coreutils, whose image carries the acl and attr tools. A non-root
# account `klab` is made for the ACL entry, then privileged_recipes.sh
# runs as root (`sh -s`, umask 022) in an empty directory and its output goes to
# $evidence/privileged/<case>.txt, after a line naming the image.
#
# The recipes and their output are deterministic, so check mode compares
# each case with the committed copy in klabautermann/docs/evidence/s6/
# byte for byte; --update replaces it. The same recipes run on the
# runner VM through the elevation prelude (runner_vm_s6_test.dart).
#
# Not part of capture.sh's default run, as with the elevation matrix: a
# spike's evidence need not be re-proven on every pull request.

# capture.sh defines klab_dir, evidence, work, images, deb_snapshot,
# run_label, mode, pull_attempts and die, and capture_elevation.sh
# elev_alpine_image, before it calls anything here.
# shellcheck disable=SC2154
readonly priv_committed="$klab_dir/docs/evidence/s6"
readonly priv_recipes="$klab_dir/test/integration/privileged_recipes.sh"

readonly priv_reader='klab'
readonly priv_dir='/srv/klabautermann-s6'

# Debian 13 packages the GNU case adds: pool path and SHA-256, from
# capture.sh's snapshot. libacl1 and libattr1 of the same versions are
# in the image.
declare -rA priv_debs=(
  [acl]='pool/main/a/acl/acl_2.3.2-2+b1_amd64.deb fa89b05576c590211c8e8965761fc76b830e3eeb3dd100ac59c8440f11ea18fd'
  [attr]='pool/main/a/attr/attr_2.5.2-3_amd64.deb f2eac7412d2df3e36ccea2db110e2fc529a473ce3e348a35ca9c9a521a6bdfb8'
)

# One case per line: its name, the image (a capture.sh image key, or
# alpine) and the Debian packages to unpack first.
readonly priv_cases=(
  'debian-13-coreutils  debian-13  acl attr'
  'alpine-322-busybox   alpine'
  'rhel-9-coreutils     ubi-9'
)

# Prints the case list for --list.
priv_list() {
  local entry name image packages
  for entry in "${priv_cases[@]}"; do
    read -r name image packages <<<"$entry"
    echo "privileged $name $(priv_image "$image")${packages:+ $packages}"
  done
}

priv_image() {
  if [[ "$1" == alpine ]]; then
    echo "$elev_alpine_image"
  else
    echo "${images[$1]}"
  fi
}

# Fetches and checks the packages, pulls Alpine.
priv_prepare() {
  local package pool sha attempt
  mkdir -p "$evidence/privileged" "$work/priv-debs"
  for package in "${!priv_debs[@]}"; do
    read -r pool sha <<<"${priv_debs[$package]}"
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
      -o "$work/priv-debs/$package.deb" "$deb_snapshot/$pool"
    echo "$sha  $work/priv-debs/$package.deb" | sha256sum --check --quiet ||
      die "$package: the download does not match its pinned SHA-256"
  done
  for ((attempt = 1; ; attempt++)); do
    docker pull --quiet "$elev_alpine_image" >/dev/null && break
    ((attempt < pull_attempts)) || die "cannot pull $elev_alpine_image"
    sleep $((attempt * 10))
  done
}

# Runs one case into $evidence/privileged/<case>.txt in a fresh
# container, which it removes again.
priv_case_one() {
  local cid status=0
  cid="$(docker create --label "$run_label" --network none \
    "$(priv_image "$2")" sleep infinity)" || return 1
  priv_case_in "$cid" "$@" || status=1
  docker rm -f "$cid" >/dev/null || status=1
  return "$status"
}

# Called in a condition, where errexit is off, so every step checks its
# own status.
priv_case_in() {
  local cid="$1" name="$2" image="$3"
  shift 3
  local log="$evidence/logs/privileged-$name.log" package

  docker start "$cid" >/dev/null || return 1
  for package in "$@"; do
    docker cp "$work/priv-debs/$package.deb" "$cid:/tmp/$package.deb" ||
      return 1
    docker exec "$cid" dpkg-deb --extract "/tmp/$package.deb" / || return 1
  done
  if [[ "$image" == alpine ]]; then
    docker exec "$cid" adduser -D "$priv_reader" || return 1
  else
    docker exec "$cid" useradd "$priv_reader" || return 1
  fi
  docker exec "$cid" mkdir -m 0755 "$priv_dir" || return 1

  {
    echo "# privileged_recipes.sh as root in $(priv_image "$image")${1:+, with ${*}}"
    # A login session's umask, as sshd gives it, rather than whatever
    # the daemon's exec sessions get, so every daemon records the same.
    # shellcheck disable=SC2016 # expanded by the container's sh
    docker exec -i "$cid" sh -c 'umask 022 && exec sh -s -- "$@"' sh \
      "$priv_dir" "$priv_reader" <"$priv_recipes" 2>"$log"
  } >"$evidence/privileged/$name.txt" || {
    sed 's/^/    /' "$log" >&2
    return 1
  }
}

# Runs every case, adding the names of failed or (in check mode)
# differing ones to the caller's `failed` array.
priv_captures() {
  local entry name image packages
  for entry in "${priv_cases[@]}"; do
    read -r name image packages <<<"$entry"
    echo "== $name in $(priv_image "$image")"
    # shellcheck disable=SC2086 # packages: one name per word
    if ! priv_case_one "$name" "$image" ${packages:-}; then
      echo "!! $name: case failed (log: $evidence/logs/privileged-$name.log)" >&2
      failed+=("$name")
      continue
    fi
    [[ "$mode" == check ]] || continue
    if [[ ! -f "$priv_committed/$name.txt" ]]; then
      echo "!! $name: no committed evidence; run capture.sh --privileged-files-only --update" >&2
      failed+=("$name")
    elif ! diff -u --label "committed $name" --label "captured $name" \
      "$priv_committed/$name.txt" "$evidence/privileged/$name.txt" >&2; then
      echo "!! $name: the recipes differ from the committed evidence" >&2
      failed+=("$name")
    fi
  done
}

# --update: replaces the committed case files, keeping the README and
# the runner VM's evidence.
priv_update() {
  local entry name
  mkdir -p "$priv_committed"
  for entry in "${priv_cases[@]}"; do
    read -r name _ <<<"$entry"
    cp -- "$evidence/privileged/$name.txt" "$priv_committed/"
  done
}
