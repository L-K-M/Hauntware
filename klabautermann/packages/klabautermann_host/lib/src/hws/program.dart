/// Assembly of the HWS/1 sampler program (03 §6.2, §6.3).
///
/// The program is written once to the stdin of `sh -s` as function
/// definitions only; its first line sets the session nonce so the nonce
/// never appears in argv, and its last output line is the READY marker.
/// It contains no user-supplied text: requests arrive later as bare
/// command lines (`hw_t`/`hw_o`), because dash reads ahead from a pipe and
/// a `read` loop inside the program would lose them (04 App. A, E1/E2).
library;

import 'dart:math';

import 'collector.dart';

/// Protocol tag printed in the READY marker (03 §6.2).
const kProtocolTag = 'HWS/1';

/// The one command line a sampler's non-PTY exec runs (03 §6.2). The
/// login shell only parses it, then `sh -s` replaces it and reads the
/// program from stdin. `LC_ALL=C` makes `${#var}` count bytes for the
/// section byte counts, `TZ=UTC` fixes time output, and the pager and
/// colour variables keep tool output plain. Every word is plain, so sh,
/// bash, zsh, fish and tcsh parse it alike and SSH `env` requests are
/// never needed.
const kSamplerStartCommand =
    'exec env LC_ALL=C TZ=UTC SYSTEMD_PAGER= NO_COLOR=1 sh -s';

/// Collector-set version carried by the READY marker (03 §6.3 "the program
/// text is versioned"). Bumped whenever the shipped fragment set changes.
/// Version 2 adds `procs`, `units`, `timers` and `cron` to the slow sampler.
/// Version 3 adds `dmesg` and `tail` to the probe's tool list, the probe's
/// `lxcfs` area (D50) and the slow program's `HW_UTF8` check (D49).
/// Version 4 filters `overview` and `core` on the host and adds the ZFS
/// ARC to `core` (D48).
const kCollectorSetVersion = '4';

/// The `timeout` guard applied to forking collectors (03 §6.2).
const kCollectorTimeoutSeconds = 10;

/// Payload line emitted by `hw_run` when the host has no `timeout`: the
/// collector ran unguarded, and the payload says so (03 §6.3).
const kTimeoutAbsentMarker = 'hw_timeout=absent';

/// Payload sub-block header separating the files one collector reads into
/// a single `S` section, for example `== meminfo ==`. Hyphens are allowed
/// so the `os-release` block parses.
final blockHeaderPattern = RegExp(r'^== ([a-z0-9_-]+) ==$');

/// The probe's tool list (03 §6.1 "about 30 tools"): the program checks
/// each with `command -v` and reports its path or absence. `dmesg` and
/// `tail` back the kernel-log fallback (LOG-03) and the file tail
/// (LOG-22) panel declarations.
const kProbeTools = [
  'journalctl',
  'crontab',
  'ss',
  'ip',
  'lsblk',
  'findmnt',
  'smartctl',
  'sensors',
  'docker',
  'podman',
  'socat',
  'timeout',
  'setsid',
  'ncdu',
  'gdu',
  'sadf',
  'logger',
  'systemd-run',
  'systemd-analyze',
  'apt-get',
  'dnf',
  'dnf5',
  'apk',
  'pacman',
  'zypper',
  'nvidia-smi',
  'dmesg',
  'tail',
];

/// Generates the per-session nonce: 128 bits from a caller-supplied
/// secure source, rendered as 32 hex digits (03 §6.2).
String generateNonce(Random random) {
  final b = StringBuffer();
  for (var i = 0; i < 16; i++) {
    b.write(random.nextInt(256).toRadixString(16).padLeft(2, '0'));
  }
  return b.toString();
}

/// The shell fragment defining `c_<collector>` for each collector
/// (03 §6.4). Values are constants assembled verbatim into the program.
const collectorFragments = <Collector, String>{
  Collector.overview: _kOverviewFragment,
  Collector.core: _kCoreFragment,
  Collector.fs: _kFsFragment,
  Collector.identity: _kIdentityFragment,
  Collector.probe: _kProbeFragment,
  Collector.procs: _kProcsFragment,
  Collector.units: _kUnitsFragment,
  Collector.timers: _kTimersFragment,
  Collector.cron: _kCronFragment,
};

