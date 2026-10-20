#!/bin/sh
# The host write inventory's snapshot (03 §8.11, M4 plan M18): every path
# under the given roots with its raw mode, owner, group and size, then
# the SHA-256 of each regular file up to 1 MiB. run.sh pipes it into the
# Docker host as root before and after a scripted session; inventory.dart
# diffs the two and checks every change against inventory_allowlist.txt.
#
#   sh -s -- <root>... < inventory.sh
#
# It stays on each root's filesystem and leaves out what 8.11 excludes:
# /proc, /sys and /dev, runtime state under /run (transient units and
# utmp among it), journals, login records and engine state. POSIX sh,
# with find, xargs, stat -c and sha256sum as GNU and BusyBox both give
# them. Unreadable paths are skipped: it runs as root.
set -eu

if [ "$#" -eq 0 ]; then
  echo 'usage: inventory.sh <root>...' >&2
  exit 64
fi

# find over root $1 with 8.11's exclusions pruned; the other arguments
# select and print.
walk() {
  root="$1"
  shift
  find "$root" -xdev \( \
    -path /proc -o -path /sys -o -path /dev -o -path /run -o \
    -path /var/run -o -path /var/log/journal -o \
    -path /var/log/wtmp -o -path /var/log/btmp -o -path /var/log/lastlog -o \
    -path '/var/log/auth.log*' -o -path '/var/log/secure*' -o \
    -path /var/lib/docker -o -path /var/lib/containerd -o \
    -path /var/lib/containers \
    \) -prune -o "$@" 2>/dev/null || true
}

tab="$(printf '\t')"
# The raw mode in hex (type and permission bits), uid, gid, size, path.
format="S${tab}%f${tab}%u${tab}%g${tab}%s${tab}%n"

for root in "$@"; do
  [ -e "$root" ] || continue
  walk "$root" -print0 | xargs -0 -r stat -c "$format" 2>/dev/null || true
done

echo '--- sha256'
for root in "$@"; do
  [ -e "$root" ] || continue
  walk "$root" -type f -size -1048577c -print0 |
    xargs -0 -r sha256sum 2>/dev/null || true
done
