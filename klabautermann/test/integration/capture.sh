#!/usr/bin/env bash
# Container shell and userland captures (03 §6.5, §11.3; 06): runs the
# `capture` command of klabautermann_core/tool/capture_fixtures.dart in
# digest-pinned container images, under each shell an image provides or
# a pinned Debian package adds, and checks every capture against its
# committed fixture in klabautermann_host/test/fixtures/<name>/.
#
#   test/integration/capture.sh            capture, then check the section
#                                          statuses and file names against
#                                          the committed fixtures
#   test/integration/capture.sh --update   capture, replace the committed
#                                          fixtures and regenerate their
#                                          goldens
#   test/integration/capture.sh --list     print the evidence directory and
#                                          the capture list; needs no Docker
#
# Needs Linux on x86_64 (the pinned packages and the fixtures are amd64),
# Docker, curl, sha256sum, realpath and the Dart SDK with the klabautermann
# workspace resolved (`dart pub get` in klabautermann/).
#
# Everything a run writes goes to $KLABAUTERMANN_EVIDENCE_DIR/capture/
# (default klabautermann/build/ci-evidence, made absolute; inside the
# repository it must lie under a build/ directory, which git ignores):
#
#   fixtures/<name>/  the tool's fixture directory for each capture,
#                     redacted and reviewed by the tool, plus a provenance
#                     paragraph in SOURCE.md
#   logs/<name>.log   the tool's output for each capture
#   images.txt        each image's pinned reference, local id and
#                     os-release
#
# The tool only ever writes redacted, reviewed files; the unredacted
# sections never leave the container. Only --update writes inside the
# repository: it replaces klabautermann_host/test/fixtures/<name>/ with
# the evidence copy, removes the `-docker-` fixtures no longer listed,
# then runs the existing golden regeneration (klabautermann_host's
# tool/regen_goldens.dart and klabautermann_core's KLAB_REGEN_GOLDENS=1
# pipeline test). Review the diff before committing.
#
# How a capture runs: the tool, compiled ahead of time, captures the
# machine it runs on (local mode), so each capture gets a fresh container
# whose PID 1 is `sleep infinity`. The tool is copied in with docker cp,
# run as root with docker exec, and its fixture copied out again. Nothing
# is mounted, so the `fs` collector sees the image's own mounts. The
# container keeps Docker's default network, which it does not use, so
# that `netdev` lists an interface besides lo; nothing is published.
#
# Debian 13 also runs BusyBox ash, mksh and zsh as `sh -s`, and zsh, fish
# and tcsh as login shells (03 §6.6, spike S2), from Debian packages
# pinned by SHA-256 on snapshot.debian.org. They are unpacked with
# dpkg-deb before the capture: no maintainer scripts and no network in
# the container. Shells that neither an image nor those packages provide
# stay on the manual checklist (06).
set -euo pipefail

klab_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
readonly klab_dir
repo_dir="$(cd "$klab_dir/.." && pwd)"
readonly repo_dir
readonly fixtures_root="$klab_dir/packages/klabautermann_host/test/fixtures"

# Bounds one capture; the tool's own reply timeout is 5 minutes.
readonly capture_timeout_seconds=300
readonly pull_attempts=3
readonly capture_hostname='capture-host'

# Official images through Google's Docker Hub mirror (Docker Hub
# rate-limits anonymous pulls), Fedora from quay.io and UBI from Red
# Hat's registry. The tag only documents the pin; Docker pulls by digest.
declare -rA images=(
  [debian-12]='mirror.gcr.io/library/debian:12@sha256:2c037a04925515fdd6ea85ea14a682d0e79931f5e9f5d07b6dbfc6ba12f9e858'
  [debian-13]='mirror.gcr.io/library/debian:13@sha256:913f6706df59a68922d1dd08f78c2476560a8d367897200a6005b00e5f67c2d5'
  [ubuntu-2204]='mirror.gcr.io/library/ubuntu:22.04@sha256:5ec03bb3441e8b0bf3b4f9cd4629a1ae763010dc3035bb8da3ae6cf026486401'
  [ubuntu-2604]='mirror.gcr.io/library/ubuntu:26.04@sha256:f144425ff09be612d6d9ad965196e9cdc23dae1f42110a8a11a3e9a8198759f7'
  [ubi-9]='registry.access.redhat.com/ubi9/ubi:9.8@sha256:16e9e43d99e181463513cc84a514859b1abb9460f1c4d9e208da4b4e51cd5cc3'
  [ubi-10]='registry.access.redhat.com/ubi10/ubi:10.2@sha256:a75ad754aa048d808dd3260243452f8c9a665831d0493b4c9d92f0c88fe2f8c3'
  [fedora-44]='quay.io/fedora/fedora:44@sha256:74e857c33dfb387710b2b1a0203824351a25e9844356af2d1e5792ca2a96129b'
  [arch]='mirror.gcr.io/library/archlinux:base-20261011.0.609700@sha256:3c64b538588416593f69a1aebd2f2ec0f2541b29159f32556fa7def2167147a0'
)