/// Assembles the program text for [kind]: the nonce line first, then the
/// shared helpers, then the fragments of every collector on that sampler,
/// then nothing else; the program's own last output line is the READY
/// marker (03 §6.2 "The client sends nothing else until it has read
/// READY").
///
/// [nonce] must be 32 lowercase hex digits as produced by [generateNonce].
String buildSamplerProgram({required SamplerKind kind, required String nonce}) {
  if (!_noncePattern.hasMatch(nonce)) {
    throw ArgumentError.value(nonce, 'nonce', 'must be 32 hex digits');
  }
  final collectors = Collector.values.where((c) => c.sampler == kind);
  final b = StringBuffer()
    ..writeln('N=$nonce')
    ..writeln(_kHelpers)
    ..writeln(kind == SamplerKind.fast ? _kFastHelpers : _kSlowLocale);
  for (final c in collectors) {
    b.writeln(collectorFragments[c]);
  }
  b.write(_kReady);
  return b.toString();
}

final _noncePattern = RegExp(r'^[0-9a-f]{32}$');

/// Shared helpers: the section emitter, the timeout ladder, the status
/// classifier, and the two request handlers. Written to both samplers;
/// the fast one simply never calls the forking helpers (03 §6.3).
const _kHelpers = r"""
NL='
'
_HW_T=
if command -v timeout >/dev/null 2>&1; then _HW_T='timeout 10'; fi

hw_sec() { printf '\036%s S %s %s %s\n%s\n' "$N" "$1" "$2" "${#3}" "$3"; }

# Forking collectors capture through hw_run: with `timeout` the command is
# guarded; without it the payload opens with the hw_timeout=absent marker
# line so the absence is visible in the section itself (03 §6.3).
hw_run() {
  if [ -n "$_HW_T" ]; then
    $_HW_T "$@"
  else
    printf '%s\n' 'hw_timeout=absent'
    "$@"
  fi
}

# hw_qrun is hw_run without the marker for places where the command's
# output is stored in a `key=value` field the sentinel would corrupt.
hw_qrun() {
  if [ -n "$_HW_T" ]; then
    $_HW_T "$@"
  else
    "$@"
  fi
}

# Prints 'json' when systemctl speaks --output=json for list-units and
# list-timers (systemd >= 246, 03 §6.4), else 'text'; fails without
# systemctl. Used by the units and timers fragments.
hw_sdfmt() {
  command -v systemctl >/dev/null 2>&1 || return 1
  _v=$(systemctl --version </dev/null 2>&1) || return 1
  _v=${_v%%"$NL"*}; _v=${_v#systemd }; _v=${_v%%[!0-9]*}
  case $_v in
    '' | *[!0-9]*)
      printf text
      return 0 ;;
  esac
  if [ "$_v" -ge 246 ]; then printf json; else printf text; fi
}

# Maps an exit status plus captured stderr to a section status
# (03 §6.2): permission errors surface as `denied`.
hw_st() {
  case $1 in
    0) printf ok ;;
    124) printf timeout ;;
    *)
      case $2 in
        *'Permission denied'* | *'permission denied'* | *'Operation not permitted'* | *EACCES*)
          printf denied ;;
        *)
          printf error ;;
      esac ;;
  esac
}

# Tick request: `hw_t <seq> <collector>...` (03 §6.2). Every collector
# runs with stdin from /dev/null so none can consume the request stream.
hw_t() {
  s=$1; shift
  read -r up _ </proc/uptime
  printf '\036%s B %s %s\n' "$N" "$s" "$up"
  for c in "$@"; do
    st=error; o=''; emitted=
    c_$c </dev/null
    [ -n "$emitted" ] || hw_sec "$c" "$st" "$o"
  done
  printf '\036%s E %s\n' "$N" "$s"
}

# On-demand request: `hw_o <seq> <collector> <arg>...`; the args go to the
# collector function after the client's validators and quoting (03 §8.8).
hw_o() {
  s=$1; shift
  c=$1; shift
  read -r up _ </proc/uptime
  printf '\036%s B %s %s\n' "$N" "$s" "$up"
  st=error; o=''; emitted=
  c_$c "$@" </dev/null
  [ -n "$emitted" ] || hw_sec "$c" "$st" "$o"
  printf '\036%s E %s\n' "$N" "$s"
}
""";

