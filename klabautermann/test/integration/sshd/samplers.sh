#!/bin/sh
# Prints the PIDs of the engine's sampler shells, oldest first: each
# `sh -s` that sshd started, not the subshells a sampler forks, which
# show the same command line. A link opens its slow sampler and then its
# fast one in one step (SamplingScheduler._start); the probe only holds
# the fast one's ticks. The exec requests reach sshd in that order on
# the one connection, so on a fresh link the fast sampler is the last
# line.
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