# Debian 13 (trixie) packages: pool path and SHA-256. The snapshot keeps
# every file it ever served, so the pins stay downloadable.
readonly deb_snapshot='https://snapshot.debian.org/archive/debian/20261015T000000Z'
declare -rA debs=(
  [busybox]='pool/main/b/busybox/busybox_1.37.0-6+b9_amd64.deb b88c3b899e16bf64347d63235128df9efbcf1f964e4841bc9b37d7856bed35bf'
  [mksh]='pool/main/m/mksh/mksh_59c-41+b2_amd64.deb e0613580ce0bb50bce40089eede49283e7a4a42ce753b99a665b40cb05dbe7c4'
  [zsh-common]='pool/main/z/zsh/zsh-common_5.9-8_all.deb 400c958c7fdb66a945cad32c0edc81cedcfface0059b5e2beb46097a457099bd'
  [zsh]='pool/main/z/zsh/zsh_5.9-8+b24_amd64.deb 69791a2e667258a54449cfa01ad0d8d198a4c6e27f02f21c864d0545efe18966'
  [tcsh]='pool/main/t/tcsh/tcsh_6.24.13-2_amd64.deb 30234574fb7fa86cd25c28ae990f34b1109deccdbc78ccf477543dd48e79cb91'
  [fish-common]='pool/main/f/fish/fish-common_4.0.2-1_all.deb eaeaf43cd391711060db323af1fd98bd5b61589b6c15ab27fbd14d06067e5924'
  [fish]='pool/main/f/fish/fish_4.0.2-1_amd64.deb 56136a4d9bee8e8cc4fc7ae43d54c82b7eb49e4f24bb1853aad92659490b3a20'
  [libpcre2-32-0]='pool/main/p/pcre2/libpcre2-32-0_10.46-1~deb13u2_amd64.deb e481279c1665e03a41bba6eb776baf8d4d78cd20b7906a7fc1591ad92ace94f4'
)

# One capture per line: the fixture directory, the image, the launch
# (`sh`: the program on `<shell> -s` through a link named sh; `login`:
# `<shell> -c '<start command>'` as sshd runs it, which then execs the
# image's sh), the shell, and the Debian packages to unpack first. Each
# image runs its own /bin/sh, and bash where that is dash. The fixture
# name is the probe's platform id (UBI reports rhel; Arch is rolling),
# `docker`, then the shell.
readonly captures=(
  'debian-12-docker-dash        debian-12    sh     dash'
  'debian-12-docker-bash        debian-12    sh     bash'
  'debian-13-docker-dash        debian-13    sh     dash'
  'debian-13-docker-bash        debian-13    sh     bash'
  'debian-13-docker-busybox     debian-13    sh     busybox  busybox'
  'debian-13-docker-mksh        debian-13    sh     mksh     mksh'
  'debian-13-docker-zsh         debian-13    sh     zsh      zsh-common zsh'
  'debian-13-docker-login-bash  debian-13    login  bash'
  'debian-13-docker-login-zsh   debian-13    login  zsh      zsh-common zsh'
  'debian-13-docker-login-fish  debian-13    login  fish     fish-common fish libpcre2-32-0'
  'debian-13-docker-login-tcsh  debian-13    login  tcsh     tcsh'
  'ubuntu-2204-docker-dash      ubuntu-2204  sh     dash'
  'ubuntu-2204-docker-bash      ubuntu-2204  sh     bash'
  'ubuntu-2604-docker-dash      ubuntu-2604  sh     dash'
  'ubuntu-2604-docker-bash      ubuntu-2604  sh     bash'
  'rhel-9-docker-bash           ubi-9        sh     bash'
  'rhel-10-docker-bash          ubi-10       sh     bash'
  'fedora-44-docker-bash        fedora-44    sh     bash'
  'arch-docker-bash             arch         sh     bash'
)