/// The slow program's locale decision (D49), made once at start so the
/// program text stays a constant: `HW_UTF8` is 1 when `locale -a` lists
/// C.UTF-8. A collector that renders text for people (A11Y-08) prefixes
/// `LC_ALL=C.UTF-8` on its own command when it is set and otherwise keeps
/// the sampler's `LC_ALL=C`; none of the version 3 collectors does yet.
/// The probe's `locale` area reports the decision. The fast program runs
/// builtin collectors only, forks nothing and so has no such check.
const _kSlowLocale = r"""
HW_UTF8=
if command -v locale >/dev/null 2>&1 &&
  hw_qrun locale -a </dev/null 2>/dev/null | grep -qiE '^C\.UTF-?8$'; then
  HW_UTF8=1
fi
""";

/// The fast program's readers (D48): each keeps only the rows and fields
/// the engine uses, with builtins only (03 §6.2 fork budget), so the
/// filtering happens before anything crosses the link. The slow program
/// does not carry them.
const _kFastHelpers = r"""
# mksh, and BusyBox on a 32-bit CPU without SH_MATH_64, do shell
# arithmetic in 32 bits, and a core's idle sum passes 2^31 jiffies after
# about 248 days at USER_HZ 100. Such a shell sends a core's eight
# counters instead (D48).
HW_W64=
[ $((2147483647 + 1)) -gt 0 ] && HW_W64=1

# A file the fast collectors cannot do without: unreadable is `denied`,
# absent `error` (03 §6.2 status vocabulary), and the caller skips it.
hw_readable() {
  [ -r "$1" ] && return 0
  if [ -e "$1" ]; then st=denied; else st=error; fi
  return 1
}

# MEM-01's meminfo subset as `<key>: <kB>`, without the padding.
hw_meminfo() {
  o="$o$NL== meminfo =="
  hw_readable /proc/meminfo || return 0
  while read -r _k _v _x; do
    case $_k in
      MemTotal: | MemFree: | MemAvailable: | Buffers: | Cached: | SReclaimable: | Shmem: | SwapTotal: | SwapFree:)
        o="$o$NL$_k $_v" ;;
    esac
  done </proc/meminfo || st=error
}

# NET-01's counters as `<interface> <rx bytes> <tx bytes>`. Only
# interfaces backed by a device (a `device` link in sysfs) whose master,
# if any, has none: bridges, bonds, VLANs, veths, tunnels and loopback
# have no device and carry traffic a device already counts, and the
# Hyper-V and failover masters already count their enslaved VF. Without
# such an interface (inside a container, or without sysfs) every
# interface but lo stays. Rows that never moved a byte are left out.
hw_netdev() {
  o="$o$NL== netdev =="
  hw_readable /proc/net/dev || return 0
  _d=; _a=
  while IFS=': ' read -r _n _rb _x _x _x _x _x _x _x _tb _x; do
    case $_n:$_rb:$_tb in
      lo:* | *:0:0 | *::* | *: | *:*[!0-9]*:* | *:*:*[!0-9]*)
        continue ;;
    esac
    if [ -e "/sys/class/net/$_n/device" ] && [ ! -e "/sys/class/net/$_n/master/device" ]; then
      _d="$_d$NL$_n $_rb $_tb"
    else
      _a="$_a$NL$_n $_rb $_tb"
    fi
  done </proc/net/dev || st=error
  o="$o${_d:-$_a}"
}

# DSK-03's counters as `<device> <reads> <sectors read> <writes>
# <sectors written>`, whole disks only. A partition (a `partition` file
# in sysfs) or a stacked device (entries under `slaves/`: LVM, dm-crypt,
# multipath, md) repeats its disks' I/O; loop, ram, zram and ZFS volume
# (zd) devices are files or memory, or count again on the pool's disks.
# Rows that never did I/O are left out.
hw_diskstats() {
  o="$o$NL== diskstats =="
  hw_readable /proc/diskstats || return 0
  while read -r _x _x _n _r _x _sr _x _w _x _sw _x; do
    case $_n in
      loop* | ram* | zram* | zd*)
        continue ;;
    esac
    case $_r:$_sr:$_w:$_sw in
      0:0:0:0 | *::* | :* | *: | *[!0-9:]*)
        continue ;;
    esac
    [ -e "/sys/class/block/$_n/partition" ] && continue
    for _s in "/sys/class/block/$_n/slaves/"*; do break; done
    [ -e "$_s" ] && continue
    o="$o$NL$_n $_r $_sr $_w $_sw"
  done </proc/diskstats || st=error
}
""";

