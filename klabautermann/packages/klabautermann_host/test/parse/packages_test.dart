// The package check's parser (03 §7.8, PKG-01 to PKG-03): each manager's
// pending updates from cached metadata, security flags and the reboot
// flag.
import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

const _apt = '''
== manager apt
== cache 1761393600
== updates
NOTE: This is only a simulation!
      apt-get needs root privileges for real execution.
Reading package lists...
The following packages will be upgraded:
  base-files libssl3 linux-image-amd64
Inst base-files [12.4+deb12u5] (12.4+deb12u6 Debian:12.6/stable [amd64])
Inst libssl3 [3.0.11-1~deb12u2] (3.0.13-1~deb12u1 Debian-Security:12/stable-security [amd64])
Inst linux-image-6.1.0-26-amd64 (6.1.112-1 Debian-Security:12/stable-security [amd64])
Conf base-files (12.4+deb12u6 Debian:12.6/stable [amd64])
== rc 0
== reboot required
linux-image-6.1.0-25-amd64
libc6
libc6
''';

const _dnf = '''
== manager dnf
== cache 1761390000
== updates

bash.x86_64                         5.2.26-3.fc40                       updates
openssl-libs.x86_64                 1:3.2.2-3.fc40                      updates
openssl.x86_64                      1:3.2.2-3.fc40                      updates
Obsoleting Packages
grub2-tools.x86_64                  1:2.06-121.fc40                     updates
== rc 100
== security
FEDORA-2024-1a2b3c4d Important/Sec. openssl-libs-1:3.2.2-3.fc40.x86_64
== rc 0
== reboot no
''';

