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
/// Version 5 bounds `procs` to [kProcsRowCap] trimmed rows (D48).
/// Version 6 adds the on-demand `timer_detail` to the slow sampler (D57).
/// Version 7 reads a guarded command BusyBox's `timeout` stopped as a
/// timeout.
/// Version 8 adds the `SELF` marker before READY, the probe's
/// `run0 --no-ask-password true` check and the slow `ops` collector
/// (03 §7.17).
/// Version 9 adds the slow `user_units` and `user_timers` collectors for
/// the login user's own manager (03 §7.5, SVC-09).
/// Version 10 adds DSK-04's ms reading, ms writing and ms doing I/O to
/// `core`'s diskstats rows (D48).
const kCollectorSetVersion = '10';

/// The most `procs` rows one reply carries (D48). With more processes the
/// fragment keeps the union of the [kProcsRowCap] / 2 with the highest CPU
/// share since their start and the [kProcsRowCap] / 2 with the most
/// resident memory, and its `meta` block reports the total.
const kProcsRowCap = 500;

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
  Collector.userUnits: _kUserUnitsFragment,
  Collector.userTimers: _kUserTimersFragment,
  Collector.cron: _kCronFragment,
  Collector.timerDetail: _kTimerDetailFragment,
  Collector.ops: _kOpsFragment,
};

/// Assembles the program text for [kind]: the nonce line first, then the
/// shared helpers, then the fragments of every collector on that sampler,
/// then nothing else; the program's last two output lines are the `SELF`
/// marker, which carries the sampler shell's `$$` and `$PPID` for the
/// protected targets (03 §8.6), and the READY marker (03 §6.2 "The client
/// sends nothing else until it has read READY").
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
  b
    ..write(_kSelf)
    ..write(_kReady);
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

# Sets systemd's own XDG_RUNTIME_DIR, /run/user/<uid>, where the session
# left it unset, so `systemctl --user` finds the user manager's bus
# (03 §7.5, SVC-09). Used by the user_units and user_timers fragments.
hw_userbus() {
  if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    XDG_RUNTIME_DIR=/run/user/$(id -u 2>/dev/null)
    export XDG_RUNTIME_DIR
  fi
}

# Maps an exit status plus captured stderr to a section status
# (03 §6.2): permission errors surface as `denied`. GNU's timeout exits
# 124 when it stops a command; BusyBox's exits with the command's own
# status, 143 after its SIGTERM, so a guarded 143 is a timeout too.
hw_st() {
  case $1 in
    0) printf ok ;;
    124) printf timeout ;;
    143) if [ -n "$_HW_T" ]; then printf timeout; else printf error; fi ;;
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
# Hyper-V and failover masters already count their enslaved VF. A Xen
# netback port (a xenbus device whose nodename is under `backend/`) is
# a guest's NIC seen from dom0 and counts as virtual. Without such an
# interface (inside a container, whose eth0 is a veth peer) the
# interfaces other than lo that are neither a bridge nor enslaved stay,
# because a nested bridge and its ports repeat what eth0 counts; when
# that leaves none, or without sysfs, every interface but lo stays. Rows
# that never moved a byte are left out.
hw_netdev() {
  o="$o$NL== netdev =="
  hw_readable /proc/net/dev || return 0
  _d=; _v=; _a=
  while IFS=': ' read -r _n _rb _x _x _x _x _x _x _x _tb _x; do
    case $_n:$_rb:$_tb in
      lo:* | *:0:0 | *::* | *: | *:*[!0-9]*:* | *:*:*[!0-9]*)
        continue ;;
    esac
    _a="$_a$NL$_n $_rb $_tb"
    _b=
    [ -r "/sys/class/net/$_n/device/nodename" ] &&
      read -r _b <"/sys/class/net/$_n/device/nodename"
    if [ -e "/sys/class/net/$_n/device" ] && [ "${_b%%/*}" != backend ]; then
      [ -e "/sys/class/net/$_n/master/device" ] || _d="$_d$NL$_n $_rb $_tb"
    elif [ ! -d "/sys/class/net/$_n/bridge" ] && [ ! -e "/sys/class/net/$_n/master" ]; then
      _v="$_v$NL$_n $_rb $_tb"
    fi
  done </proc/net/dev || st=error
  o="$o${_d:-${_v:-$_a}}"
}