/// `overview` (03 §6.4): the total `cpu` line of /proc/stat, then the
/// meminfo subset, /proc/loadavg and the netdev rows of [_kFastHelpers].
const _kOverviewFragment = r"""
c_overview() {
  st=ok
  o='== stat =='
  while IFS= read -r l; do
    case $l in
      'cpu '*)
        o="$o$NL$l" ;;
      *)
        break ;;
    esac
  done </proc/stat || st=error
  hw_meminfo
  o="$o$NL== loadavg =="
  read -r l </proc/loadavg && o="$o$NL$l" || st=error
  hw_netdev
}
""";

/// `core` (03 §6.4): the overview's blocks with the per-core `cpuN` lines
/// as `cpuN <busy> <idle>` jiffies (CPU-02 shows busy per core; idle is
/// idle plus iowait, busy the other fields but guest, which user and
/// nice already include), or their first eight counters from a shell
/// with 32-bit arithmetic, `btime`, the diskstats rows, PSI averages
/// without the cumulative `total` and without cpu's `full` line, which
/// the kernel sets to zero at the system level
/// (Documentation/accounting/psi.rst), /proc/uptime and, where ZFS is
/// loaded, the ARC's `c_min` and `size`.
const _kCoreFragment = r"""
c_core() {
  st=ok
  o='== stat =='
  while IFS= read -r l; do
    case $l in
      'cpu '*)
        o="$o$NL$l" ;;
      cpu[0-9]*)
        set -- $l
        if [ -n "$HW_W64" ]; then
          o="$o$NL$1 $((${2:-0} + ${3:-0} + ${4:-0} + ${7:-0} + ${8:-0} + ${9:-0})) $((${5:-0} + ${6:-0}))"
        else
          o="$o$NL$1 ${2:-0} ${3:-0} ${4:-0} ${5:-0} ${6:-0} ${7:-0} ${8:-0} ${9:-0}"
        fi ;;
      btime\ *)
        o="$o$NL$l"
        break ;;
    esac
  done </proc/stat || st=error
  hw_meminfo
  o="$o$NL== loadavg =="
  read -r l </proc/loadavg && o="$o$NL$l" || st=error
  hw_netdev
  hw_diskstats
  for p in cpu io memory; do
    [ -r "/proc/pressure/$p" ] || continue
    o="$o$NL== pressure_$p =="
    while read -r _k _a _b _c _x; do
      case $p:$_k in
        cpu:full) ;;
        *:some | *:full)
          o="$o$NL$_k $_a $_b $_c" ;;
      esac
    done <"/proc/pressure/$p"
  done
  o="$o$NL== uptime ==";
  read -r l </proc/uptime && o="$o$NL$l" || st=error
  if [ -e /proc/spl/kstat/zfs/arcstats ]; then
    o="$o$NL== arcstats =="
    _m=; _z=
    while read -r _n _t _v; do
      case $_n in
        c_min) _m=$_v ;;
        size) _z=$_v ;;
        *) continue ;;
      esac
      o="$o$NL$_n $_v"
      [ -n "$_m" ] && [ -n "$_z" ] && break
    done 2>/dev/null </proc/spl/kstat/zfs/arcstats
  fi
}
""";

