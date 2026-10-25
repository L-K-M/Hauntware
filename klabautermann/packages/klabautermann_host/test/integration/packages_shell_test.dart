// The package check through a real shell (PKG-01 to PKG-03): stand-in
// managers on a PATH that holds only them and the few tools the script
// uses, and its `/var/` paths pointed at a stand-in tree. Tagged
// `shell`; a shell that is not installed gets no tests.
@Tags(['shell'])
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

/// The tools the script runs besides the managers.
const _tools = ['cat', 'sort', 'stat', 'tail'];

Future<void> _write(Directory root, String path, String text) async {
  final file = File('${root.path}/$path');
  await file.parent.create(recursive: true);
  await file.writeAsString(text);
}

/// A stand-in [name] on the test PATH under [root] that runs [script].
Future<void> _stub(Directory root, String name, String script) async {
  await _write(root, 'bin/$name', '#!/bin/sh\n$script\n');
  await Process.run('chmod', ['0755', '${root.path}/bin/$name']);
}

/// Runs the package check under [shell] with its `/var/` under [root].
Future<PackageCheck> _check(String shell, Directory root) async {
  final bin = Directory('${root.path}/bin')..createSync(recursive: true);
  for (final tool in _tools) {
    final path = [
      '/usr/bin/$tool',
      '/bin/$tool',
    ].firstWhere((path) => File(path).existsSync());
    Link('${bin.path}/$tool').createSync(path);
  }
  final argv = HostCommands.packageCheck();
  final result = await Process.run(
    shell,
    [argv[1], argv[2].replaceAll('/var/', '${root.path}/var/')],
    environment: {'PATH': bin.path},
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
  expect(result.stderr, isEmpty);
  return parsePackageCheck(result.stdout as String);
}

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    test('$name: apt is read from its cache, with the reboot it asks '
        'for', () async {
      final root = await Directory.systemTemp.createTemp('klab-pkg-');
      addTearDown(() => root.delete(recursive: true));
      await _write(root, 'var/cache/apt/pkgcache.bin', '');
      await _write(root, 'var/run/reboot-required', '');
      await _write(root, 'var/run/reboot-required.pkgs', 'libc6\n');
      await _stub(root, 'apt-get', r'''
[ "$1 $2 $3 $4" = "-s -o Debug::NoLocking=1 upgrade" ] || exit 9
echo 'Inst libssl3 [3.0.11-1] (3.0.13-1 Debian-Security:12/stable-security [amd64])'
''');

      final check = await _check(shell, root);
      expect(check.manager, PackageManager.apt);
      expect(check.failure, isNull);
      expect(check.cachedAt, isNotNull);
      expect(check.updates.single.security, isTrue);
      expect(check.reboot, RebootState.required);
      expect(check.rebootPackages, ['libc6']);
    });

    test('$name: dnf\'s exit 100 is updates, its advisories mark security, '
        'and needs-restarting answers the reboot', () async {
      final root = await Directory.systemTemp.createTemp('klab-pkg-');
      addTearDown(() => root.delete(recursive: true));
      await _stub(root, 'dnf', r'''
case "$*" in
  '-q --cacheonly check-update') echo 'bash.x86_64 5.2.26-3.fc40 updates'; exit 100 ;;
  '-q --cacheonly updateinfo list --security') echo 'FEDORA-1 Important/Sec. bash-5.2.26-3.fc40.x86_64' ;;
  *) exit 9 ;;
esac
''');
      await _stub(root, 'needs-restarting', '[ "\$1" = -r ] && exit 1');

      final check = await _check(shell, root);
      expect(check.manager, PackageManager.dnf);
      expect(check.updates.single.security, isTrue);
      expect(check.securityCount, 1);
      expect(check.reboot, RebootState.required);
    });

    test('$name: without a manager the check says so, and nothing says '
        'whether to reboot', () async {
      final root = await Directory.systemTemp.createTemp('klab-pkg-');
      addTearDown(() => root.delete(recursive: true));

      final check = await _check(shell, root);
      expect(check.failure, PackageCheckFailure.noManager);
      expect(check.reboot, RebootState.unknown);
    });
  }
}