usage() {
  echo 'usage: capture.sh [--update | --list]' >&2
  exit 2
}

die() {
  echo "capture.sh: $*" >&2
  exit 1
}

mode=check
case "${1:-}" in
  '') ;;
  --update) mode=update ;;
  --list) mode=list ;;
  *) usage ;;
esac
[[ "$#" -le 1 ]] || usage

# realpath -m resolves a relative path against the working directory
# without creating it, so --list stays free of side effects.
evidence_root="$(realpath -m -- "${KLABAUTERMANN_EVIDENCE_DIR:-$klab_dir/build/ci-evidence}")"
readonly evidence_root
case "$evidence_root/" in
  "$repo_dir"/*)
    [[ "/${evidence_root#"$repo_dir"/}/" == */build/* ]] ||
      die "$evidence_root is inside the repository but not under a build/ directory"
    ;;
esac
readonly evidence="$evidence_root/capture"

if [[ "$mode" == list ]]; then
  echo "evidence $evidence"
  for entry in "${captures[@]}"; do
    read -r name image launch shell packages <<<"$entry"
    echo "capture $name ${images[$image]} $launch $shell${packages:+ $packages}"
  done
  exit 0
fi

[[ "$(uname -s)" == Linux && "$(uname -m)" == x86_64 ]] ||
  die 'needs Linux on x86_64'
for tool in docker curl sha256sum dart timeout; do
  command -v "$tool" >/dev/null || die "$tool is not on PATH"
done
docker info >/dev/null 2>&1 || die 'cannot reach the Docker daemon'

# Every container of this run carries the label, so the teardown finds
# one even when the script stopped between creating it and recording it.
run_label="klabautermann.capture=$$-$(date +%s)"
readonly run_label
work=''

teardown() {
  local status="$?"
  trap - EXIT INT TERM
  local ids
  ids="$(docker ps -aq --filter "label=$run_label" 2>/dev/null)" || ids=''
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086 # one id per word
    docker rm -f $ids >/dev/null 2>&1 || true
  fi
  if [[ -n "$work" ]]; then
    rm -rf -- "$work"
  fi
  exit "$status"
}
trap teardown EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

work="$(mktemp -d "${TMPDIR:-/tmp}/klab-capture.XXXXXX")"
rm -rf -- "$evidence"
mkdir -p "$evidence/fixtures" "$evidence/logs" "$work/stage/out" "$work/debs"

echo '== Compiling the capture tool'
(
  cd "$klab_dir/packages/klabautermann_core"
  dart compile exe --verbosity=warning tool/capture_fixtures.dart \
    -o "$work/stage/capture_fixtures"
)

echo '== Fetching the pinned Debian packages'
for package in "${!debs[@]}"; do
  read -r pool sha <<<"${debs[$package]}"
  curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
    -o "$work/debs/$package.deb" "$deb_snapshot/$pool"
  echo "$sha  $work/debs/$package.deb" | sha256sum --check --quiet ||
    die "$package: the download does not match its pinned SHA-256"
done

echo '== Pulling the images'
for key in "${!images[@]}"; do
  ref="${images[$key]}"
  for ((attempt = 1; ; attempt++)); do
    docker pull --quiet "$ref" >/dev/null && break
    ((attempt < pull_attempts)) || die "cannot pull $ref"
    sleep $((attempt * 10))
  done
done
for key in $(printf '%s\n' "${!images[@]}" | sort); do
  ref="${images[$key]}"
  {
    echo "== $key $ref"
    docker image inspect --format '{{.Id}} {{.Os}}/{{.Architecture}}' "$ref"
    docker run --rm --label "$run_label" --network none --entrypoint cat \
      "$ref" /etc/os-release
  } >>"$evidence/images.txt"
done

# The provenance paragraph appended to a capture's SOURCE.md: the image
# and the Debian packages unpacked into it ($@).
# shellcheck disable=SC2016 # Markdown code spans, not expansions
provenance() {
  local image="$1" package pool list=''
  shift
  printf '\nContainer capture: `klabautermann/test/integration/capture.sh` ran\n'
  printf 'the tool as root in a fresh container of\n`%s`,\n' "${images[$image]}"
  printf 'whose PID 1 is `sleep infinity`.\n'
  [[ "$#" -gt 0 ]] || return 0
  for package in "$@"; do
    read -r pool _ <<<"${debs[$package]}"
    list+="${list:+, }\`${pool##*/}\`"
  done
  printf 'The shell comes from Debian packages unpacked into it first, from\n'
  printf '%s:\n%s.\n' "$deb_snapshot" "$list"
}

# Runs one capture into $evidence/fixtures/<name>/ in a fresh container,
# which it removes again.
capture_one() {
  local cid status=0
  cid="$(docker create --label "$run_label" --hostname "$capture_hostname" \
    "${images[$2]}" sleep infinity)" || return 1
  capture_in "$cid" "$@" || status=1
  docker rm -f "$cid" >/dev/null || status=1
  return "$status"
}

# Called in a condition, where errexit is off, so every step checks its
# own status.
capture_in() {
  local cid="$1" name="$2" image="$3" launch="$4" shell="$5"
  shift 5
  local log="$evidence/logs/$name.log" package flag=--sh

  docker cp "$work/stage/." "$cid:/opt/klab" || return 1
  for package in "$@"; do
    docker cp "$work/debs/$package.deb" "$cid:/opt/klab/$package.deb" ||
      return 1
  done
  docker start "$cid" >/dev/null || return 1
  for package in "$@"; do
    docker exec "$cid" dpkg-deb --extract "/opt/klab/$package.deb" / || return 1
    docker exec "$cid" rm "/opt/klab/$package.deb" || return 1
  done
  if [[ "$#" -gt 0 ]]; then
    docker exec "$cid" ldconfig || return 1
  fi

  [[ "$launch" == login ]] && flag=--login-shell
  if ! timeout "$capture_timeout_seconds" docker exec "$cid" \
    /opt/klab/capture_fixtures capture --out /opt/klab/out \
    --platform "$name" "$flag" "$shell" >"$log" 2>&1; then
    sed 's/^/    /' "$log" >&2
    return 1
  fi
  docker cp "$cid:/opt/klab/out/$name" "$evidence/fixtures/$name" ||
    return 1
  provenance "$image" "$@" >>"$evidence/fixtures/$name/SOURCE.md"
}

# What a later capture must reproduce: the file names and SOURCE.md's
# section statuses and probe areas. Counters, process lists and dates
# change with every run.
shape() {
  local dir="$1"
  (cd "$dir" && find . -maxdepth 1 -type f ! -name '*.golden.json' | sort)
  # shellcheck disable=SC2016 # Markdown code spans, not expansions
  grep -E '^\| `[a-z_]+` \||^Probe areas: ' "$dir/SOURCE.md"
}

failed=()
names=()
for entry in "${captures[@]}"; do
  read -r name image launch shell packages <<<"$entry"
  names+=("$name")
  echo "== $name: $launch $shell in $image"
  # shellcheck disable=SC2086 # packages: one name per word
  if ! capture_one "$name" "$image" "$launch" "$shell" ${packages:-}; then
    echo "!! $name: capture failed (log: $evidence/logs/$name.log)" >&2
    failed+=("$name")
    continue
  fi

  [[ "$mode" == check ]] || continue
  committed="$fixtures_root/$name"
  if [[ ! -d "$committed" ]]; then
    echo "!! $name: no committed fixture; run capture.sh --update" >&2
    failed+=("$name")
  elif ! diff -u --label "committed $name" --label "captured $name" \
    <(shape "$committed") <(shape "$evidence/fixtures/$name") >&2; then
    echo "!! $name: the capture differs from the committed fixture" >&2
    failed+=("$name")
  fi
done

if [[ "${#failed[@]}" -gt 0 ]]; then
  die "${#failed[@]} of ${#captures[@]} captures failed or differ: ${failed[*]}"
fi

if [[ "$mode" == update ]]; then
  echo '== Replacing the committed fixtures'
  for dir in "$fixtures_root"/*-docker-*/; do
    stale="$(basename "$dir")"
    [[ -d "$dir" && " ${names[*]} " != *" $stale "* ]] || continue
    echo "removing $stale, which capture.sh no longer lists"
    rm -rf -- "${fixtures_root:?}/$stale"
  done
  for name in "${names[@]}"; do
    rm -rf -- "${fixtures_root:?}/$name"
    cp -R -- "$evidence/fixtures/$name" "$fixtures_root/$name"
  done
  (cd "$klab_dir/packages/klabautermann_host" && dart run tool/regen_goldens.dart)
  (
    cd "$klab_dir/packages/klabautermann_core"
    KLAB_REGEN_GOLDENS=1 dart test test/sampling/sample_pipeline_fixtures_test.dart
  )
fi

echo "== ${#captures[@]} captures in $evidence"