/// `fs` (03 §6.4, §7.3): `df -PT -B1` and `df -Pi` under `timeout 10`,
/// because a stale NFS mount hangs `df`. The section status is the worse
/// of the two runs; partial output still parses.
const _kFsFragment = r"""
c_fs() {
  st=ok; o=''
  if ! command -v df >/dev/null 2>&1; then
    st=missing
    return 0
  fi
  b=$(hw_run df -PT -B1 </dev/null 2>&1); rb=$?
  i=$(hw_run df -Pi </dev/null 2>&1); ri=$?
  o="== blocks ==$NL$b$NL== inodes ==$NL$i"
  sb=$(hw_st "$rb" "$b"); si=$(hw_st "$ri" "$i")
  case $sb:$si in
    ok:ok)
      st=ok ;;
    *:timeout | timeout:*)
      st=timeout ;;
    *:denied | denied:*)
      st=denied ;;
    *:missing | missing:*)
      st=missing ;;
    *)
      st=error ;;
  esac
}
""";

/// `identity` (03 §6.4): /etc/os-release, `uname -s -r -m`, and
/// `hostnamectl --json=short` where the flag exists (systemd 249+); older
/// systemctl output lands in the block and the parser falls back to
/// os-release.
const _kIdentityFragment = r"""
c_identity() {
  st=ok; o=''
  if [ -r /etc/os-release ]; then
    o='== os-release =='
    while IFS= read -r l; do
      o="$o$NL$l"
    done </etc/os-release || st=error
  else
    o='== os-release =='
    st=error
  fi
  o="$o$NL== uname =="
  u=$(hw_run uname -s -r -m </dev/null 2>&1); rc=$?
  o="$o$NL$u"
  [ "$(hw_st "$rc" "$u")" = ok ] || st=error
  o="$o$NL== hostnamectl =="
  if command -v hostnamectl >/dev/null 2>&1; then
    h=$(hw_run hostnamectl --json=short </dev/null 2>&1)
    o="$o$NL$h"
  fi
}
""";

