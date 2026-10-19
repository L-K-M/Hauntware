# shellcheck shell=bash
# Spike S3's elevation matrix (03 §8.3; 06's spike table; M4 plan E01),
# sourced by capture.sh, which owns the modes, the evidence directory,
# the labels and the teardown, and runs it only for --elevation-only.
# Defining things here runs nothing.
#
# Each case is a fresh container of a digest-pinned image with no
# network and nothing published:
#
#   1. The pinned packages are copied in and unpacked: sudo with
#      dpkg-deb (no maintainer scripts, so the sudoers mode and sudo-rs's
#      `sudo` link are set by hand, as the scripts would), doas with
#      `apk add --no-network`.
#   2. A non-root account `klab` gets a password made for the case and
#      fed to chpasswd on stdin, and the case's sudoers or doas rule.
#   3. klabautermann_core's tool/capture_elevation.dart, compiled ahead
#      of time and run on the host, probes the account as the engine
#      does and drives seance_core's ElevatedExecutor (the D24 prelude,
#      the rung-4 retry and the refusal classifier) through `docker exec`
#      as klab, in a new session without a tty. It writes
#      $evidence/elevation/<case>.json: every command, its exit status,
#      stdout and full stderr, and never the password.
#
# A last container records `command -V printf` under dash, bash, BusyBox
# ash, mksh and zsh (the prelude's rung needs a builtin printf) in
# $evidence/elevation/printf-builtin.txt.
#
# Check mode compares each case with the committed copy in
# klabautermann/docs/evidence/s3/ by outcome (ran or refused, the refusal
# kind, the exit status, the commands taken) and the probe facts; stderr
# texts are evidence for E04, not compared. --update replaces the
# committed copy.
#
# Not part of capture.sh's default run, which CI makes on every
# Klabautermann integration change: Alpine's mirror keeps only the
# current revision of a package, so the doas pin can disappear, and a
# spike's evidence need not be re-proven on every pull request.

# capture.sh defines klab_dir, evidence, work, images, debs, deb_snapshot,
# run_label, mode, pull_attempts and die before it calls anything here.
# shellcheck disable=SC2154
readonly elev_committed="$klab_dir/docs/evidence/s3"

readonly elev_user='klab'
# A name the container's /etc/hosts resolves: without one, sudo warns
# "unable to resolve host" on every run, which a real host does not.
readonly elev_hostname='elevation-host'
readonly elev_alpine_image='mirror.gcr.io/library/alpine:3.22@sha256:5291449c3df73caf6ed85e649dec1b9e818b39a5d8c871e97afc13e9cd5e8fa8'

# The packages each tool needs beyond its image: a source URL relative to
# its archive and the SHA-256. Debian's from capture.sh's snapshot,
# Ubuntu 26.04's from Ubuntu's snapshot of the same day, Alpine's from
# its mirror.
readonly elev_ubuntu_snapshot='https://snapshot.ubuntu.com/ubuntu/20261015T000000Z'
readonly elev_alpine_mirror='https://dl-cdn.alpinelinux.org/alpine/v3.22/main/x86_64'
declare -rA elev_packages=(
  [sudo]='debian pool/main/s/sudo/sudo_1.9.16p2-3+deb13u2_amd64.deb 4f926f8f0704575158a90135713977f98f7d50d185969d9a8a405cdce5e3e50c'
  [libapparmor1]='debian pool/main/a/apparmor/libapparmor1_4.1.0-1_amd64.deb 4158976c77038b93021967f425b4cc505df18c4f5e3f444732399e7ed4af4419'
  [sudo-rs]='ubuntu pool/main/r/rust-sudo-rs/sudo-rs_0.2.13-0ubuntu1_amd64.deb c346b4e766578fc82af855616570b308850c5531a9f41a3247141875727ae391'
  [sudo-common]='ubuntu pool/main/s/sudo-common/sudo-common_1.2ubuntu_all.deb ba909e8e796115f442d0915ed3baa1b752e8809ec4d8e723d2bbd0d177750d2c'
  [doas]='alpine doas-6.8.2-r8.apk fcd959f0e02a43e8410d5761c9e3a945ed074f07a18e3a5ff7bcfe6ddfb7e3c5'
)

# One case per line: its name, the image (a capture.sh image key, or
# alpine), the tool and the rule variant (elev_rule).
readonly elev_cases=(
  'debian-13-sudo-tty             debian-13    sudo     tty'
  'debian-13-sudo-ppid            debian-13    sudo     ppid'
  'debian-13-sudo-global          debian-13    sudo     global'
  'debian-13-sudo-timeout-0       debian-13    sudo     timeout-0'
  'debian-13-sudo-requiretty      debian-13    sudo     requiretty'
  'ubuntu-2604-sudo-rs            ubuntu-2604  sudo-rs  default'
  'ubuntu-2604-sudo-rs-timeout-0  ubuntu-2604  sudo-rs  timeout-0'
  'alpine-322-doas-nopass         alpine       doas     nopass'
  'alpine-322-doas-password       alpine       doas     password'
)

