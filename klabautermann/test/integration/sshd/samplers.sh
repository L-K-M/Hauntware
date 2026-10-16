#!/bin/sh
# Prints the PIDs of the engine's sampler shells, oldest first: each
# `sh -s` that sshd started, not the subshells a sampler forks, which
# show the same command line. A link starts its slow sampler, runs the
# probe on it, then starts the fast one, so on a fresh link the fast
# sampler is the last line.
set -eu

ps -o pid,ppid,args | awk '
  NR > 1 {
    parent[$1] = $2
    command = $0
    sub(/^ *[0-9]+ +[0-9]+ +/, "", command)
    args[$1] = command
  }
  END {
    for (pid in args) {
      if (args[pid] == "sh -s" && args[parent[pid]] != "sh -s") print pid
    }
  }
' | sort -n
