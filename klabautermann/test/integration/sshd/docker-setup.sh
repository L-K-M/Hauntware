#!/bin/sh
# The Docker host's accounts and socket paths (03 §11.3), which
# fixture-entrypoint runs as root once the fixture user exists. It runs on
# every start, and `compose restart` keeps the container's files, so each
# step accepts what an earlier start left.
set -eu

if [ "$#" -ne 2 ]; then
  echo 'usage: fixture-setup FIXTURE-USER AUTHORIZED-KEYS' >&2
  exit 2
fi
readonly fixture_user="$1"
readonly authorized_keys="$2"
# dind's dockerd hands its socket to this gid (`--group 990` in
# docker-compose.yml); the base leaves it free.
readonly docker_gid=990
# Signs in with the same keys but is outside the group, so the socket
# refuses it (EACCES).
readonly negative_user='klab-nosock'
# In the group, so it may write the socket, but its login shell
# (nocli-shell.sh) puts no engine CLI on its PATH: the ladder's last
# rung, with no relay to start (M3 D22).
readonly nocli_user='klab-nocli'
readonly nocli_shell='/usr/local/libexec/fixture-nocli-shell'
readonly socket='/run/docker-fixture/docker.sock'

if ! getent group docker >/dev/null; then
  addgroup -g "$docker_gid" docker
fi
if ! id -nG "$fixture_user" | tr ' ' '\n' | grep -qx docker; then
  addgroup "$fixture_user" docker
fi

# Adds [user] with [shell], signing in with the same keys.
add_account() {
  user="$1"
  shell="$2"
  if ! id "$user" >/dev/null 2>&1; then
    adduser -D -s "$shell" "$user"
    # As for the fixture user: adduser -D leaves the account locked,
    # which PAM refuses even for keys.
    printf '%s:%s\n' "$user" "$(head -c 24 /dev/urandom | base64)" \
      | chpasswd
  fi
  home="/home/$user"
  install -d -m 0700 -o "$user" -g "$user" "$home/.ssh"
  install -m 0600 -o "$user" -g "$user" \
    "$authorized_keys" "$home/.ssh/authorized_keys"
}

add_account "$negative_user" /bin/sh
add_account "$nocli_user" "$nocli_shell"
if ! id -nG "$nocli_user" | tr ' ' '\n' | grep -qx docker; then
  addgroup "$nocli_user" docker
fi

# The engine's first candidate path, and a second for the discovery
# tests: the rootless path of the fixture user's uid (03 §5.4).
ln -sfn "$socket" /var/run/docker.sock
uid="$(id -u "$fixture_user")"
install -d -m 0700 -o "$fixture_user" -g "$fixture_user" "/run/user/$uid"
ln -sfn "$socket" "/run/user/$uid/docker.sock"

# The host's syslog (M5 M20a): BusyBox syslogd writes /var/log/messages,
# where the edit suite reads the `logger -t klabautermann` line (SAF-13).
# A restart stops the daemon with the container, so each start runs one.
syslogd