# The shells whose printf the last container asks about, as each is
# started: `<shell...> -c 'command -V printf'`.
readonly elev_printf_shells=('dash' 'bash' 'busybox ash' 'mksh' 'zsh')

# Prints the case list for --list.
elev_list() {
  local entry name image tool variant
  for entry in "${elev_cases[@]}"; do
    read -r name image tool variant <<<"$entry"
    echo "elevation $name $(elev_image "$image") $tool $variant"
  done
}

elev_image() {
  if [[ "$1" == alpine ]]; then
    echo "$elev_alpine_image"
  else
    echo "${images[$1]}"
  fi
}

# The rule lines of a case: a sudoers drop-in or a doas.conf.
elev_rule() {
  local tool="$1" variant="$2"
  if [[ "$tool" == doas ]]; then
    case "$variant" in
      nopass) echo "permit nopass $elev_user as root" ;;
      password) echo "permit $elev_user as root" ;;
    esac
    return 0
  fi
  case "$variant" in
    tty | ppid | global) echo "Defaults timestamp_type=$variant" ;;
    timeout-0) echo 'Defaults timestamp_timeout=0' ;;
    requiretty) echo 'Defaults requiretty' ;;
    default) ;;
  esac
  echo "$elev_user ALL=(ALL) ALL"
}

# Compiles the tool, fetches and checks the packages, pulls Alpine.
elev_prepare() {
  local package archive path sha url attempt
  mkdir -p "$evidence/elevation" "$work/elev-stage" "$work/elev-packages"
  (
    cd "$klab_dir/packages/klabautermann_core" || exit
    dart compile exe --verbosity=warning tool/capture_elevation.dart \
      -o "$work/elev-stage/capture_elevation"
  )
  for package in "${!elev_packages[@]}"; do
    read -r archive path sha <<<"${elev_packages[$package]}"
    case "$archive" in
      debian) url="$deb_snapshot/$path" ;;
      ubuntu) url="$elev_ubuntu_snapshot/$path" ;;
      alpine) url="$elev_alpine_mirror/$path" ;;
    esac
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
      -o "$work/elev-packages/$package.${path##*.}" "$url"
    echo "$sha  $work/elev-packages/$package.${path##*.}" |
      sha256sum --check --quiet ||
      die "$package: the download does not match its pinned SHA-256"
  done
  for package in busybox mksh zsh-common zsh; do
    read -r path sha <<<"${debs[$package]}"
    curl -fsSL --retry 5 --retry-all-errors --connect-timeout 30 \
      -o "$work/elev-packages/$package.deb" "$deb_snapshot/$path"
    echo "$sha  $work/elev-packages/$package.deb" | sha256sum --check --quiet ||
      die "$package: the download does not match its pinned SHA-256"
  done
  for ((attempt = 1; ; attempt++)); do
    docker pull --quiet "$elev_alpine_image" >/dev/null && break
    ((attempt < pull_attempts)) || die "cannot pull $elev_alpine_image"
    sleep $((attempt * 10))
  done
}

# Runs one case into $evidence/elevation/<case>.json in a fresh
# container, which it removes again.
elev_case_one() {
  local cid status=0
  cid="$(docker create --label "$run_label" --network none \
    --hostname "$elev_hostname" --add-host "$elev_hostname:127.0.0.1" \
    "$(elev_image "$2")" sleep infinity)" || return 1
  elev_case_in "$cid" "$@" || status=1
  docker rm -f "$cid" >/dev/null || status=1
  return "$status"
}

