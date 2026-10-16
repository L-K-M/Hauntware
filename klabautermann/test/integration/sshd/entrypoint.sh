#!/bin/sh
# Starts sshd with the config named by the service's command (03 §11.3).
# Keys are generated, never committed (D53): host keys here, client keys
# by run.sh, which mounts their public halves as authorized_keys.
set -eu

readonly fixture_user='klab'
readonly authorized_keys='/run/fixture/authorized_keys'
readonly flag_dir='/run/klabautermann-fixture'

if [ "$#" -ne 1 ]; then
  echo 'expected one sshd config path' >&2
  exit 2
fi
if [ ! -s "$authorized_keys" ]; then
  echo "missing $authorized_keys: start the fixture with run.sh" >&2
  exit 1
fi

# Generates only the missing keys. `compose restart` keeps the container's
# files, so the key the engine pinned survives a restart.
ssh-keygen -A

# A restart keeps the account too.
if ! id "$fixture_user" >/dev/null 2>&1; then
  adduser -D -s /bin/sh "$fixture_user"
  # adduser -D leaves the account locked, which PAM refuses even for
  # keys; a random password nobody learns unlocks it.
  printf '%s:%s\n' "$fixture_user" "$(head -c 24 /dev/urandom | base64)" \
    | chpasswd
fi
home="/home/$fixture_user"
install -d -m 0700 -o "$fixture_user" -g "$fixture_user" "$home/.ssh"
install -m 0600 -o "$fixture_user" -g "$fixture_user" \
  "$authorized_keys" "$home/.ssh/authorized_keys"

# Where the tests raise the slow tool's flag (slow-df.sh), as root.
install -d -m 0755 "$flag_dir"
mkdir -p /run/sshd

/usr/sbin/sshd.pam -t -f "$1"
exec /usr/sbin/sshd.pam -D -e -f "$1"
