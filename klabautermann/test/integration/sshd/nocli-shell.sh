#!/bin/sh
# The login shell of the Docker host's no-CLI account (docker-setup.sh;
# M3 D22): sshd runs every session's command through it, and its PATH
# leaves out /usr/local/bin, where the docker CLI is, so that account has
# no engine CLI. The base has no socat; BusyBox's nc, which has no -U,
# stays on the PATH.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
exec /bin/sh "$@"
