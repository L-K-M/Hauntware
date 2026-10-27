// DSK-07's folder read through real shells (03 §7.3), on this host's
// `du`, over a folder the test builds. Tagged `shell`; a shell that is
// not installed gets no tests.
@Tags(['shell'])
@TestOn('linux')
library;

import 'dart:io';

import 'package:klabautermann_host/klabautermann_host.dart';
import 'package:test/test.dart';

final _shells = {
  for (final name in ['dash', 'bash'])
    for (final dir in ['/bin', '/usr/bin'])
      if (File('$dir/$name').existsSync()) name: '$dir/$name',
};

Future<DiskUsageParse> _read(
  String shell,
  String path, {
  Map<String, String>? environment,
}) async {
  final argv = HostCommands.diskUsage(path);
  final r = await Process.run(shell, argv.sublist(1), environment: environment);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  return parseDiskUsage(r.stdout as String, path);
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('klab-du-');
    Directory('${root.path}/big/inner').createSync(recursive: true);
    File('${root.path}/big/blob').writeAsBytesSync(List.filled(256 * 1024, 1));
    File('${root.path}/small').writeAsStringSync('x');
    File('${root.path}/with space').writeAsStringSync('y');
    Link('${root.path}/link').createSync('${root.path}/big');
  });

  tearDown(() => root.delete(recursive: true));

  for (final MapEntry(key: name, value: shell) in _shells.entries) {
    test('$name: lists the folder largest first, folders marked and a '
        'symlink to one not', () async {
      final listing = (await _read(shell, root.path)).listing!;
      expect(listing.incomplete, isFalse);
      expect(listing.entries.first.name, 'big');
      expect(listing.entries.first.isFolder, isTrue);
      expect(listing.entries.first.bytes, greaterThanOrEqualTo(256 * 1024));
      expect(
        listing.totalBytes,
        greaterThanOrEqualTo(listing.entries.first.bytes),
      );
      final byName = {for (final e in listing.entries) e.name: e};
      expect(byName.keys, containsAll(['small', 'with space', 'link']));
      expect(byName['link']!.isFolder, isFalse);
      expect(byName['small']!.isFolder, isFalse);
    });

    test('$name: a du that prints more errors than are kept still '
        'lists the whole folder', () async {
      // More than a pipe holds, so a cut that stopped reading would end
      // this du before its listing: as SIGPIPE ends du under sshd, though
      // this test's processes ignore it, the fake exits on a failed write.
      final bin = Directory('${root.path}/bin')..createSync();
      final du = File('${bin.path}/du')
        ..writeAsStringSync(
          '#!/bin/sh\n'
          'i=0; while [ \$i -lt 2000 ]; do '
          'echo "du: cannot read directory \'/x/\$i\': Permission denied" >&2 || exit 141; '
          'i=\$((i + 1)); done\n'
          'for p; do :; done\n'
          'printf "8\\t%s\\n4\\t%s/small\\n" "\$p" "\$p"\n',
        );
      await Process.run('chmod', ['+x', du.path]);

      final listing = (await _read(
        shell,
        root.path,
        environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
      )).listing!;
      expect(listing.incomplete, isTrue);
      expect(listing.entries.single.name, 'small');
    });

    test('$name: a missing folder says so', () async {
      final parse = await _read(shell, '${root.path}/gone');
      expect(parse.problem, DiskUsageProblem.notFound);
    });
  }
}