/// The capability probe (03 §6.1). One `S` section per probe area named
/// `probe_<area>`; every external tool is reached through `command -v`
/// first, so an absent tool reports `missing`, not a shell error. The
/// fragment sets `emitted`, which keeps `hw_t`/`hw_o` from adding a
/// redundant `probe` section around the per-area ones.
const _kProbeFragment = r"""
c_probe() {
  emitted=1
  _probe_kernel
  _probe_distro
  _probe_init
  _probe_virt
  _probe_lxcfs
  _probe_id
  _probe_elev
  _probe_tools
  _probe_kfeat
  _probe_locale
  _probe_socks
  _probe_session
  _probe_clock
  _probe_linger
}

_probe_kernel() {
  if ! command -v uname >/dev/null 2>&1; then
    psec kernel missing ''
    return 0
  fi
  _o=$(hw_qrun uname -s -r -m </dev/null 2>&1)
  _s=$(hw_st $? "$_o")
  psec kernel "$_s" "$_o"
}

_probe_distro() {
  _st=ok; _o=''
  while IFS= read -r _l; do
    _o="$_o$NL$_l"
  done </etc/os-release || _st=error
  psec distro "$_st" "${_o#"$NL"}"
}

_probe_init() {
  _st=ok; _o=''
  if read -r _c </proc/1/comm 2>/dev/null; then
    _o="pid1_comm=$_c"
  else
    _o='pid1_comm='
    _st=error
  fi
  if [ -d /run/systemd/system ]; then
    _o="$_o${NL}systemd_dir=yes"
  else
    _o="$_o${NL}systemd_dir=no"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    _v=$(hw_qrun systemctl --version </dev/null 2>&1); _rc=$?
    _o="$_o${NL}systemctl_rc=$_rc"
    _o="$_o${NL}systemctl_version=${_v%%"$NL"*}"
  else
    _o="$_o${NL}systemctl_version="
  fi
  psec init "$_st" "$_o"
}

_probe_virt() {
  if ! command -v systemd-detect-virt >/dev/null 2>&1; then
    psec virt missing ''
    return 0
  fi
  _v=$(hw_qrun systemd-detect-virt </dev/null 2>&1); _vr=$?
  _c=$(hw_qrun systemd-detect-virt -c </dev/null 2>&1); _cr=$?
  psec virt ok "virt_rc=$_vr${NL}virt=$_v${NL}container_rc=$_cr${NL}container=$_c"
}

# The /proc paths that are fuse.lxcfs mounts (D50): inside a container
# lxcfs serves the container's own figures for most of them, and
# HostProfile.showsHostFigures names the exceptions. Builtins read
# /proc/mounts (`<source> <mount point> <type> ...`); mount points escape
# blanks as \040, so the space-joined list splits cleanly.
_probe_lxcfs() {
  if [ ! -r /proc/mounts ]; then
    psec lxcfs error ''
    return 0
  fi
  _st=ok; _o=''
  while read -r _s _m _t _r; do
    case $_t:$_m in
      fuse.lxcfs:/proc/*)
        _o="$_o $_m" ;;
    esac
  done </proc/mounts || _st=error
  psec lxcfs "$_st" "mounts=${_o# }"
}

_probe_id() {
  if ! command -v id >/dev/null 2>&1; then
    psec identity missing ''
    return 0
  fi
  _u=$(hw_qrun id -u </dev/null 2>&1)
  _n=$(hw_qrun id -un </dev/null 2>&1)
  _g=$(hw_qrun id -nG </dev/null 2>&1)
  psec identity ok "uid=$_u${NL}user=$_n${NL}groups=$_g"
}

_probe_elev() {
  _o=''
  if command -v sudo >/dev/null 2>&1; then
    _v=$(hw_qrun sudo -V </dev/null 2>&1)
    _o="sudo_version=${_v%%"$NL"*}"
    hw_qrun sudo -n true >/dev/null 2>&1
    _o="$_o${NL}sudo_noninteractive=$?"
  else
    _o="sudo_version=${NL}sudo_noninteractive="
  fi
  if command -v doas >/dev/null 2>&1; then
    _o="$_o${NL}doas=present"
    hw_qrun doas -n true >/dev/null 2>&1
    _o="$_o${NL}doas_noninteractive=$?"
  else
    _o="$_o${NL}doas=absent${NL}doas_noninteractive="
  fi
  if command -v run0 >/dev/null 2>&1; then
    _o="$_o${NL}run0=present"
  else
    _o="$_o${NL}run0=absent"
  fi
  _p=$(command -V printf 2>/dev/null)
  case $_p in
    *builtin*)
      _o="$_o${NL}printf=builtin" ;;
    *)
      _o="$_o${NL}printf=external" ;;
  esac
  psec elev ok "$_o"
}

_probe_tools() {
  _o=''
  for _t in journalctl crontab ss ip lsblk findmnt smartctl sensors docker podman socat timeout setsid ncdu gdu sadf logger systemd-run systemd-analyze apt-get dnf dnf5 apk pacman zypper nvidia-smi dmesg tail; do
    if command -v "$_t" >/dev/null 2>&1; then
      _o="$_o$NL$_t=$(command -v "$_t" 2>/dev/null)"
    else
      _o="$_o$NL$_t="
    fi
  done
  psec tools ok "${_o#"$NL"}"
}

_probe_kfeat() {
  if [ -r /proc/pressure/cpu ]; then
    _o='psi=yes'
  else
    _o='psi=no'
  fi
  if [ -e /sys/fs/cgroup/cgroup.controllers ]; then
    _o="$_o${NL}cgroup_v2=yes"
  else
    _o="$_o${NL}cgroup_v2=no"
  fi
  psec kfeat ok "$_o"
}

_probe_locale() {
  if ! command -v locale >/dev/null 2>&1; then
    psec locale missing ''
    return 0
  fi
  if [ -n "$HW_UTF8" ]; then
    psec locale ok 'c_utf8=yes'
  else
    psec locale ok 'c_utf8=no'
  fi
}

_probe_socks() {
  _u=$(hw_qrun id -u </dev/null 2>&1)
  _o=''
  for _p in /var/run/docker.sock /run/podman/podman.sock "/run/user/$_u/docker.sock" "/run/user/$_u/podman/podman.sock"; do
    _e=no; _w=no
    [ -S "$_p" ] && _e=yes
    [ -w "$_p" ] && _w=yes
    _o="$_o$NL$_p $_e $_w"
  done
  psec sockets ok "${_o#"$NL"}"
}

_probe_session() {
  _o="ssh_connection=$SSH_CONNECTION"
  _o="$_o${NL}ppid=$PPID"
  if read -r _c </proc/$PPID/comm 2>/dev/null; then
    _o="$_o${NL}ppid_comm=$_c"
  else
    _o="$_o${NL}ppid_comm="
  fi
  psec session ok "$_o"
}

_probe_clock() {
  _st=ok; _o=''
  if command -v date >/dev/null 2>&1; then
    _e=$(hw_qrun date +%s </dev/null 2>&1)
    _z=$( (unset TZ; hw_qrun date +%z </dev/null 2>&1) )
    _o="epoch=$_e${NL}offset=$_z"
  else
    _o="epoch=${NL}offset="
    _st=error
  fi
  if command -v timedatectl >/dev/null 2>&1; then
    _t=$(hw_qrun timedatectl show -p Timezone </dev/null 2>&1)
    case $_t in
      Timezone=*)
        _o="$_o${NL}$_t" ;;
      *)
        _o="$_o${NL}timedatectl_error=yes" ;;
    esac
  fi
  if [ -r /etc/timezone ]; then
    read -r _tz </etc/timezone && _o="$_o${NL}etc_timezone=$_tz"
  fi
  if [ -L /etc/localtime ]; then
    _lt=$(readlink /etc/localtime 2>/dev/null) && _o="$_o${NL}localtime=$_lt"
  fi
  psec clock "$_st" "$_o"
}

_probe_linger() {
  _o="xdg_runtime_dir=$XDG_RUNTIME_DIR"
  if command -v loginctl >/dev/null 2>&1 && command -v id >/dev/null 2>&1; then
    _un=$(hw_qrun id -un </dev/null 2>&1)
    _l=$(hw_qrun loginctl show-user "$_un" -p Linger </dev/null 2>&1)
    case $_l in
      Linger=*)
        _o="$_o${NL}$_l" ;;
      *)
        _o="$_o${NL}linger_error=yes" ;;
    esac
  fi
  if [ -r /etc/systemd/logind.conf ]; then
    while IFS= read -r _l; do
      case $_l in
        KillUserProcesses=*)
          _o="$_o${NL}$_l" ;;
      esac
    done </etc/systemd/logind.conf
  fi
  psec linger ok "$_o"
}

# Probe areas run unguarded through hw_qrun, so psec itself prepends the
# absence note when `timeout` is missing (03 §6.3); the key=value payloads
# tolerate the extra line.
psec() {
  if [ -n "$_HW_T" ]; then
    hw_sec "probe_$1" "$2" "$3"
  else
    hw_sec "probe_$1" "$2" "hw_timeout=absent$NL$3"
  fi
}
""";

