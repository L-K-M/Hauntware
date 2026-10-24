# Spike S6: privileged files

Spike S6 (03 §5.11, §8.5; M5 plan M01) asks how the engine replaces a
root-owned file without losing its owner, mode, POSIX ACL or extended
attributes, which tools each userland lacks, and whether an elevated
`sftp-server` could carry the edit instead.

`klabautermann/test/integration/privileged_recipes.sh` holds the recipes.
For each one it makes a target owned by `root:adm` with mode 0640, an ACL
entry `user:<reader>:r--` and a `user.klab` xattr (where `setfacl` and
`setfattr` exist), replaces the content through a temp file in the same
directory, and prints what survived. It deletes nothing; its caller
removes the directory.

- `debian-13-coreutils.txt`, `alpine-322-busybox.txt`,
  `rhel-9-coreutils.txt`: `test/integration/capture.sh
  --privileged-files-only --update`, which runs the script as root in
  digest-pinned containers with umask 022. Debian 13 gets the pinned
  `acl` and `attr` packages; Alpine and UBI 9 run as shipped. Check mode
  compares a new run with these files byte for byte.
- `runner-vm/`: `klabautermann_core/test/integration/runner_vm_s6_test.dart`
  (tag `runner-vm-s6`), which `test/integration/runner_vm.sh` runs on the
  GitHub-hosted Ubuntu runner. It runs the same script through seance_core's
  elevation prelude as `klab-vm-sudo` on ext4, and starts `sftp-server`
  through the prelude. No password is in any file.

## Recipes

- **a**: `tee` to `.<name>.klabautermann-tmp-<pid>`, then
  `chown --reference`, `chmod --reference` and `mv`.
- **b**: `tee`, then `cp --attributes-only --preserve=mode,ownership,xattr
  <target> <temp>` and `mv`.
- **c**: recipe a, plus `getfacl <target> | setfacl --set-file=- <temp>`
  before the `mv`.
- **d**: `tee` under `umask 077`, then numeric `chown` and `chmod` from
  `stat -c '%u:%g'` and `stat -c '%a'`, and `mv`.

## What it shows

| Userland | a | b | c | d |
| --- | --- | --- | --- | --- |
| GNU coreutils (Debian 13, UBI 9) | owner, mode; **ACL and xattr lost** | owner, mode, ACL, xattr | owner, mode, ACL; **xattr lost** | owner, mode; **ACL and xattr lost** |
| BusyBox (Alpine 3.22) | **`--reference` refused: root:root 0644** | **`--attributes-only` refused: root:root 0644** | as a (no ACL tools) | owner, mode |

- GNU `cp --preserve=mode` carries the ACL with the mode bits, and
  `--attributes-only` leaves the temp's content alone, so recipe b keeps
  everything the target had.
- BusyBox has neither `--reference` nor `cp --attributes-only`, nor the
  ACL and xattr tools. With those steps refused, the temp keeps the
  session umask's mode: a 0640 file became 0644, readable by every
  account. Recipe d, with its temp made under `umask 077` (0600 before
  `chmod`), keeps owner and mode.
- `sha256sum` and `stat -c` are present in all three. `restorecon` and
  `getenforce` are absent and `/sys/fs/selinux/enforce` is unreadable in
  every container, so SELinux labels stay a manual check on RHEL 9
  (STATUS.md).