# DSK-03's counters and DSK-04's timings as `<device> <reads> <sectors
# read> <writes> <sectors written> <ms reading> <ms writing> <ms doing
# I/O>` of whole disks. A partition (a `partition` file
# in sysfs) or a stacked device (entries under `slaves/`: LVM, dm-crypt,
# multipath, md) repeats its disks' I/O, and without sysfs both stay;
# loop, ram, zram and ZFS volume (zd) devices are files or memory, or
# count again on the pool's disks.
# A hidden NVMe multipath path (nvme<S>c<C>n<N>) waits for the end: its
# head nvme<S>n<N> counts the same I/O on kernels that account it there,
# so the path stays only when the head has none. Rows that never did I/O
# are left out.
hw_diskstats() {
  o="$o$NL== diskstats =="
  hw_readable /proc/diskstats || return 0
  _k=; _p=
  while read -r _x _x _n _r _x _sr _dr _w _x _sw _dw _x _di _x; do
    case $_n in
      loop* | ram* | zram* | zd*)
        continue ;;
    esac
    case $_r:$_sr:$_w:$_sw:$_dr:$_dw:$_di in
      0:0:0:0:* | *::* | :* | *: | *[!0-9:]*)
        continue ;;
    esac
    [ -e "/sys/class/block/$_n/partition" ] && continue
    for _s in "/sys/class/block/$_n/slaves/"*; do break; done
    [ -e "$_s" ] && continue
    case $_n in
      nvme[0-9]*c[0-9]*n[0-9]*)
        _p="$_p$NL$_n $_r $_sr $_w $_sw $_dr $_dw $_di" ;;
      *)
        _k="$_k$NL$_n $_r $_sr $_w $_sw $_dr $_dw $_di" ;;
    esac
  done </proc/diskstats || st=error
  while [ -n "$_p" ]; do
    _p=${_p#"$NL"}; _e=${_p%%"$NL"*}; _p=${_p#"$_e"}
    _n=${_e%% *}
    case $_k in
      *"$NL${_n%%c*}n${_n##*n} "*) ;;
      *) _k="$_k$NL$_e" ;;
    esac
  done
  o="$o$_k"
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
/// without the cumulative `total`, /proc/uptime and, where ZFS is loaded,
/// the ARC's `c_min` and `size`.
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
      case $_k in
        some | full)
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
    hw_qrun run0 --no-ask-password true >/dev/null 2>&1
    _o="$_o${NL}run0_noninteractive=$?"
  else
    _o="$_o${NL}run0=absent${NL}run0_noninteractive="
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