/// `procs` (03 §7.2): `/proc/<pid>/stat` and the needed `status` fields
/// with builtins, every `/proc/<pid>/cmdline` through one `head -n 1000`
/// piped into `tr '\000' '\037'` (shell variables cannot hold NULs; 04
/// App. A, E11). When head or tr is absent the fallbacks are
/// `ps -eo pid,ppid,user,stat,rss,args` then BusyBox `ps w`. The `==> `
/// headers head prints and the forgery they enable are the parser's
/// problem (03 §7.2), so the bytes go into the `cmdline` block verbatim.
const _kProcsFragment = r"""
c_procs() {
  st=ok
  o='== stat =='
  for _f in /proc/[0-9]*/stat; do
    _p=${_f#/proc/}; _p=${_p%/stat}
    if IFS= read -r _l <"$_f"; then o="$o$NL$_p $_l"; fi
  done
  o="$o$NL== status =="
  for _f in /proc/[0-9]*/status; do
    _p=${_f#/proc/}; _p=${_p%/status}
    [ -r "$_f" ] || continue
    while IFS= read -r _l; do
      case $_l in
        Name:* | Uid:* | Gid:* | VmRSS:* | Threads:*)
          o="$o$NL$_p $_l" ;;
      esac
    done <"$_f"
  done
  o="$o$NL== cmdline =="
  if command -v head >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
    _c=$(cd /proc 2>/dev/null && hw_run head -n 1000 [0-9]*/cmdline 2>/dev/null </dev/null | tr '\000' '\037')
    o="$o$NL$_c"
  elif command -v ps >/dev/null 2>&1; then
    _c=$(hw_run ps -eo pid,ppid,user,stat,rss,args </dev/null 2>&1)
    if [ $? -eq 0 ]; then
      o="$o$NL== ps ==$NL$_c"
    else
      _c=$(hw_run ps w </dev/null 2>&1)
      o="$o$NL== ps_w ==$NL$_c"
    fi
  fi
}
""";

