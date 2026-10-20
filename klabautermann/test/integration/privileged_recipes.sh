# shellcheck shell=sh
# Spike S6's privileged-file recipes (03 §5.11, §8.5; M5 plan M01), run
# as root by capture_privileged.sh in each container (`sh -s -- <dir>
# <reader>`) and by runner_vm_s6_test.dart through the elevation prelude
# (`sh -c <this> sh <dir> <reader>`). POSIX sh, so BusyBox ash runs it.
#
# <dir> is an empty root-owned directory the caller made and removes
# with everything in it; this script deletes nothing. <reader> is an
# account other than root that a POSIX ACL entry names. For each recipe
# it creates its own target owned by root:adm with mode 0640, an
# ACL entry `user:<reader>:r--` and a `user.klab` xattr where the tools
# exist, replaces the content through a temp file beside it, and prints
# what survived. The output is deterministic, so a later run can be
# compared with the committed copy: no temp names, inodes or dates.
set -u

dir="$1"
reader="$2"

have() {
  command -v "$1" >/dev/null 2>&1
}

# Prints "<label>: exit <status>" for a step, so a refusal is evidence
# rather than an abort.
step() {
  label="$1"
  shift
  "$@" >/dev/null 2>&1
  echo "$label: exit $?"
}

echo '## tools'
for tool in tee chown chmod mv cp stat sha256sum getfacl setfacl \
  getfattr setfattr restorecon getenforce; do
  if have "$tool"; then
    echo "$tool: present"
  else
    echo "$tool: absent"
  fi
done

echo '## options'
echo "umask: $(umask)"
: >"$dir/probe-a"
: >"$dir/probe-b"
step 'chown --reference' chown --reference="$dir/probe-a" "$dir/probe-b"
step 'chmod --reference' chmod --reference="$dir/probe-a" "$dir/probe-b"
step 'cp --attributes-only --preserve=mode,ownership,xattr' \
  cp --attributes-only --preserve=mode,ownership,xattr \
  "$dir/probe-a" "$dir/probe-b"
step 'mv -f' mv -f "$dir/probe-b" "$dir/probe-a"

echo '## selinux'
if have getenforce; then
  echo "getenforce: $(getenforce 2>&1)"
else
  echo 'getenforce: absent'
fi
if [ -r /sys/fs/selinux/enforce ]; then
  echo "/sys/fs/selinux/enforce: $(cat /sys/fs/selinux/enforce)"
else
  echo '/sys/fs/selinux/enforce: unreadable'
fi

# A fresh target for recipe $1, with every attribute the tools can set,
# and the temp name beside it that the recipe writes.
setup() {
  target="$dir/target-$1.conf"
  temp="$dir/.target-$1.conf.klabautermann-tmp-$$"
  printf 'original\n' >"$target"
  chown root:adm "$target"
  chmod 0640 "$target"
  if have setfacl; then
    step 'setup setfacl' setfacl -m "u:$reader:r" "$target"
  fi
  if have setfattr; then
    step 'setup setfattr' setfattr -n user.klab -v spike "$target"
  fi
}

# What the target carries now, one fact per line.
describe() {
  echo "owner: $(stat -c '%U:%G' "$target")"
  echo "mode: $(stat -c '%a' "$target")"
  if ! have getfacl; then
    echo 'acl: (no getfacl)'
  elif acl="$(getfacl -c "$target" 2>/dev/null)"; then
    printf '%s\n' "$acl" | sed -e '/^$/d' -e 's/^/acl: /'
  else
    echo 'acl: (getfacl failed)'
  fi
  if ! have getfattr; then
    echo 'xattr user.klab: (no getfattr)'
  elif value="$(getfattr --only-values -n user.klab "$target" 2>/dev/null)"; then
    echo "xattr user.klab: $value"
  else
    echo 'xattr user.klab: none'
  fi
  if have sha256sum; then
    echo "content: $(sha256sum "$target" | cut -d ' ' -f 1)"
  else
    echo "content: $(cat "$target")"
  fi
  if [ -e "$temp" ]; then
    echo 'temp: left'
  else
    echo 'temp: gone'
  fi
}

write_temp() {
  printf 'edited\n' | tee "$temp" >/dev/null
}

# As write_temp, but no account but root can read the temp before its
# mode is set, whatever umask the session has.
write_temp_private() {
  (umask 077 && printf 'edited\n' | tee "$temp" >/dev/null)
}

# The numeric owner and mode of the target onto the temp, through stat,
# which BusyBox has, rather than --reference, which it lacks.
copy_owner() {
  chown "$(stat -c '%u:%g' "$target")" "$temp"
}
copy_mode() {
  chmod "$(stat -c '%a' "$target")" "$temp"
}

echo '## baseline'
setup baseline
describe

echo '## recipe a: tee, chown --reference, chmod --reference, mv'
setup a
step tee write_temp
step chown chown --reference="$target" "$temp"
step chmod chmod --reference="$target" "$temp"
step mv mv -f "$temp" "$target"
describe

echo '## recipe b: tee, cp --attributes-only --preserve=mode,ownership,xattr, mv'
setup b
step tee write_temp
step cp cp --attributes-only --preserve=mode,ownership,xattr "$target" "$temp"
step mv mv -f "$temp" "$target"
describe

echo '## recipe c: recipe a, then getfacl | setfacl --set-file=- before mv'
setup c
step tee write_temp
step chown chown --reference="$target" "$temp"
step chmod chmod --reference="$target" "$temp"
copy_acl() {
  getfacl -- "$target" 2>/dev/null | setfacl --set-file=- "$temp"
}
step 'getfacl | setfacl' copy_acl
step mv mv -f "$temp" "$target"
describe

echo '## recipe d: umask 077 tee, chown and chmod from stat, mv'
setup d
step tee write_temp_private
echo "temp mode: $(stat -c '%a' "$temp")"
step chown copy_owner
step chmod copy_mode
step mv mv -f "$temp" "$target"
describe