void main() {
  test('apt: Inst lines with their versions, security from the origin, '
      'and the packages that want a reboot, once each', () {
    final check = parsePackageCheck(_apt);
    expect(check.manager, PackageManager.apt);
    expect(check.failure, isNull);
    expect(check.cachedAt, DateTime.utc(2025, 10, 25, 12));
    expect(
      [
        for (final u in check.updates)
          (u.name, u.current, u.available, u.security),
      ],
      [
        ('base-files', '12.4+deb12u5', '12.4+deb12u6', false),
        ('libssl3', '3.0.11-1~deb12u2', '3.0.13-1~deb12u1', true),
        ('linux-image-6.1.0-26-amd64', null, '6.1.112-1', true),
      ],
    );
    expect(check.securityCount, 2);
    expect(check.reboot, RebootState.required);
    expect(check.rebootPackages, ['linux-image-6.1.0-25-amd64', 'libc6']);
  });

  test('apt: an Ubuntu update from both updates and security origins is a '
      'security update', () {
    final check = parsePackageCheck('''
== manager apt
== cache
== updates
Inst libc6 [2.39-0ubuntu8.2] (2.39-0ubuntu8.3 Ubuntu:24.04/noble-updates, Ubuntu:24.04/noble-security [amd64])
== rc 0
== reboot no
''');
    expect(check.updates.single.security, isTrue);
    expect(check.cachedAt, isNull);
    expect(check.reboot, RebootState.notRequired);
  });

  test('dnf: exit 100 lists updates up to the obsoletes, and an advisory '
      'marks exactly the package it names', () {
    final check = parsePackageCheck(_dnf);
    expect(check.manager, PackageManager.dnf);
    expect(
      [for (final u in check.updates) (u.name, u.available, u.security)],
      [
        ('bash', '5.2.26-3.fc40', false),
        ('openssl-libs', '1:3.2.2-3.fc40', true),
        // `openssl-libs-1:…` does not name `openssl`.
        ('openssl', '1:3.2.2-3.fc40', false),
      ],
    );
    expect(check.securityCount, 1);
    expect(check.reboot, RebootState.notRequired);
  });

  test('dnf: no cached metadata is said so, and a failing advisory list '
      'leaves security unknown', () {
    final empty = parsePackageCheck('''
== manager dnf
== cache
== updates
Error: Cache-only enabled but no cache for 'fedora'
== rc 1
== security
== rc 1
== reboot unknown
''');
    expect(empty.failure, PackageCheckFailure.noCache);
    expect(empty.updates, isEmpty);

    final noAdvisories = parsePackageCheck('''
== manager dnf
== updates
bash.x86_64   5.2.26-3.fc40   updates
== rc 100
== security
Unknown argument "updateinfo" for command "dnf5".
== rc 2
== reboot unknown
''');
    expect(noAdvisories.updates.single.name, 'bash');
    expect(noAdvisories.securityCount, isNull);
    expect(noAdvisories.reboot, RebootState.unknown);
  });

  test('zypper: the update table by its column names, and the needed '
      'security patches counted', () {
    final check = parsePackageCheck('''
== manager zypper
== updates
S | Repository      | Name | Current Version    | Available Version  | Arch
--+-----------------+------+--------------------+--------------------+-------
v | repo-sle-update | bash | 4.4-150400.25.22.1 | 4.4-150400.27.3.2  | x86_64
v | repo-sle-update | curl | 8.0.1-150400.5.41.1 | 8.0.1-150400.5.44.1 | x86_64
== rc 0
== security
Repository      | Name        | Category | Severity  | Interactive | Status | Summary
----------------+-------------+----------+-----------+-------------+--------+--------
repo-sle-update | SUSE-2024-1 | security | important | ---         | needed | bash
repo-sle-update | SUSE-2024-2 | security | moderate  | ---         | applied | curl
== rc 0
== reboot unknown
''');
    expect(
      [for (final u in check.updates) (u.name, u.current, u.available)],
      [
        ('bash', '4.4-150400.25.22.1', '4.4-150400.27.3.2'),
        ('curl', '8.0.1-150400.5.41.1', '8.0.1-150400.5.44.1'),
      ],
    );
    expect(check.securityCount, 1);
    expect(check.updates.any((u) => u.security), isFalse);
  });

  test('pacman: exit 1 without output is up to date; apk lists versions '
      'below the index', () {
    final current = parsePackageCheck('''
== manager pacman
== cache 1761390000
== updates
== rc 1
== reboot unknown
''');
    expect(current.failure, isNull);
    expect(current.updates, isEmpty);
    expect(current.securityCount, isNull);

    final pacman = parsePackageCheck('''
== manager pacman
== updates
linux 6.6.1.arch1-1 -> 6.6.2.arch1-1
== rc 0
== reboot unknown
''');
    expect(
      [for (final u in pacman.updates) (u.name, u.current, u.available)],
      [('linux', '6.6.1.arch1-1', '6.6.2.arch1-1')],
    );

    final apk = parsePackageCheck('''
== manager apk
== updates
Installed:                                Available:
busybox-1.36.1-r15                      < 1.36.1-r19
ssl_client-1.36.1-r15                   < 1.36.1-r19
apk-tools-2.14.0-r5                     < 2.14.1-r0
== rc 0
== reboot unknown
''');
    expect(
      [for (final u in apk.updates) (u.name, u.current, u.available)],
      [
        ('busybox', '1.36.1-r15', '1.36.1-r19'),
        ('ssl_client', '1.36.1-r15', '1.36.1-r19'),
        ('apk-tools', '2.14.0-r5', '2.14.1-r0'),
      ],
    );
  });

  test('no manager, a failing one, and output cut off before its status '
      'are failures that keep the reboot flag', () {
    final none = parsePackageCheck('== manager none\n== reboot required\n');
    expect(none.failure, PackageCheckFailure.noManager);
    expect(none.reboot, RebootState.required);
    expect(
      parsePackageCheck('== manager pkgin\n== cache 1700000000\n').cachedAt,
      DateTime.utc(2023, 11, 14, 22, 13, 20),
    );

    final failing = parsePackageCheck('''
== manager apt
== updates
E: Could not open lock file /var/lib/dpkg/lock-frontend
== rc 100
== reboot no
''');
    expect(failing.failure, PackageCheckFailure.failed);
    expect(failing.detail, contains('Could not open lock file'));

    final cut = parsePackageCheck(
      '== manager apt\n== updates\nInst a [1] (2 x [y])\n',
    );
    expect(cut.failure, PackageCheckFailure.failed);
  });
}