# Called in a condition, where errexit is off, so every step checks its
# own status.
elev_case_in() {
  local cid="$1" name="$2" image="$3" tool="$4" variant="$5"
  local log="$evidence/logs/elevation-$name.log" package password
  local secret="$work/elev-$name.password"

  docker start "$cid" >/dev/null || return 1
  docker exec "$cid" mkdir -p /opt/klab || return 1
  case "$tool" in
    sudo) set -- sudo libapparmor1 ;;
    sudo-rs) set -- sudo-rs sudo-common ;;
    doas) set -- doas ;;
  esac
  for package in "$@"; do
    docker cp "$work/elev-packages/$package".* "$cid:/opt/klab/" || return 1
  done
  if [[ "$tool" == doas ]]; then
    docker exec "$cid" apk add --quiet --no-network /opt/klab/doas.apk ||
      return 1
    docker exec "$cid" adduser -D -s /bin/sh "$elev_user" || return 1
  else
    for package in "$@"; do
      docker exec "$cid" dpkg-deb --extract "/opt/klab/$package.deb" / ||
        return 1
    done
    docker exec "$cid" ldconfig || return 1
    # What sudo's and sudo-rs's maintainer scripts would do.
    docker exec "$cid" chmod 0440 /etc/sudoers || return 1
    if [[ "$tool" == sudo-rs ]]; then
      docker exec "$cid" ln -s ../lib/cargo/bin/sudo /usr/bin/sudo || return 1
    fi
    docker exec "$cid" useradd --create-home --shell /bin/sh "$elev_user" ||
      return 1
  fi
  docker exec "$cid" rm -rf /opt/klab || return 1

  # printf is a builtin, so the password is in no process's argv; it
  # stays in a 0600 file of the run's work directory for the tool.
  password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
  [[ "$password" =~ ^[0-9a-f]{48}$ ]] || return 1
  (umask 077 && printf '%s\n' "$password" >"$secret") || return 1
  printf '%s:%s\n' "$elev_user" "$password" |
    docker exec -i "$cid" chpasswd >/dev/null 2>&1 || return 1
  password=''

  if [[ "$tool" == doas ]]; then
    elev_rule "$tool" "$variant" | docker exec -i "$cid" sh -c \
      'cat >/etc/doas.d/klab.conf && chmod 0400 /etc/doas.d/klab.conf' ||
      return 1
  else
    elev_rule "$tool" "$variant" | docker exec -i "$cid" sh -c \
      'cat >/etc/sudoers.d/klab && chmod 0440 /etc/sudoers.d/klab' ||
      return 1
  fi

  if ! timeout 300 "$work/elev-stage/capture_elevation" run \
    --container "$cid" --user "$elev_user" --case "$name" \
    --description "$tool in $(elev_image "$image"), rule: $(elev_rule "$tool" "$variant" | paste -sd ';' -)" \
    --password-file "$secret" --out "$evidence/elevation/$name.json" \
    >"$log" 2>&1; then
    rm -f -- "$secret"
    sed 's/^/    /' "$log" >&2
    return 1
  fi
  rm -f -- "$secret"
}

# Records `command -V printf` under each shell into printf-builtin.txt.
elev_printf() {
  local cid status=0
  cid="$(docker create --label "$run_label" --network none \
    "${images[debian-13]}" sleep infinity)" || return 1
  elev_printf_in "$cid" || status=1
  docker rm -f "$cid" >/dev/null || status=1
  return "$status"
}

elev_printf_in() {
  local cid="$1" package shell out
  docker start "$cid" >/dev/null || return 1
  docker exec "$cid" mkdir -p /opt/klab || return 1
  for package in busybox mksh zsh-common zsh; do
    docker cp "$work/elev-packages/$package.deb" "$cid:/opt/klab/" ||
      return 1
    docker exec "$cid" dpkg-deb --extract "/opt/klab/$package.deb" / ||
      return 1
  done
  docker exec "$cid" ldconfig || return 1
  {
    echo "# command -V printf, as each shell runs a -c string; ${images[debian-13]}"
    for shell in "${elev_printf_shells[@]}"; do
      # shellcheck disable=SC2086 # `busybox ash` is two words
      out="$(docker exec "$cid" $shell -c 'command -V printf' 2>&1)"
      echo "$shell: exit $? $out"
    done
  } >"$evidence/elevation/printf-builtin.txt"
}

# Runs every case, adding the names of failed or (in check mode)
# differing ones to the caller's `failed` array.
elev_captures() {
  local entry name image tool variant
  for entry in "${elev_cases[@]}"; do
    read -r name image tool variant <<<"$entry"
    echo "== $name: $tool ($variant) in $(elev_image "$image")"
    if ! elev_case_one "$name" "$image" "$tool" "$variant"; then
      echo "!! $name: case failed (log: $evidence/logs/elevation-$name.log)" >&2
      failed+=("$name")
    fi
  done
  echo '== printf builtin status'
  elev_printf || failed+=(printf-builtin)

  [[ "$mode" == check ]] || return 0
  if ! compgen -G "$elev_committed/*.json" >/dev/null; then
    echo '!! no committed elevation evidence; run capture.sh --elevation-only --update' >&2
    failed+=(elevation-evidence)
  elif ! "$work/elev-stage/capture_elevation" check "$elev_committed" \
    "$evidence/elevation"; then
    echo '!! the elevation matrix differs from the committed evidence' >&2
    failed+=(elevation-evidence)
  fi
}

# --update: replaces the committed case files and printf record, keeping
# the README.
elev_update() {
  mkdir -p "$elev_committed"
  rm -f -- "$elev_committed"/*.json "$elev_committed/printf-builtin.txt"
  cp -- "$evidence/elevation"/*.json "$evidence/elevation/printf-builtin.txt" \
    "$elev_committed/"
}
