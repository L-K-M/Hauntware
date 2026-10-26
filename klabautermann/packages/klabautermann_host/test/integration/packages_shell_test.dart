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
  test('the refresh and the check try the managers in one order', () {
    final named = RegExp(
      r'for m in ([^;]+); do',
    ).firstMatch(HostCommands.packageManagerName()[2])![1]!.split(' ');
    final checked = [
      for (final match in RegExp(
        r"have (\S+); then\n  echo '== manager",
      ).allMatches(HostCommands.packageCheck()[2]))
        match[1]!,
    ];
    expect(named, checked);
  });

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    test('$name: apt is read from its cache, with the reboot it asks '
        'for', () async {
      final root = await Directory.systemTemp.createTemp('klab-pkg-');
      addTearDown(() => root.delete(recursive: true));
      await _write(root, 'var/cache/apt/pkgcache.bin', '');
      await _write(root, 'var/run/reboot-required', '');
      await _write(root, 'var/run/reboot-required.pkgs', 'libc6\n');
      await _stub(root, 'apt-get', r'''
[ "$1 $2 $3 $4" = "-s -o Debug::NoLocking=1 dist-upgrade" ] || exit 9
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
      await _stub(root, 'needs-restarting', r'[ "$1" = -r ] && exit 1; exit 9');

      final check = await _check(shell, root);
      expect(check.manager, PackageManager.dnf);
      expect(check.updates.single.security, isTrue);
      expect(check.securityCount, 1);
      expect(check.reboot, RebootState.required);
    });

    test('$name: zypper\'s cache age is its newest repository index, and '
        'its security patches are counted', () async {
      final root = await Directory.systemTemp.createTemp('klab-pkg-');
      addTearDown(() => root.delete(recursive: true));
      await _write(root, 'var/cache/zypp/raw/repo-oss/repodata/repomd.xml', '');
      await _stub(root, 'zypper', r'''
case "$*" in
  '--non-interactive --no-refresh -q lu')
    echo 'S | Repository | Name | Current Version | Available Version | Arch'
    echo '--+------------+------+-----------------+-------------------+-----'
    echo 'v | repo-oss   | curl | 8.6.0-1.1       | 8.6.0-2.1         | x86_64' ;;
  '--non-interactive --no-refresh -q lp -g security')
    echo 'Repository | Name | Category | Severity | Interactive | Status | Summary'
    echo '-----------+------+----------+----------+-------------+--------+--------'
    echo 'repo-oss   | p-1  | security | moderate | ---         | needed | curl' ;;
  *) exit 9 ;;
esac
''');

      final check = await _check(shell, root);
      expect(check.manager, PackageManager.zypper);
      expect(check.cachedAt, isNotNull);
      expect(check.updates.single.name, 'curl');
      expect(check.securityCount, 1);
    });

    test('$name: the refresh names the manager the check reads, apt-get '
        'as apt', () async {
      final root = await Directory.systemTemp.createTemp('klab-pkg-');
      addTearDown(() => root.delete(recursive: true));
      final bin = Directory('${root.path}/bin')..createSync();
      Future<ProcessResult> name() => Process.run(
        shell,
        [
          HostCommands.packageManagerName()[1],
          HostCommands.packageManagerName()[2],
        ],
        environment: {'PATH': bin.path},
        includeParentEnvironment: false,
      );

      expect((await name()).exitCode, 1);
      await _stub(root, 'dnf', 'exit 0');
      await _stub(root, 'apt-get', 'exit 0');
      expect((await name()).stdout, 'apt\n');
      expect(
        PackageManager.values.asNameMap()[((await name()).stdout as String)
            .trim()],
        PackageManager.apt,
      );
      expect(
        () => HostCommands.packageRefresh(PackageManager.pacman),
        throwsA(isA<HostCommandError>()),
      );
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
