/// The start-ticks reader the guarded kill and the operation wrapper share
/// (03 §7.2, §7.17). Internal to the command builders: the barrel does not
/// export it.
library;

/// The status [kStartTicksFunction] returns when `/proc/<pid>` does not
/// exist: the process has exited (or is hidden by `hidepid=2`).
const int kStartTicksGone = 3;

/// The status [kStartTicksFunction] returns when `/proc/<pid>/stat` cannot
/// be read or split into at least 20 fields after its last `) `.
const int kStartTicksUnreadable = 5;

/// Defines `klab_ticks <pid>`, which sets `KT` to the process's start
/// time in clock ticks: field 22 of `/proc/<pid>/stat` [R: proc(5)].
/// `comm` (field 2) may hold spaces and `)`, so the fields resume after
/// the last `) ` of the line, where `state` is field 3 and `starttime`
/// the 20th, as in the `procs` collector. A comm holding a newline ends
/// the first line inside comm, which leaves fewer than 20 fields there,
/// and reads as unreadable rather than as a guess. Globbing is off while
/// the line splits, so a `*` in comm expands to nothing. Inside a
/// function `set --` replaces only the function's own parameters.
const String kStartTicksFunction =
    '''
klab_ticks() {
  KT=
  [ -d "/proc/\$1" ] || return $kStartTicksGone
  if ! IFS= read -r _l 2>/dev/null <"/proc/\$1/stat"; then
    [ -d "/proc/\$1" ] || return $kStartTicksGone
    return $kStartTicksUnreadable
  fi
  case \$_l in *') '*) ;; *) return $kStartTicksUnreadable ;; esac
  set -f; set -- \${_l##*) }; set +f
  [ \$# -ge 20 ] || return $kStartTicksUnreadable
  case \${20} in '' | *[!0-9]*) return $kStartTicksUnreadable ;; esac
  KT=\${20}
}
''';