/// `procs` (03 §7.2, D48): one row per process with the fields PRC-01 and
/// PRC-02 use, read with builtins from `/proc/<pid>/stat` and the `Uid:`
/// and `VmRSS:` lines of `status`: pid, state, ppid, utime, stime,
/// starttime, uid, RSS in kB (`-` for an unknown uid or RSS) and comm.
/// Both loops join rows in chunks of 64, so a tick's time grows about
/// linearly with the process count instead of with its square. Any
/// process can put a newline in its comm, which leaves comm text after
/// the last `) ` of the first stat line, so the fields there are split
/// with globbing off and fewer than 20 skip the process.
///
/// Above [kProcsRowCap] processes `sort` keeps the union of the top halves
/// by CPU share since start and by RSS (`selection=cpu_rss`); without
/// `sort` or `head`, or when the selection comes back empty, the first rows
/// in glob order stay (`selection=pid`). The `meta` block carries the
/// total. The share is per mille of one CPU: (utime + stime) * 10 over the
/// whole seconds since start, at USER_HZ 100 (Linux's on every architecture
/// but Alpha). 32-bit shell arithmetic (mksh) wraps it for a process with
/// more than about 24 days of CPU time or started more than 248 days after
/// boot, which only misranks that process. starttime counts from the host's
/// boot but an lxcfs `/proc/uptime` from the container's init (D50), so
/// where `/proc/uptime` is an lxcfs mount PID 1's start goes back onto the
/// clock; `HW_LXUP` caches that check for the sampler's life.
///
/// The selection writes no stderr: `head` closing its pipe early makes
/// `sort` report a broken pipe where SIGPIPE is ignored, and mksh, whose
/// `printf` is an external command, cannot run it once the rows pass the
/// kernel's 128 KiB limit for one argument (above about 2,000 processes),
/// which leaves the glob order.
///
/// The kept rows' `/proc/<pid>/cmdline` go through one `head -n 1000`
/// piped into `tr '\000' '\037'` (shell variables cannot hold NULs; 04
/// App. A, E11), in the byte order of the pids, which is the glob's (03
/// §7.2); without head or tr the fallbacks are
/// `ps -eo pid,ppid,user,stat,rss,args` then BusyBox `ps w`. The `==> `
/// headers head prints and the forgery they enable are the parser's
/// problem (03 §7.2).
const _kProcsFragment = r"""
c_procs() {
  st=ok
  if [ -z "$HW_LXUP" ]; then
    HW_LXUP=0
    while read -r _a _b _c _x; do
      case $_c:$_b in fuse.lxcfs:/proc/uptime) HW_LXUP=1 ;; esac
    done 2>/dev/null </proc/mounts
  fi
  _z=0
  if [ "$HW_LXUP" = 1 ] && IFS= read -r _l 2>/dev/null </proc/1/stat; then
    set -f; set -- ${_l##*) }; set +f; _z=$((${20:-0} / 100))
  fi
  _up=; read -r _up _x 2>/dev/null </proc/uptime
  _up=${_up%%.*}; _now=$((${_up:-0} + _z))
  _r=; _k=; _i=0; _n=0
  for _f in /proc/[0-9]*/stat; do
    IFS= read -r _l 2>/dev/null <"$_f" || continue
    case $_l in
      *') '*) ;;
      *) continue ;;
    esac
    _p=${_f#/proc/}; _p=${_p%/stat}
    _c=${_l#*\(}; _c=${_c%\)*}
    set -f; set -- ${_l##*) }; set +f
    [ $# -ge 20 ] || continue
    _u=-; _m=-
    while read -r _a _b _x; do
      case $_a in
        Uid:) _u=$_b ;;
        VmRSS:) _m=$_b; break ;;
        Threads:) break ;;
      esac
    done 2>/dev/null <"/proc/$_p/status"
    _e=$((_now - ${20} / 100)); [ "$_e" -gt 0 ] || _e=1
    _k="$_k$NL$(((${12} + ${13}) * 10 / _e)) $_p $1 $2 ${12} ${13} ${20} $_u $_m $_c"
    _n=$((_n + 1)); _i=$((_i + 1))
    if [ "$_i" -ge 64 ]; then _r="$_r$_k"; _k=; _i=0; fi
  done
  _r="$_r$_k"; _r=${_r#"$NL"}
  _sel=all
  if [ "$_n" -gt 500 ]; then
    _sel=pid
    if command -v sort >/dev/null 2>&1 && command -v head >/dev/null 2>&1; then
      _s=$({ printf '%s\n' "$_r" 2>/dev/null | sort -k1,1nr 2>/dev/null | head -n 250
        printf '%s\n' "$_r" 2>/dev/null | sort -k9,9nr 2>/dev/null | head -n 250
      } | sort -u -k2,2 2>/dev/null)
      if [ -n "$_s" ]; then _r=$_s; _sel=cpu_rss; fi
    fi
  fi
  o="== meta ==${NL}total=$_n${NL}selection=$_sel$NL== rows =="
  _q=; _k=; _w=; _i=0; _j=0
  set -f; _ifs=$IFS; IFS=$NL
  for _l in $_r; do
    [ "$_i" -lt 500 ] || break
    _l=${_l#* }
    _k="$_k$NL$_l"; _w="$_w ${_l%% *}/cmdline"
    _i=$((_i + 1)); _j=$((_j + 1))
    if [ "$_j" -ge 64 ]; then o="$o$_k"; _q="$_q$_w"; _k=; _w=; _j=0; fi
  done
  o="$o$_k"; _q="$_q$_w"
  IFS=$_ifs; set +f
  o="$o$NL== cmdline =="
  if command -v head >/dev/null 2>&1 && command -v tr >/dev/null 2>&1; then
    _c=$(cd /proc 2>/dev/null && hw_run head -n 1000 $_q 2>/dev/null </dev/null | tr '\000' '\037')
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

/// `user_units` (03 §7.5, SVC-09): `units` for the login user's own
/// manager, `systemctl --user`, in the same block names so one parser
/// reads both. `systemctl --user` finds the manager through
/// `XDG_RUNTIME_DIR`; where the session left it unset, systemd's own
/// `/run/user/<uid>` is set first [U]. Without a user session or linger
/// the bus is not there and the section reports `error`.
const _kUserUnitsFragment = r"""
c_user_units() {
  st=ok; o=''
  if ! command -v systemctl >/dev/null 2>&1; then st=missing; return 0; fi
  hw_userbus
  if [ "$(hw_sdfmt)" = json ]; then
    _u=$(hw_run systemctl --user list-units --all --output=json </dev/null 2>&1); _ru=$?
    _f=$(hw_run systemctl --user --failed --output=json </dev/null 2>&1); _rf=$?
    o="== units_json ==$NL$_u$NL== failed_json ==$NL$_f"
  else
    _u=$(hw_run systemctl --user list-units --all --plain --no-legend </dev/null 2>&1); _ru=$?
    _f=$(hw_run systemctl --user --failed --plain --no-legend </dev/null 2>&1); _rf=$?
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

/// `user_timers` (03 §7.7, JOB-08): `timers` for the login user's own
/// manager, in the same block names, with `user_units`' bus fallback.
const _kUserTimersFragment = r"""
c_user_timers() {
  st=ok; o=''
  if ! command -v systemctl >/dev/null 2>&1; then st=missing; return 0; fi
  hw_userbus
  if [ "$(hw_sdfmt)" = json ]; then
    _t=$(hw_run systemctl --user list-timers --all --output=json </dev/null 2>&1); _rt=$?
    o="== timers_json ==$NL$_t"
  else
    _t=$(hw_run systemctl --user list-timers --all </dev/null 2>&1); _rt=$?
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

/// `timer_detail` (03 §7.7, D57): one timer's triggers and randomized
/// delay from `systemctl show`, which has no JSON output, for the timer
/// unit `hw_o` passes as `$1`; a request without exactly one unit gets an
/// error section. The sampler's `TZ=UTC` prints each `next_elapse` in UTC.
const _kTimerDetailFragment = r"""
c_timer_detail() {
  st=ok; o=''
  if [ $# -ne 1 ]; then st=error; o='timer_detail: expects one timer unit'; return 0; fi
  if ! command -v systemctl >/dev/null 2>&1; then st=missing; return 0; fi
  o=$(hw_run systemctl show -p TimersCalendar -p TimersMonotonic -p RandomizedDelayUSec -- "$1" </dev/null 2>&1); _rd=$?
  st=$(hw_st "$_rd" "$o")
}
""";

/// The login user's operation directory below
/// `${XDG_STATE_HOME:-$HOME/.local/state}` (03 §7.17); the `ops` fragment
/// ignores a relative `XDG_STATE_HOME`, as the XDG base directory
/// specification says.
const kOpsUserSubdirectory = 'klabautermann/ops';

/// The root-owned operation directory (03 §7.17).
const kOpsRootDirectory = '/var/lib/klabautermann/ops';

/// The most records the `ops` collector reads from one directory [E]; the
/// directory's `dir` line still counts every well-named record.
const kOpsRecordCap = 50;

/// The most bytes of one record the `ops` collector sends [E]; a longer
/// file is cut there and marked `truncated`.
const kOpsRecordBytes = 4096;

/// `ops` (03 §7.17): the detached-operation records of both operation
/// directories, for re-attach. Each directory is one guarded command, an
/// `sh -c` of the constant listing script `_HW_OPS` with the directory's
/// kind and path as positional parameters, so a hung home directory costs
/// one `timeout 10` and the fragment declares two guarded commands.
///
/// For each regular file (not a symlink) named `<16 hex digits>.json`, at
/// most [kOpsRecordCap] of them in glob order, the script prints
///
///     rec <kind> <id> <status> <bytes>
///     <exactly bytes bytes of the record>
///
/// and last one `dir <kind> <state> <count> <path>` line, where `state` is
/// `ok`, `absent` or `denied` and `count` the well-named records found. A
/// record's `status` is `ok`, `truncated` (cut at [kOpsRecordBytes]),
/// `denied` or `error`; no bytes follow the last two. The byte counts frame
/// the records as sections are framed, so record text cannot forge another
/// record (the script sets `LC_ALL=C` itself, so `${#c}` counts bytes
/// whatever locale it inherits), and a listing its timeout
/// cut short has no `dir` line. `head -c 4097` bounds each read; the
/// sentinels printed after it and after each listing keep the trailing
/// newlines that command substitution would drop, so a listing cut after
/// a whole record leaves that record framed. The script sends its own stderr to /dev/null,
/// so a shell's warning (bash's about a NUL byte) cannot land between
/// records.
const _kOpsFragment = r"""
_HW_OPS='LC_ALL=C; export LC_ALL; exec 2>/dev/null
k=$1; d=$2; n=0; t=0
if [ ! -e "$d" ]; then printf "dir %s absent 0 %s\n" "$k" "$d"; exit 0; fi
if [ ! -d "$d" ] || [ ! -r "$d" ] || [ ! -x "$d" ]; then
  printf "dir %s denied 0 %s\n" "$k" "$d"; exit 0
fi
for f in "$d"/*.json; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  i=${f##*/}; i=${i%.json}
  case $i in *[!0-9a-f]*) continue ;; esac
  [ ${#i} -eq 16 ] || continue
  t=$((t + 1))
  [ $n -lt 50 ] || continue
  n=$((n + 1))
  if [ ! -r "$f" ]; then printf "rec %s %s denied 0\n\n" "$k" "$i"; continue; fi
  c=$(head -c 4097 "$f"; r=$?; printf x; exit $r); r=$?
  c=${c%x}
  if [ $r -ne 0 ]; then printf "rec %s %s error 0\n\n" "$k" "$i"; continue; fi
  s=ok
  if [ ${#c} -gt 4096 ]; then c=${c%?}; s=truncated; fi
  printf "rec %s %s %s %s\n%s\n" "$k" "$i" "$s" ${#c} "$c"
done
printf "dir %s ok %s %s\n" "$k" "$t" "$d"'

c_ops() {
  st=ok; o=''
  if ! command -v head >/dev/null 2>&1; then st=missing; return 0; fi
  _u=${XDG_STATE_HOME:-$HOME/.local/state}
  case $_u in /*) ;; *) _u=$HOME/.local/state ;; esac
  _a=$(hw_run sh -c "$_HW_OPS" sh user "$_u/klabautermann/ops" </dev/null 2>&1; _r=$?; printf x; exit $_r); _ra=$?
  _b=$(hw_run sh -c "$_HW_OPS" sh root /var/lib/klabautermann/ops </dev/null 2>&1; _r=$?; printf x; exit $_r); _rb=$?
  o="${_a%x}${_b%x}"
  case $(hw_st "$_ra" ''):$(hw_st "$_rb" '') in
    ok:ok)
      st=ok ;;
    *:timeout | timeout:*)
      st=timeout ;;
    *)
      st=error ;;
  esac
}
""";

/// The `SELF` marker (03 §6.2, §8.6), printed just before READY: the
/// sampler shell's PID and its parent's. `kSamplerStartCommand` execs
/// `env`, which execs `sh -s`, so `$$` is the process sshd started for
/// the channel and `$PPID` the sshd process serving the session.
const _kSelf = r"""
printf '\036%s SELF %s %s\n' "$N" "$$" "$PPID"
""";

/// The READY marker is the program's last output line (03 §6.2).
const _kReady =
    "printf '\\036%s READY HWS/1 $kCollectorSetVersion\\n' \"\$N\"\n";