/// `units` (03 §6.4, §7.5): `systemctl list-units --all` plus
/// `systemctl --failed`, JSON on systemd 246+ and `--plain --no-legend`
/// text below. The block names record which shape the payload holds.
const _kUnitsFragment = r"""
c_units() {
  st=ok; o=''
  if ! command -v systemctl >/dev/null 2>&1; then st=missing; return 0; fi
  if [ "$(hw_sdfmt)" = json ]; then
    _u=$(hw_run systemctl list-units --all --output=json </dev/null 2>&1); _ru=$?
    _f=$(hw_run systemctl --failed --output=json </dev/null 2>&1); _rf=$?
    o="== units_json ==$NL$_u$NL== failed_json ==$NL$_f"
  else
    _u=$(hw_run systemctl list-units --all --plain --no-legend </dev/null 2>&1); _ru=$?
    _f=$(hw_run systemctl --failed --plain --no-legend </dev/null 2>&1); _rf=$?
    o="== units_text ==$NL$_u$NL== failed_text ==$NL$_f"
  fi
  _su=$(hw_st "$_ru" "$_u"); _sf=$(hw_st "$_rf" "$_f")
  case $_su:$_sf in
    ok:ok)
      st=ok ;;
    *:timeout | timeout:*)
      st=timeout ;;
    *:denied | denied:*)
      st=denied ;;
    *)
      st=error ;;
  esac
}
""";

/// `timers` (03 §6.4, §7.7): `systemctl list-timers --all`, JSON on
/// systemd 246+ and the columnar text table below. The text table keeps
/// its header row: the parser slices rows at the header's column offsets.
const _kTimersFragment = r"""
c_timers() {
  st=ok; o=''
  if ! command -v systemctl >/dev/null 2>&1; then st=missing; return 0; fi
  if [ "$(hw_sdfmt)" = json ]; then
    _t=$(hw_run systemctl list-timers --all --output=json </dev/null 2>&1); _rt=$?
    o="== timers_json ==$NL$_t"
  else
    _t=$(hw_run systemctl list-timers --all </dev/null 2>&1); _rt=$?
    o="== timers_text ==$NL$_t"
  fi
  st=$(hw_st "$_rt" "$_t")
}
""";

/// `cron` (03 §6.4, §7.7): own `crontab -l` (exit 1 with "no crontab" is
/// empty, not an error; the meta block carries the exit code so the
/// parser can tell), `/etc/crontab`, `/etc/cron.d/*` as name-prefixed
/// lines, and the entry names of `cron.{hourly,daily,weekly,monthly}`.
const _kCronFragment = r"""
c_cron() {
  st=ok; o=''
  if command -v crontab >/dev/null 2>&1; then
    _c=$(hw_qrun crontab -l </dev/null 2>&1); _rc=$?
    o="== crontab_meta ==${NL}rc=$_rc$NL== crontab ==$NL$_c"
  else
    o="== crontab_meta ==${NL}tool=missing$NL== crontab =="
  fi
  o="$o$NL== etc_crontab =="
  if [ -r /etc/crontab ]; then
    while IFS= read -r _l; do o="$o$NL$_l"; done </etc/crontab
  elif [ -e /etc/crontab ]; then
    st=denied
  fi
  o="$o$NL== cron_d =="
  for _f in /etc/cron.d/*; do
    [ -f "$_f" ] && [ -r "$_f" ] || continue
    _n=${_f##*/}
    while IFS= read -r _l; do
      o="$o$NL$_n	$_l"
    done <"$_f"
  done
  o="$o$NL== cron_dirs =="
  for _d in hourly daily weekly monthly; do
    for _f in "/etc/cron.$_d"/*; do
      [ -e "$_f" ] || continue
      o="$o$NL$_d ${_f##*/}"
    done
  done
}
""";

/// The READY marker is the program's last output line (03 §6.2).
const _kReady =
    "printf '\\036%s READY HWS/1 $kCollectorSetVersion\\n' \"\$N\"\n";
