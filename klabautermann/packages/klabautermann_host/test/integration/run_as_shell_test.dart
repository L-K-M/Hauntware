// JOB-19's "run now" as another user through real shells (03 §7.7): the
// script picks `runuser` where the host has it and `su` where it does
// not, as on BusyBox systems. Stand-ins on a PATH of their own record
// what was run; where the test runs as root, util-linux's and BusyBox's
// real tools run the command as `nobody`. Tagged `shell`; a shell that is
// not installed gets no tests.
@Tags(['shell'])
@TestOn('linux')
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

String? _which(String name) {
  for (final dir in ['/bin', '/usr/bin', '/sbin', '/usr/sbin']) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

final _busybox = _which('busybox');

/// Each installed shell, as the words that start it.
final _shells = <String, List<String>>{
  for (final name in ['dash', 'bash', 'mksh'])
    if (_which(name) case final p?) name: [p],
  if (_busybox case final p?) 'busybox ash': [p, 'sh'],
};

final _isRoot = (Process.runSync('id', ['-u']).stdout as String).trim() == '0';

void main() {
  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    group(name, () {
      late Directory bin;

      setUp(() {
        bin = Directory.systemTemp.createTempSync('klab-run-as-');
        addTearDown(() => bin.deleteSync(recursive: true));
      });

      /// A stand-in for [tool] that runs [body].
      void shim(String tool, String body) {
        final file = File('${bin.path}/$tool')
          ..writeAsStringSync('#!/bin/sh\n$body\n');
        Process.runSync('chmod', ['0755', file.path]);
      }

      /// A stand-in for [tool] that prints its name and arguments.
      void recorder(String tool) =>
          shim(tool, 'echo $tool; for a in "\$@"; do echo "\$a"; done');

      /// Why a test that stands in for [tool] on PATH cannot run here:
      /// the shell runs its own (a BusyBox built to run its applets
      /// before PATH has `su`), or null.
      String? ownTool(String tool) {
        final found =
            Process.runSync(shell.first, [
                  ...shell.skip(1),
                  '-c',
                  'command -v $tool',
                ]).stdout
                as String;
        return found.trim().isNotEmpty && !found.startsWith('/')
            ? '$name runs its own $tool'
            : null;
      }

      /// Runs "run now" for [command] as [user] under [shell], with only
      /// [bin] on PATH.
      Future<ProcessResult> runAs(String user, String command) {
        final argv = HostCommands.runCronCommand(command, asUser: user);
        expect(argv.first, 'sh');
        return Process.run(
          shell.first,
          [...shell.skip(1), ...argv.sublist(1)],
          environment: {'PATH': bin.path},
          includeParentEnvironment: false,
        );
      }

      test('runuser runs the command where the host has it', () async {
        recorder('runuser');
        recorder('su');

        final r = await runAs('www-data', "echo 'a b' | wc");
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect((r.stdout as String).trim().split('\n'), [
          'runuser',
          '-u',
          'www-data',
          '--',
          'sh',
          '-c',
          "echo 'a b' | wc",
        ]);
      });

      test('su runs it on a host without runuser', () async {
        recorder('su');

        final r = await runAs('www-data', "echo 'a b' | wc");
        expect(r.exitCode, 0, reason: '${r.stderr}');
        expect((r.stdout as String).trim().split('\n'), [
          'su',
          '-s',
          '/bin/sh',
          '-c',
          "echo 'a b' | wc",
          'www-data',
        ]);
      }, skip: ownTool('su'));

      test("the tool's exit status is the step's", () async {
        shim('su', 'exit 7');
        expect((await runAs('www-data', 'true')).exitCode, 7);
      }, skip: ownTool('su'));

      for (final (tool, real) in [
        ('runuser', _which('runuser')),
        ('su', _which('su')),
        ('su', _busybox == null ? null : '$_busybox su'),
      ]) {
        test(
          'the real ${real ?? tool} runs the command as the user',
          () async {
            // A shell that runs its own `su` runs that one instead; the
            // command sets the PATH either leaves it.
            shim(tool, 'PATH=/usr/sbin:/usr/bin:/sbin:/bin exec $real "\$@"');

            final r = await runAs(
              'nobody',
              r'PATH=/usr/bin:/bin; id -un; echo "$1-$#"',
            );
            expect(r.exitCode, 0, reason: '${r.stderr}');
            expect((r.stdout as String).trim().split('\n'), ['nobody', '-0']);
          },
          skip: !_isRoot
              ? 'needs root to run as another user'
              : real == null
              ? '$tool is not installed'
              : null,
        );
      }
    });
  }

  test('at least one shell is installed', () {
    expect(_shells, isNotEmpty);
  });
}
